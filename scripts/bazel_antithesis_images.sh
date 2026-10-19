#!/usr/bin/env bash

set -euo pipefail

# Build and validate Antithesis images with Bazel compiling the node and
# workload binaries. On arm64, this deliberately keeps the existing
# uninstrumented local-development behavior. Native amd64 builds instrumented
# binaries for the shipping Antithesis image.

test_setup="${TEST_SETUP:-}"
if [[ "$test_setup" != avalanchego && "$test_setup" != subnet-evm ]]; then
  echo "TEST_SETUP must be 'avalanchego' or 'subnet-evm'" >&2
  exit 2
fi

case "$(uname -m)" in
  x86_64) architecture=amd64 ;;
  aarch64 | arm64) architecture=arm64 ;;
  *)
    echo "unsupported host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${BAZEL_ANTITHESIS_CACHE_ROOT:-${repo_root}/.cache/bazel-antithesis}"
mkdir -p "$cache_root/repository" "$cache_root/disk"
# setup-bazel populates this cache before network downloads are disabled in CI.
# Bind it into the Docker build so Gazelle can resolve its dependencies without
# network access after instrumentation.
export BAZEL_ANTITHESIS_REPOSITORY_CACHE="${BAZEL_ANTITHESIS_REPOSITORY_CACHE:-${HOME}/.cache/bazel-repository-cache}"
export BAZEL_ANTITHESIS_GO_MOD_CACHE="${BAZEL_ANTITHESIS_GO_MOD_CACHE:-${HOME}/.cache/bazel-go-repository-modcache}"
mkdir -p "$BAZEL_ANTITHESIS_REPOSITORY_CACHE" "$BAZEL_ANTITHESIS_GO_MOD_CACHE"

docker_cache_archive="${BAZEL_ANTITHESIS_DOCKER_CACHE_ARCHIVE:-}"
write_docker_cache="${BAZEL_ANTITHESIS_WRITE_DOCKER_CACHE:-false}"
if [[ -n "$docker_cache_archive" && -f "$docker_cache_archive" ]]; then
  docker load --input "$docker_cache_archive"
fi

case "$architecture" in
  amd64)
    golang_digest=26de5cf8eac40c12a1ff8de1a634971b4654fd881225eed7ace643b8c769f2f5
    debian_digest=a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91
    ;;
  arm64)
    golang_digest=581f0292073059289b736d46d572ba4c515e0b511f8645963e0b0adf232680a1
    debian_digest=a1b86db52ce3daef089e45aabe36dfec4091f82464c25c1fdcf03de197cbe82a
    ;;
esac

ensure_docker_image() {
  local source_image=$1
  local local_image=$2

  if docker image inspect "$local_image" > /dev/null 2>&1; then
    return
  fi
  docker pull --platform "linux/$architecture" "$source_image"
  docker tag "$source_image" "$local_image"
}

# These are Docker inputs, not outputs of the validation. The digest selects
# one platform and the local tag keeps the existing Dockerfiles unchanged.
export ANTITHESIS_GO_IMAGE="docker.io/library/golang@sha256:$golang_digest"
export ANTITHESIS_EXECUTION_IMAGE="docker.io/library/debian@sha256:$debian_digest"
ensure_docker_image "$ANTITHESIS_GO_IMAGE" "golang:1.26.8-bookworm"
ensure_docker_image "$ANTITHESIS_EXECUTION_IMAGE" "debian:12-slim"
if [[ "$architecture" == amd64 ]]; then
  ensure_docker_image "docker.io/antithesishq/go-instrumentor@sha256:0dba5495e2c60f9b37ef9d4d1b859bef761c4094a1e2a28861c139c3acd9e459" "antithesishq/go-instrumentor:latest"
fi

# The Antithesis builder Dockerfiles copy Bazel from this native image. This
# keeps Bazel native on both supported local-development architectures.
bazelisk --batch fetch //:gazelle \
  --repository_cache="$BAZEL_ANTITHESIS_REPOSITORY_CACHE" \
  --repo_env=GO_REPOSITORY_USE_HOST_MODCACHE=1 \
  --repo_env="GOMODCACHE=$BAZEL_ANTITHESIS_GO_MOD_CACHE"
bazelisk run "//bazel/image:load_builder_${architecture}" \
  --repository_cache="$cache_root/repository" \
  --disk_cache="$cache_root/disk" \
  --remote_upload_local_results=false

export ANTITHESIS_BAZEL=1
export BAZEL_BUILDER_IMAGE="avalanchego-bazel-builder:phase1"
bash -x "$repo_root/scripts/tests.build_antithesis_images.sh"

source "$repo_root/scripts/git_commit.sh"
node_image="antithesis-${test_setup}-node:${commit_hash}"
image_architecture="$(docker image inspect --format '{{.Architecture}}' "$node_image")"
if [[ "$image_architecture" != "$architecture" ]]; then
  echo "expected $node_image to be $architecture, got $image_architecture" >&2
  exit 1
fi

if [[ "$architecture" == amd64 ]]; then
  docker run --rm --entrypoint /bin/sh "$node_image" -ec '
    test -f /usr/lib/libvoidstar.so
    test -d /symbols
    test -n "$(find /symbols -type f -print -quit)"
  '
fi

if [[ "$write_docker_cache" == true && -n "$docker_cache_archive" ]]; then
  cache_images=(golang:1.26.8-bookworm debian:12-slim)
  if [[ "$architecture" == amd64 ]]; then
    cache_images+=(antithesishq/go-instrumentor:latest)
  fi
  mkdir -p "$(dirname "$docker_cache_archive")"
  temporary_archive="${docker_cache_archive}.tmp"
  docker image save --output "$temporary_archive" "${cache_images[@]}"
  mv "$temporary_archive" "$docker_cache_archive"
fi
