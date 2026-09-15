# the base image is tracked by its moving tag on purpose
# hadolint ignore=DL3007
FROM docker.io/binarycodes/mkdocs:latest

# the base image builds a mounted /blog at container start; here the content is
# part of the image, so the strict build runs once, at image build time, and a
# broken post fails the build instead of the container
COPY blog /blog
RUN mkdocs build --strict --site-dir /srv/site

# drop the base entrypoint so the container does not rebuild the site on start
ENTRYPOINT []
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile"]
