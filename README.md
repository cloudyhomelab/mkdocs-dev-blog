# Dev Blog

A Markdown dev blog packaged as a container image. Everything that changes regularly lives in
`blog/`: posts under `blog/docs/` and the site configuration in `blog/mkdocs.yml`. The image builds on
[`binarycodes/mkdocs`](https://github.com/cloudyhomelab/mkdocs-custom), which supplies
MkDocs, the devblog theme and Caddy. Unlike the base image, the content is baked in: the
strict build runs at image build time, so a broken post fails the build instead of the
container, and the container starts straight into Caddy on port 8000 over plain HTTP.

```sh
LOCAL=true docker buildx bake --load
docker run --rm -p 8000:8000 docker.io/binarycodes/mkdocs-dev-blog:latest
```

## Writing posts

Run the MkDocs dev server from the base image with `blog/` mounted:

```sh
docker run --rm -p 8000:8000 -v "$PWD/blog:/blog:ro" \
  docker.io/binarycodes/mkdocs:latest mkdocs serve --dev-addr=0.0.0.0:8000
```

Post front matter and site options are documented in the
[theme README](https://github.com/cloudyhomelab/mkdocs-custom/blob/main/theme/README.md).

## License

Copyright (C) 2026 Sujoy Das. This project is free software: you can redistribute it
and/or modify it under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any later version.
See [LICENSE](LICENSE). SPDX: `GPL-3.0-or-later`.
