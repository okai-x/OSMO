#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

repository="${TEST_SRCDIR}/_main"
test_directory="$(mktemp -d)"
trap 'rm -rf -- "$test_directory"' EXIT
mkdir -p "$test_directory/bin" "$test_directory/terraform"
export COMMAND_LOG="$test_directory/commands.log"
export FIXTURE="$test_directory/deployment.json"
cat >"$FIXTURE" <<'JSON'
{"bucket":"tf-bucket","access_key_id":"tf-hmac-id","access_key":"tf-hmac-secret","region":"asia-southeast1"}
JSON
cat >"$test_directory/bin/mock" <<'EOF2'
#!/bin/bash
set -euo pipefail
tool="$(basename "$0")"
printf '%s %s\n' "$tool" "$*" >>"$COMMAND_LOG"
case "$tool" in
  kubectl)
    [[ "$1" == apply ]] && cat >/dev/null
    [[ "$1" == create ]] && echo 'kind: Secret'
    # No in-cluster MinIO: auto-detection must not pick the minio backend.
    [[ "$1 ${2:-}" == 'get svc' ]] && exit 1 ;;
  terraform) [[ "$*" == *"output -json deployment" ]] && cat "$FIXTURE" ;;
esac
exit 0
EOF2
chmod +x "$test_directory/bin/mock"
for tool in kubectl terraform gcloud; do ln -s mock "$test_directory/bin/$tool"; done
export PATH="$test_directory/bin:$PATH"
export TF_DIR="$test_directory/terraform"
script="$repository/deployments/scripts/configure-storage.sh"
values="$test_directory/storage-values.yaml"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing: $2"; }
absent() { ! grep -Fq -- "$2" "$1" || fail "unexpected: $2"; }

# Explicit env credentials win over Terraform outputs.
GCS_BUCKET=env-bucket GCS_ACCESS_KEY_ID=env-id GCS_ACCESS_KEY=env-secret GCS_REGION=europe-west1 \
    bash "$script" --backend gcs --namespace osmo-test --output-values "$values" >"$test_directory/env.log" 2>&1
contains "$values" "base_url: gs://env-bucket"
contains "$values" "secretName: osmo-workflow-data-cred"
contains "$values" "secretName: osmo-workflow-app-cred"
absent "$values" "env-secret"
[[ "$(grep -c 'kubectl create secret generic osmo-workflow-' "$COMMAND_LOG")" == 3 ]] || fail "expected three credential Secrets"
contains "$COMMAND_LOG" "--from-literal=endpoint=gs://env-bucket"
contains "$COMMAND_LOG" "--from-literal=addressing_style=path"
contains "$COMMAND_LOG" "--from-literal=region=europe-west1"
contains "$COMMAND_LOG" "-n osmo-test"
absent "$COMMAND_LOG" "terraform"

# Without env credentials the backend reads the GCP Terraform deployment output.
: >"$COMMAND_LOG"
bash "$script" --backend gcs --namespace osmo-test --output-values "$values" >"$test_directory/tf.log" 2>&1
contains "$COMMAND_LOG" "terraform -chdir=$TF_DIR output -json deployment"
contains "$values" "base_url: gs://tf-bucket"
contains "$COMMAND_LOG" "--from-literal=access_key_id=tf-hmac-id"
contains "$COMMAND_LOG" "--from-literal=region=asia-southeast1"

# auto picks gcs from GCS_BUCKET, and a custom addressing style is honoured.
: >"$COMMAND_LOG"
GCS_BUCKET=env-bucket GCS_ACCESS_KEY_ID=env-id GCS_ACCESS_KEY=env-secret STORAGE_ADDRESSING_STYLE=virtual \
    bash "$script" --backend auto --namespace osmo-test --output-values "$values" >"$test_directory/auto.log" 2>&1
contains "$test_directory/auto.log" "Storage backend: gcs"
contains "$COMMAND_LOG" "--from-literal=addressing_style=virtual"

# Workload identity is rejected; nothing is created.
: >"$COMMAND_LOG"
if GCS_BUCKET=b GCS_ACCESS_KEY_ID=i GCS_ACCESS_KEY=s bash "$script" --backend gcs --auth-method workload-identity \
        --namespace osmo-test --output-values "$values" >"$test_directory/wi.log" 2>&1; then
    fail "workload identity must be rejected for gcs"
fi
absent "$COMMAND_LOG" "create secret"
echo "PASS: gcs storage backend"
