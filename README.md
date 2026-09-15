# blog

A Markdown dev blog packaged as a container image. Posts live under `docs/`, `mkdocs.yml`
configures the site, and the image builds on
[`binarycodes/mkdocs`](https://github.com/cloudyhomelab/mkdocs-custom), which supplies
MkDocs, the devblog theme and Caddy. Unlike the base image, the content is baked in: the
strict build runs at image build time, so a broken post fails the build instead of the
container, and the container starts straight into Caddy on port 8000 over plain HTTP.

```sh
LOCAL=true docker buildx bake --load
docker run --rm -p 8000:8000 docker.io/binarycodes/blog:latest
```

## Writing posts

Run the MkDocs dev server from the base image with this directory mounted:

```sh
docker run --rm -p 8000:8000 -v "$PWD:/blog:ro" \
  docker.io/binarycodes/mkdocs:latest mkdocs serve --dev-addr=0.0.0.0:8000
```

Post front matter and site options are documented in the
[theme README](https://github.com/cloudyhomelab/mkdocs-custom/blob/main/theme/README.md).

## CI

Pull requests run `validate.yml`: hadolint, the BuildKit checks, an amd64 image build
(which is the strict site build) and an HTTP smoke test of the running container. Pushes
to `main` run the same validation and then `publish.yml` pushes the image to Docker Hub
for amd64 and arm64, tagged `latest` and `sha-<commit>`, with provenance and SBOM
attestations and a keyless cosign signature. A weekly rebuild picks up base-image
updates. The publish job needs the `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets.
