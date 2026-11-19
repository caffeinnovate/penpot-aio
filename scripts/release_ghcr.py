"""Publish a versioned release from an existing, tested GHCR image index."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess  # nosec B404 - invoke Git and Docker with argument lists.
import sys
from itertools import count
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

REPO = "caffeinnovate/penpot-aio"
IMAGE = f"ghcr.io/{REPO}"
PLATFORMS = {("linux", "amd64"), ("linux", "arm64")}
INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}


def github(path, *, method="GET", data=None, missing_ok=False):
    request = Request(
        f"https://api.github.com/repos/{REPO}/{path}",
        data=json.dumps(data).encode() if data is not None else None,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Content-Type": "application/json",
            "User-Agent": "penpot-aio-release-workflow",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method=method,
    )
    try:
        with urlopen(request, timeout=30) as response:  # nosec B310 - fixed HTTPS origin.
            return json.load(response)
    except HTTPError as error:
        if error.code == 404 and missing_ok:
            return None
        raise RuntimeError(
            f"GitHub {method} {path} returned HTTP {error.code}"
        ) from error


def publishing_run(commit):
    query = urlencode(
        {"branch": "main", "head_sha": commit, "status": "success", "per_page": 100}
    )
    runs = github(f"actions/workflows/publish-ghcr.yml/runs?{query}")["workflow_runs"]
    for run in runs:
        if run["head_sha"] != commit or run["conclusion"] != "success":
            continue
        jobs = github(f"actions/runs/{run['id']}/jobs")["jobs"]
        if any(
            step["name"] == "Publish the commit-tagged image"
            and step["conclusion"] == "success"
            for job in jobs
            for step in job["steps"]
        ):
            return run["html_url"]
    raise RuntimeError(f"No successful GHCR publishing run found for {commit}")


def image_manifest(reference, *, missing_ok=False):
    result = subprocess.run(  # nosec B603
        [
            "docker",
            "buildx",
            "imagetools",
            "inspect",
            "--format",
            "{{json .Manifest}}",
            reference,
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        message = result.stderr.strip().removeprefix("ERROR: ")
        if missing_ok and message == f"{reference}: not found":
            return None
        raise RuntimeError(f"Could not inspect {reference}: {result.stderr.strip()}")
    return json.loads(result.stdout)


def require_platforms(index, reference):
    platforms = {
        (platform.get("os"), platform.get("architecture"))
        for manifest in index.get("manifests", [])
        if (platform := manifest.get("platform"))
    }
    if index.get("mediaType") not in INDEX_TYPES or not PLATFORMS.issubset(platforms):
        raise RuntimeError(
            f"{reference} must provide a linux/amd64 and linux/arm64 image index"
        )


def promote_image(reference, digest):
    subprocess.run(  # nosec B603
        [
            "docker",
            "buildx",
            "imagetools",
            "create",
            "--tag",
            reference,
            f"{IMAGE}@{digest}",
        ],
        check=True,
    )
    if image_manifest(reference)["digest"] != digest:
        raise RuntimeError(
            f"{reference} did not resolve to the tested digest after promotion"
        )


def tagged_commit(tag):
    reference = github(f"git/ref/tags/{tag}", missing_ok=True)
    if reference is None:
        return None
    target = reference["object"]
    while target["type"] == "tag":
        target = github(f"git/tags/{target['sha']}")["object"]
    if target["type"] != "commit":
        raise RuntimeError(f"Git tag {tag} does not point to a commit")
    return target["sha"]


def existing_release(tag):
    # The releases list includes drafts when accessed with repository write permission.
    for page in count(1):
        releases = github(f"releases?per_page=100&page={page}")
        for release in releases:
            if release["tag_name"] == tag:
                return release
        if len(releases) < 100:
            return None


def release_image(commit, digest, version, make_latest):
    version_match = re.fullmatch(r"([0-9]+\.[0-9]+\.[0-9]+)-aio\.[1-9][0-9]*", version)
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise RuntimeError("source_commit must be a full lowercase commit SHA")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
        raise RuntimeError("image_digest must be a full lowercase sha256 digest")
    if not version_match or len(version) > 128:
        raise RuntimeError("release_version must use the form 2.16.0-aio.4")

    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", commit, "HEAD"], check=False
    )  # nosec B603 B607
    if ancestor.returncode:
        raise RuntimeError(f"{commit} is not on the checked-out main history")
    dockerfile = subprocess.check_output(
        ["git", "show", f"{commit}:Dockerfile"], text=True
    )  # nosec B603 B607
    pinned_version = re.search(r"^ARG PENPOT_VERSION=(\S+)$", dockerfile, re.MULTILINE)
    if not pinned_version or pinned_version[1] != version_match[1]:
        raise RuntimeError(
            f"Release {version} does not match PENPOT_VERSION at {commit}"
        )

    run_url = publishing_run(commit)
    source = f"{IMAGE}:sha-{commit}"
    source_index = image_manifest(source)
    if source_index["digest"] != digest:
        raise RuntimeError(
            "The commit-tagged image no longer points to the supplied tested digest"
        )
    require_platforms(source_index, source)

    version_ref = f"{IMAGE}:{version}"
    tag = f"v{version}"
    version_index = image_manifest(version_ref, missing_ok=True)
    previous_commit = tagged_commit(tag)
    release = existing_release(tag)
    if version_index and version_index["digest"] != digest:
        raise RuntimeError(f"{version_ref} already points to another digest")
    if previous_commit and previous_commit != commit:
        raise RuntimeError(f"Git tag {tag} already points to another commit")
    if release and (
        previous_commit != commit
        or release["draft"]
        or release["prerelease"]
        or digest not in (release["body"] or "")
    ):
        raise RuntimeError(f"GitHub Release {tag} conflicts with the requested release")

    if version_index is None:
        promote_image(version_ref, digest)
    if previous_commit is None:
        github(
            "git/refs", method="POST", data={"ref": f"refs/tags/{tag}", "sha": commit}
        )
    if tagged_commit(tag) != commit:
        raise RuntimeError(f"Could not verify {tag} points to {commit}")
    if release is None:
        release = github(
            "releases",
            method="POST",
            data={
                "tag_name": tag,
                "name": f"Penpot AIO {version}",
                "body": f"""## Container image

```sh
docker pull {version_ref}
```

- Image digest `{digest}`
- Source commit [`{commit}`](https://github.com/{REPO}/commit/{commit})
- [Successful GHCR build]({run_url})
""",
                "draft": False,
                "prerelease": False,
                "make_latest": "false",
            },
        )

    if make_latest:
        latest_ref = f"{IMAGE}:latest"
        latest_index = image_manifest(latest_ref, missing_ok=True)
        if latest_index is None or latest_index["digest"] != digest:
            promote_image(latest_ref, digest)
        latest_release = github("releases/latest", missing_ok=True)
        if latest_release is None or latest_release["id"] != release["id"]:
            github(
                f"releases/{release['id']}",
                method="PATCH",
                data={"make_latest": "true"},
            )

    print(
        f"Release {tag}: {release['html_url']}\nImage: {version_ref}\nDigest: {digest}"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_commit")
    parser.add_argument("image_digest")
    parser.add_argument("release_version")
    parser.add_argument("make_latest", choices=("true", "false"))
    args = parser.parse_args()
    try:
        release_image(
            args.source_commit,
            args.image_digest,
            args.release_version,
            args.make_latest == "true",
        )
    except (
        RuntimeError,
        KeyError,
        URLError,
        ValueError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
