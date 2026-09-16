#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_ROOT="${TEST_SRCDIR:?}/_main"
# shellcheck source=/dev/null
source "$REPO_ROOT/deployments/scripts/deploy-k8s.sh"

POSTGRES_HOST=postgres
POSTGRES_DB_NAME=osmo
POSTGRES_USERNAME=osmo
REDIS_HOST=redis
REDIS_PORT=6379
OSMO_IMAGE_TAG=6.4.0-prana-test
OSMO_CHART_DIR="$REPO_ROOT/deployments/charts"
OSMO_CHART_VERSION=ignored-in-local-mode
OSMO_SERVICE_HELM_VALUES_FILES=("$OSMO_CHART_DIR/service/tests/mcp-proxy-values.yaml")
OSMO_SERVICE_HELM_SET_VALUES=(gateway.authz.enabled=true)

fail() { echo "FAIL: $*" >&2; exit 1; }
require_contains() {
    [[ "$1" == *"$2"* ]] || fail "missing: $2"
}

[[ -z "$(chart_version_flag)" ]] || fail 'local chart must ignore remote version pin'
[[ "$(osmo_chart_reference service)" == "$OSMO_CHART_DIR/service" ]] || fail 'wrong chart'

for registry in osmo asia-southeast1-docker.pkg.dev/example-project/osmo; do
    OSMO_IMAGE_REGISTRY="$registry"
    OSMO_IMAGE_PULL_POLICY=""
    resolve_image_settings
    if [[ "$registry" == osmo ]]; then
        expected_policy=Never
    else
        expected_policy=Always
    fi
    [[ "$OSMO_IMAGE_PULL_POLICY" == "$expected_policy" ]] || fail 'wrong pull policy'
    service_manifest=$(render_osmo_service_chart)
    backend_manifest=$(render_backend_operator_chart)
    manifest="$service_manifest
$backend_manifest"

    for component in service agent logger router worker delayed-job-monitor web-ui \
                     authz-sidecar mcp backend-listener backend-worker backend-test-runner; do
        # Both Deployment containers and the embedded test-runner CronJob must
        # carry the matching pull policy in the same container mapping.
        awk -v expected="$registry/$component:$OSMO_IMAGE_TAG" -v policy="$expected_policy" '
            active && NF && match($0, /[^ ]/) < indentation { failed = 1; exit 1 }
            $1 == "image:" {
                if (active) { failed = 1; exit 1 }
                image = $2; gsub(/"/, "", image)
                if (image == expected) {
                    active = 1
                    indentation = match($0, /[^ ]/)
                }
            }
            active && $1 == "imagePullPolicy:" && match($0, /[^ ]/) == indentation {
                value = $2; gsub(/"/, "", value)
                if (value != policy) { failed = 1; exit 1 }
                found = 1; active = 0
            }
            END { if (!found || active || failed) exit 1 }
        ' <<< "$manifest" || fail "wrong image or policy for $component"
    done
    require_contains "$service_manifest" "client: $registry/client:$OSMO_IMAGE_TAG"
    require_contains "$service_manifest" "init: $registry/init-container:$OSMO_IMAGE_TAG"
    require_contains "$service_manifest" '        - default_ctrl
        - default_user
        - osmo_image_policy'
    require_contains "$service_manifest" "          - imagePullPolicy: $expected_policy
            name: osmo-ctrl"
    require_contains "$service_manifest" "          - imagePullPolicy: $expected_policy
            name: osmo-init"
    require_contains "$service_manifest" "cpu: '{{USER_CPU}}'"
    require_contains "$service_manifest" "nvidia.com/gpu: '{{USER_GPU}}'"

    # Third-party images keep their original names and pull policies.
    require_contains "$service_manifest" 'image: "envoyproxy/envoy:v1.38.1"
        imagePullPolicy: IfNotPresent'
    require_contains "$backend_manifest" 'image: "ubuntu:22.04"
                  imagePullPolicy: IfNotPresent'
    [[ "$manifest" != *nvcr.io/nvidia/osmo/* ]] || fail 'upstream OSMO image leaked'
    echo "PASS: $registry, $expected_policy, runtime templates and third-party images"
done

OSMO_IMAGE_PULL_POLICY=IfNotPresent
resolve_image_settings
require_contains "$(backend_operator_set_flags)" 'backendTestRunner.podTemplate.image.pullPolicy=IfNotPresent'

OSMO_IMAGE_PULL_POLICY=invalid
if resolve_image_settings >/dev/null 2>&1; then
    fail 'invalid pull policy accepted'
fi
OSMO_IMAGE_PULL_POLICY=Never
OSMO_IMAGE_TAG='invalid/tag'
if render_osmo_service_chart >/dev/null 2>&1; then
    fail 'invalid tag accepted'
fi
echo 'PASS: explicit policy override and invalid settings'
