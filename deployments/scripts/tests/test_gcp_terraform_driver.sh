#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC1091 # Bazel runfile paths are resolved at runtime.

set -euo pipefail

test_directory="$(mktemp -d)"
trap 'rm -rf "$test_directory"' EXIT
command_log="$test_directory/commands.log"
fixture="$test_directory/deployment.json"

source "${TEST_SRCDIR}/_main/deployments/scripts/common.sh"
source "${TEST_SRCDIR}/_main/deployments/scripts/gcp/terraform.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

terraform() {
    printf 'terraform %s\n' "$*" >>"$command_log"
    if [[ "$*" == *"output -json deployment" ]]; then
        cat "$fixture"
    fi
}
gcloud() { printf 'gcloud %s\n' "$*" >>"$command_log"; }
kubectl() { printf 'kubectl %s\n' "$*" >>"$command_log"; }

cat >"$fixture" <<'JSON'
{
  "project_id": "test-project", "cluster_name": "osmo-test", "gpu_node_pool": "gpu",
  "region": "asia-southeast1", "zone": "asia-southeast1-b",
  "postgres_host": "10.50.0.2", "postgres_database": "osmo", "postgres_username": "osmo",
  "postgres_password": "pa'ss$word\"x", "redis_host": "10.50.1.2", "redis_port": 6379,
  "redis_password": "redis-secret", "redis_ca": "", "bucket": "test-bucket",
  "access_key_id": "hmac-id", "access_key": "hmac-secret"
}
JSON

mkdir -p "$test_directory/terraform"
gcp_terraform_apply "$test_directory/terraform"
[[ "$(sed -n '1p' "$command_log")" == "terraform apply -auto-approve" ]] || fail "default apply command changed"
gcp_terraform_apply "$test_directory/terraform" true -var-file=extra.tfvars
[[ "$(sed -n '2p' "$command_log")" == "terraform plan -var-file=extra.tfvars" ]] || fail "dry-run arguments were not forwarded"
gcp_terraform_destroy "$test_directory/terraform"
[[ "$(sed -n '3p' "$command_log")" == "terraform destroy -auto-approve" ]] || fail "destroy command changed"
gcp_terraform_destroy "$test_directory/terraform" true
[[ "$(wc -l <"$command_log")" == 3 ]] || fail "dry-run destroy invoked terraform"

tfvars="$test_directory/terraform.tfvars"
TF_PROJECT_ID=test-project TF_CLUSTER_NAME=osmo-test TF_GCP_REGION=asia-southeast1 TF_GCP_ZONE='' \
    gcp_generate_tfvars "$tfvars"
grep -Fq 'project_id   = "test-project"' "$tfvars" || fail "project missing from tfvars"
grep -Fq 'zone         = "asia-southeast1-b"' "$tfvars" || fail "zone did not default to region-b"
grep -Fq 'redis_transit_encryption_mode = "DISABLED"' "$tfvars" || fail "redis TLS must be disabled for the minimal chart"
grep -Fq 'bucket_force_destroy = true' "$tfvars" || fail "bucket_force_destroy default changed"
grep -Fq 'deletion_protection  = false' "$tfvars" || fail "deletion_protection default changed"
grep -Fq 'gpu_node_pool_enabled  = false' "$tfvars" || fail "gpu pool default changed"
TF_GPU_NODE_POOL_ENABLED=true gcp_generate_tfvars "$tfvars"
grep -Fq 'gpu_node_pool_enabled  = true' "$tfvars" || fail "gpu pool flag not forwarded"

: >"$command_log"
outputs="$test_directory/outputs.env"
gcp_get_terraform_outputs "$test_directory/terraform" "$outputs"
grep -Fq -- "terraform -chdir=$test_directory/terraform output -json deployment" "$command_log" || fail "outputs not read from the deployment object"
if grep -Fq -- "-raw" "$command_log"; then fail "per-key -raw reads are not part of the contract"; fi
grep -Fq 'export PROVIDER="gcp"' "$outputs" || fail "provider marker missing"
grep -Fq 'export IS_PRIVATE_CLUSTER=' "$outputs" || fail "private cluster marker missing"
(
    # shellcheck disable=SC1090 # Generated in this test.
    source "$outputs"
    [[ "$POSTGRES_PASSWORD" == "pa'ss\$word\"x" ]] || fail "password not preserved through source"
    [[ "$REDIS_PORT" == 6379 && "$POSTGRES_PORT" == 5432 ]] || fail "ports wrong"
    [[ "$GCS_BUCKET" == test-bucket && "$GCS_ACCESS_KEY" == hmac-secret ]] || fail "storage outputs wrong"
    [[ "$GKE_GPU_NODE_POOL" == gpu && "$GKE_CLUSTER_NAME" == osmo-test ]] || fail "cluster outputs wrong"
)
[[ "$(gcp_get_terraform_output "$test_directory/terraform" bucket)" == test-bucket ]] || fail "single output read failed"
[[ -z "$(gcp_get_terraform_output "$test_directory/terraform" missing_key)" ]] || fail "missing key should be empty"

jq 'del(.bucket)' "$fixture" >"$fixture.bad" && mv "$fixture.bad" "$fixture"
if gcp_get_terraform_outputs "$test_directory/terraform" "$test_directory/bad.env" 2>/dev/null; then
    fail "incomplete outputs were accepted"
fi

: >"$command_log"
GKE_CLUSTER_NAME=osmo-test GCP_PROJECT_ID=test-project GCP_ZONE=asia-southeast1-b gcp_configure_kubectl
grep -Fq 'gcloud container clusters get-credentials osmo-test --project test-project --zone asia-southeast1-b --dns-endpoint' "$command_log" \
    || fail "get-credentials must use the DNS endpoint"
grep -Fq 'kubectl get nodes' "$command_log" || fail "kubectl was not exercised"

gcp_run_kubectl "get pods -n osmo"
grep -Fq 'kubectl get pods -n osmo' "$command_log" || fail "string-form kubectl wrapper failed"
gcp_run_kubectl get nodes -o name
grep -Fq 'kubectl get nodes -o name' "$command_log" || fail "argv-form kubectl wrapper failed"
echo "PASS: GCP Terraform driver"
