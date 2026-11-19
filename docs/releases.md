# Releases

The upstream `JSONbored/penpot-aio` project uses the app repo release model:

- upstream version plus AIO revision, for example `v2.15.3-aio.1`
- packages publish from `main` through `aio-fleet`
- formal GitHub Releases and changelog updates are release-driven

Shared release, registry, and catalog behavior lives in `aio-fleet`.

## Caffeinnovate GHCR builds

Once the workflow is on the fork's default branch, open **Actions**, select **Publish Penpot AIO to GHCR**, and run it from `main`. The workflow checks the Unraid template and runs the Docker integration tests before publishing `linux/amd64` and `linux/arm64` with a `sha-<full commit SHA>` tag.

After the first publish, set the package visibility to **Public** in GitHub Packages to allow anonymous pulls. Replace `FULL_COMMIT_SHA` with the workflow run's commit SHA.

```sh
docker pull ghcr.io/caffeinnovate/penpot-aio:sha-FULL_COMMIT_SHA
```

## Caffeinnovate releases

After testing the commit-tagged image in Unraid, run **Release Penpot AIO** from `main` in GitHub Actions. Enter the full commit SHA, the exact `sha256:…` digest you tested, and an AIO version such as `2.19.3-aio.1`.

The workflow adds the version tag to that image index and creates the corresponding Git tag and GitHub Release. Select **Advance the GHCR latest tag and the GitHub Latest release** when that version should become the default. To resume an interrupted release, use the same inputs again.
