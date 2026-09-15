variable "REGISTRY"   { default = "docker.io" }
variable "NAMESPACE"  { default = "binarycodes" }
variable "IMAGE_NAME" { default = "blog" }

# set by publish.yml so every published image also carries an immutable tag
variable "GIT_SHA"    { default = "" }
variable "SOURCE_URL" { default = "" }

variable "LOCAL" { default = false }

group "default" {
  targets = ["image"]
}

target "image" {
  context    = "."
  dockerfile = "Dockerfile"

  # the base image is tracked by a moving tag, so always build from its current digest
  pull = true

  labels = {
    "org.opencontainers.image.title"       = "${IMAGE_NAME}"
    "org.opencontainers.image.description" = "Dev blog: MkDocs site with the content baked in, served by Caddy on port 8000"
    "org.opencontainers.image.source"      = "${SOURCE_URL}"
    "org.opencontainers.image.revision"    = "${GIT_SHA}"
  }

  tags = concat(
    ["${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:latest"],
    GIT_SHA != "" ? ["${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:sha-${substr(GIT_SHA, 0, 12)}"] : [],
  )

  platforms = LOCAL ? [] : ["linux/amd64", "linux/arm64"]
}
