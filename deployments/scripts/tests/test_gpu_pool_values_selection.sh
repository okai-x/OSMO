#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC1091 # Bazel runfile paths are resolved at runtime.
set -euo pipefail

export STATIC_VALUES_DIR="${TEST_SRCDIR}/_main/deployments/values"
source "${TEST_SRCDIR}/_main/deployments/scripts/deploy-k8s.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
label_file="$(mktemp)"
trap 'rm -f "$label_file"' EXIT
# deploy-k8s.sh calls the wrapper inside a command substitution, so the mock
# reports the queried label through a file instead of a variable.
mock_kubectl() {
    local label
    label="$(sed -E 's/.* -l ([^ ]+) .*/\1/' <<<"$1")"
    printf '%s' "$label" >"$label_file"
    [[ "$label" == "$GPU_LABEL_PRESENT" ]] && echo "node-1"
    return 0
}
queried_label() { cat "$label_file"; }
# shellcheck disable=SC2034 # Read by render_gpu_pool_values from deploy-k8s.sh.
RUN_KUBECTL=mock_kubectl

# Azure/AWS keep the NFD label and the original fragment.
PROVIDER=aws GPU_LABEL_PRESENT="nvidia.com/gpu.present=true" render_gpu_pool_values
[[ "$GPU_POOL_VALUES_FILE" == "$STATIC_VALUES_DIR/gpu-pool.yaml" ]] || fail "aws selected $GPU_POOL_VALUES_FILE"
[[ "$(queried_label)" == "nvidia.com/gpu.present=true" ]] || fail "aws queried $(queried_label)"

# GKE has no NFD; detection keys on the accelerator label and picks the GKE fragment.
PROVIDER=gcp GPU_LABEL_PRESENT="cloud.google.com/gke-accelerator" render_gpu_pool_values
[[ "$GPU_POOL_VALUES_FILE" == "$STATIC_VALUES_DIR/gpu-pool-gke.yaml" ]] || fail "gcp selected $GPU_POOL_VALUES_FILE"
[[ "$(queried_label)" == "cloud.google.com/gke-accelerator" ]] || fail "gcp queried $(queried_label)"

# No GPU nodes and no forced pool: nothing layered.
PROVIDER=gcp GPU_LABEL_PRESENT="none" render_gpu_pool_values
[[ -z "$GPU_POOL_VALUES_FILE" ]] || fail "unexpected fragment without GPU nodes"

# A zero-node GKE GPU pool still gets the fragment when the pool was requested.
PROVIDER=gcp GPU_LABEL_PRESENT="none" OSMO_GPU_POOL_ENABLED=true render_gpu_pool_values
[[ "$GPU_POOL_VALUES_FILE" == "$STATIC_VALUES_DIR/gpu-pool-gke.yaml" ]] || fail "forced gcp pool selected $GPU_POOL_VALUES_FILE"

# NO_GPU wins over everything.
PROVIDER=gcp GPU_LABEL_PRESENT="cloud.google.com/gke-accelerator" NO_GPU=1 render_gpu_pool_values
[[ -z "$GPU_POOL_VALUES_FILE" ]] || fail "NO_GPU did not suppress the fragment"

grep -Fq "cloud.google.com/gke-accelerator" "$STATIC_VALUES_DIR/gpu-pool-gke.yaml" || fail "GKE fragment lacks accelerator affinity"
grep -Fq "default_platform: gpu" "$STATIC_VALUES_DIR/gpu-pool-gke.yaml" || fail "GKE fragment lacks gpu platform"
echo "PASS: GPU pool values selection"
