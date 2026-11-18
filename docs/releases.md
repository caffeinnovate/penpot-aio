# Releases

`penpot-aio` uses the app repo release model:

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
