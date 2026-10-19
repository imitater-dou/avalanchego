#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
: "${RUNNER_OS:?RUNNER_OS must be set}"
: "${RUNNER_ARCH:?RUNNER_ARCH must be set}"

inputs=(
  go.mod
  scripts/bazel_antithesis_images.sh
  tests/antithesis/Dockerfile.builder-bazel
  tests/antithesis/Dockerfile.builder-uninstrumented-bazel
  tests/antithesis/avalanchego/Dockerfile.node
  tests/antithesis/avalanchego/Dockerfile.workload
  tests/antithesis/subnet-evm/Dockerfile.node
  tests/antithesis/subnet-evm/Dockerfile.workload
)
input_digest="$(sha256sum "${inputs[@]}" | sha256sum | awk '{print $1}')"
printf 'key=antithesis-bazel-image-docker-v1-%s-%s-%s\n' \
  "$RUNNER_OS" "$RUNNER_ARCH" "$input_digest" >> "$GITHUB_OUTPUT"
