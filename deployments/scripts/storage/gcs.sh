#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Google Cloud Storage backend for configure-storage.sh.
#
# Static HMAC credentials only. The OSMO storage SDK reaches GCS through the
# S3-compatible XML API and its gs:// backend rejects default credentials, so
# Workload Identity cannot be used here yet. Credentials resolve from:
#   1. GCS_BUCKET + GCS_ACCESS_KEY_ID + GCS_ACCESS_KEY env vars
#      (gcp/terraform.sh exports them from the Terraform outputs)
#   2. the osmo GCP Terraform `deployment` output in terraform/gcp/example
# Creates 3 K8s Secrets and emits a values fragment with a gs:// base_url.

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:?NAMESPACE not set}"
OUTPUT_VALUES="${OUTPUT_VALUES:?OUTPUT_VALUES not set}"
AUTH_METHOD="${AUTH_METHOD:-static}"
NGC_SECRET_NAME="${NGC_SECRET_NAME:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # Script-relative source is resolved at runtime.
source "$SCRIPT_DIR/common.sh"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../../terraform/gcp/example}"

if [[ "$AUTH_METHOD" == "workload-identity" ]]; then
    cat >&2 <<'MSG'
[ERROR] --auth-method workload-identity is not supported on the gcs backend.
The OSMO storage SDK does not support default credentials for gs:// yet;
GKE Workload Identity cannot replace the HMAC key. Use --auth-method static.
MSG
    exit 2
fi

# 1. Discover credentials + bucket. Precedence: explicit env vars > GCP TF output.
if [[ -n "${GCS_BUCKET:-}" && -n "${GCS_ACCESS_KEY_ID:-}" && -n "${GCS_ACCESS_KEY:-}" ]]; then
    BUCKET="$GCS_BUCKET"
    ACCESS_KEY_ID="$GCS_ACCESS_KEY_ID"
    ACCESS_KEY="$GCS_ACCESS_KEY"
    REGION="${GCS_REGION:-${STORAGE_REGION:-}}"
    echo "[INFO] Using GCS HMAC credentials from env vars (GCS_BUCKET, GCS_ACCESS_KEY_ID, GCS_ACCESS_KEY)"
elif command -v terraform &>/dev/null && [[ -d "$TF_DIR" ]] \
        && deployment="$(terraform -chdir="$TF_DIR" output -json deployment 2>/dev/null)" \
        && [[ -n "$deployment" ]]; then
    BUCKET=$(jq -r '.bucket // empty' <<<"$deployment")
    ACCESS_KEY_ID=$(jq -r '.access_key_id // empty' <<<"$deployment")
    ACCESS_KEY=$(jq -r '.access_key // empty' <<<"$deployment")
    REGION=$(jq -r '.region // empty' <<<"$deployment")
    if [[ -z "$BUCKET" || -z "$ACCESS_KEY_ID" || -z "$ACCESS_KEY" ]]; then
        echo "[ERROR] GCP Terraform deployment output lacks bucket or HMAC fields; re-run terraform apply" >&2
        exit 1
    fi
    echo "[INFO] Using GCS HMAC credentials from osmo GCP TF outputs"
else
    cat >&2 <<'MSG'
[ERROR] gcs backend (static auth) requires HMAC credentials. Provide either:

  GCS_BUCKET=<bucket-name>
  GCS_ACCESS_KEY_ID=<hmac-access-id>
  GCS_ACCESS_KEY=<hmac-secret>

Optional:
  GCS_REGION               (bucket location, e.g. asia-southeast1)
  STORAGE_ADDRESSING_STYLE (virtual|path|auto; default path)

or apply osmo GCP terraform (terraform/gcp/example) and let the script read
its `deployment` output. Create HMAC keys for a service account with
storage.objectAdmin on the bucket; user-account HMAC keys are not supported.
MSG
    exit 1
fi

ENDPOINT="gs://${BUCKET}"
# Path style keeps the bucket out of the TLS hostname, which is what the
# unified-chart deployment uses for GCS as well.
ADDRESSING_STYLE="${STORAGE_ADDRESSING_STYLE:-path}"
validate_addressing_style "$ADDRESSING_STYLE"

# 2. Best-effort existence check with the operator's gcloud identity. It does
#    not prove the HMAC key works; the smoke workflow does that.
if command -v gcloud &>/dev/null; then
    if gcloud storage buckets describe "gs://${BUCKET}" --format='value(name)' &>/dev/null; then
        echo "[INFO] Bucket $BUCKET exists"
    else
        echo "[WARN] gcloud cannot describe gs://${BUCKET}; continuing with the provided credentials"
    fi
else
    echo "[INFO] gcloud not available — skipping bucket existence check"
fi

# 3. Create 3 K8s Secrets, one per workflow_* credential reference.
create_workflow_cred_secrets "$ACCESS_KEY_ID" "$ACCESS_KEY" "$ENDPOINT" "$REGION" "" "$ADDRESSING_STYLE"

# 4. Emit Helm values fragment.
emit_static_values_fragment gcs "$ENDPOINT"

echo "[INFO] GCS storage configured (static HMAC auth):"
echo "       bucket:     $BUCKET"
echo "       endpoint:   $ENDPOINT"
echo "       region:     ${REGION:-<default>}"
echo "       addressing: $ADDRESSING_STYLE"
echo "       secrets:    osmo-workflow-{data,log,app}-cred in $NAMESPACE"
echo "       values:     $OUTPUT_VALUES"
