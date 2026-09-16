#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build-images.sh [--tag TAG] [--output-dir DIRECTORY]
                                    [--push --project PROJECT_ID]

Build this checkout's OSMO images for linux/amd64 into the local Docker daemon.
Local names: osmo/<component>:<version>-prana-<commit>
With --push: asia-southeast1-docker.pkg.dev/PROJECT_ID/osmo/<component>:TAG

Pushing requires an existing Docker repository named osmo and Docker credentials.
No push, cloud resource creation, or deployment occurs by default.
Build records are saved under ~/.local/state/osmo-prana-images/TAG/build.*.
Use --output-dir to change the records' root directory.
EOF
}

fail() { echo "ERROR: $*" >&2; exit 1; }

tag=
project=
output_root=
push=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag|--project|--output-dir)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a value."
            case "$1" in
                --tag) tag="$2" ;;
                --project) project="$2" ;;
                --output-dir) output_root="$2" ;;
            esac
            shift 2 ;;
        --push) push=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
if [[ "$push" == true ]]; then
    [[ "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || fail '--push requires --project with a GCP project ID.'
fi
[[ "$(uname -s):$(uname -m)" == Linux:x86_64 ]] || fail 'This script requires a Linux x86_64 host.'
if command -v bazelisk >/dev/null 2>&1; then
    bazel_command=bazelisk
elif command -v bazel >/dev/null 2>&1; then
    bazel_command=bazel
else
    fail 'Install Bazelisk or the Bazel version in .bazelversion first.'
fi

output_root="${output_root:-${HOME:?HOME is required without --output-dir}/.local/state/osmo-prana-images}"
[[ "$output_root" == /* ]] || output_root="$PWD/$output_root"
repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repository_root"
source_commit=$(git rev-parse HEAD)
version=$(awk '/^major:/ {major=$2} /^minor:/ {minor=$2} /^revision:/ {revision=$2}
    END {printf "%s.%s.%s", major, minor, revision}' src/lib/utils/version.yaml)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Cannot read the OSMO version.'
tag="${tag:-${version}-prana-${source_commit:0:8}}"
[[ "$tag" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || fail 'Invalid Docker image tag.'
export OSMO_VERSION_TAG="prana${source_commit:0:8}"
docker info >/dev/null
docker buildx version >/dev/null

output_root="$output_root/$tag"
mkdir -p -- "$output_root"
output_directory=$(mktemp -d "$output_root/build.XXXXXXXX")
exec > >(tee "$output_directory/build.log") 2>&1
printf 'Source commit: %s\nVersion stamp: %s\nImage tag: %s\n' \
    "$source_commit" "$OSMO_VERSION_TAG" "$tag" | tee "$output_directory/source.txt"
git status --short > "$output_directory/worktree-status.txt"
git diff --binary HEAD > "$output_directory/source.patch"
printf 'image\tid\tplatform\n' > "$output_directory/images.tsv"

# Component, existing oci_load target, and the tag embedded in its Docker tarball.
specifications=(
    'service|//src/service/core:service_image_load_x86_64|osmo.local/service:latest-x86_64'
    'agent|//src/service/agent:agent_service_image_load_x86_64|osmo.local/agent:latest-x86_64'
    'logger|//src/service/logger:logger_image_load_x86_64|osmo.local/logger:latest-x86_64'
    'router|//src/service/router:router_image_load_x86_64|osmo.local/router:latest-x86_64'
    'worker|//src/service/worker:worker_image_load_x86_64|osmo.local/worker:latest-x86_64'
    'delayed-job-monitor|//src/service/delayed_job_monitor:delayed_job_monitor_image_load_x86_64|osmo.local/delayed-job-monitor:latest-x86_64'
    'authz-sidecar|//src/service/authz_sidecar:authz_sidecar_image_load_x86_64|osmo.local/authz-sidecar:latest-x86_64'
    'mcp|//src/service/mcp:mcp_image_load_x86_64|osmo.local/mcp:latest-x86_64'
    'backend-listener|//src/operator:backend_listener_image_load_x86_64|osmo.local/backend-listener:latest-x86_64'
    'backend-worker|//src/operator:backend_worker_image_load_x86_64|osmo.local/backend-worker:latest-x86_64'
    'backend-test-runner|//src/operator/backend_test_runner:backend_test_runner_image_load_x86_64|osmo.local/backend_test_runner:latest-x86_64'
    'init-container|//src/runtime:init_image_load_x86_64|init_image_x86_64:latest'
    'client|//src/cli:cli_image_amd64_load|cli_image_amd64:latest'
)
targets=()
images=()
for specification in "${specifications[@]}"; do
    IFS='|' read -r component target source_tag <<< "$specification"
    targets+=("$target")
    images+=("$component")
done

"$bazel_command" build --platforms=//bzl/platforms:linux_x86_64 \
    --workspace_status_command=bzl/prana_status.sh \
    --jobs=8 --local_resources=memory=24576 \
    --remote_download_outputs=all --output_groups=+tarball "${targets[@]}"
docker buildx build --platform linux/amd64 --load \
    --tag "osmo/web-ui:$tag" \
    --label "org.opencontainers.image.revision=$source_commit" \
    --label "org.opencontainers.image.version=$tag" src/ui

for specification in "${specifications[@]}"; do
    IFS='|' read -r component target source_tag <<< "$specification"
    target_path="${target#//}"
    tarball="bazel-bin/${target_path/:/\/}/tarball.tar"
    [[ -f "$tarball" ]] || fail "Missing build output: $tarball"
    previous_id=$(docker image inspect --format '{{.Id}}' "$source_tag" 2>/dev/null || true)
    if ! load_output=$(docker load --input "$tarball" 2>&1); then
        printf '%s\n' "$load_output" >&2
        fail "Cannot load $component."
    fi
    # Preserve existing development tags after assigning the requested local name.
    if ! docker tag "$source_tag" "osmo/$component:$tag"; then
        if [[ -n "$previous_id" ]]; then docker tag "$previous_id" "$source_tag"; fi
        fail "Cannot tag $component."
    fi
    if [[ -n "$previous_id" ]]; then docker tag "$previous_id" "$source_tag"; fi
done
images+=(web-ui)
for component in "${images[@]}"; do
    reference="osmo/$component:$tag"
    platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$reference")
    [[ "$platform" == linux/amd64 ]] || fail "Unexpected platform for $reference: $platform"
    image_id=$(docker image inspect --format '{{.Id}}' "$reference")
    printf '%s\t%s\t%s\n' "$reference" "$image_id" "$platform" >> "$output_directory/images.tsv"
    printf 'Ready: %s\n' "$reference"
done
echo "Verifying CLI version in osmo/client:$tag"
version_output=$(docker run --rm --network none --entrypoint osmo "osmo/client:$tag" version)
printf '%s\n' "$version_output" | tee "$output_directory/client-version.log"
[[ "$version_output" == *"OSMO client version:  ${version}.${OSMO_VERSION_TAG}"* ]] || fail 'CLI version stamp does not match the source.'
echo "Built ${#images[@]} local images. Records: $output_directory"

if [[ "$push" == true ]]; then
    remote_prefix="asia-southeast1-docker.pkg.dev/$project/osmo"
    for component in "${images[@]}"; do
        remote_reference="$remote_prefix/$component:$tag"
        docker tag "osmo/$component:$tag" "$remote_reference"
        docker push "$remote_reference"
        printf '%s\n' "$remote_reference" >> "$output_directory/pushed-images.txt"
    done
    echo "Pushed ${#images[@]} images to $remote_prefix"
fi
