<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# OSMO Deployment Helm Values

Static, user-editable values files consumed by [`scripts/deploy-osmo-minimal.sh`](../scripts/deploy-osmo-minimal.sh).

The deploy script orchestrates `helm install` — these YAML files hold the values that don't change per-cluster. Per-cluster values (PG/Redis hosts, image tag, namespace, NGC pull secret name) are injected with `--set` at install time so users don't need to edit YAML for routine deploys.

To customize defaults beyond what `--set` covers, edit these files directly.

The minimal values use `INFO` application logging and reserve CPU and memory
for the control-plane services. Size requests and limits for your workload;
these defaults are a starting point for small deployments. The backend listener
allows 30 seconds per liveness check and requires three consecutive failures
before restarting. The chart exposes these settings under
`services.backendListener.livenessProbe` and `services.backendWorker.livenessProbe`;
without the minimal values, the historical probe settings remain unchanged.

When updating an existing deployment, layer only the settings being changed
onto its retained values. Applying this entire base file last can overwrite
cluster-specific settings such as Redis TLS and workflow pod templates.

## Files

| File | Loaded when | Purpose |
|---|---|---|
| `service.yaml` | Always | Base values for the `service` chart (now bundles router + UI). Mirrors the [docs minimal-deploy values](../../docs/deployment_guide/appendix/deploy_minimal.rst). |
| `backend-operator.yaml` | Always | Base values for the `backend-operator` chart. |
| `gpu-pool.yaml` | When GPU nodes are detected (or `--gpu-node-pool`) | Adds `gpu_toleration` pod template + GPU platform on the default pool. |
| `gpu-pool-gke.yaml` | `--provider gcp` with GKE accelerator nodes (or `--gpu-node-pool`) | Same platform wiring keyed on GKE's `cloud.google.com/gke-accelerator` label; GKE supplies the driver, so no GPU Operator labels exist. |
| `pod-monitor-on.yaml` | When prometheus-operator CRDs are detected (or `OSMO_POD_MONITOR_ENABLED=true`) | Re-enables PodMonitor scraping. Off by default to avoid CRD-not-installed errors. |
| `training-pool-gke.yaml` | Only when passed explicitly: `--helm-values values/training-pool-gke.yaml` | Pins platform components to the GKE `cpu` pool and adds the `training_cpu` pod template (nodeSelector + taint toleration) to the default pool's `default` platform, so only `training-cpu` nodes count toward it. Pairs with `training_node_pool_enabled` in the GCP Terraform example. |

In addition, the storage backend script ([`scripts/configure-storage.sh`](../scripts/configure-storage.sh)) writes a runtime fragment to `scripts/values/.storage-values.yaml` — that file is auto-generated and should not be hand-edited; it carries the workflow credential references for the backend you selected (`minio` / `azure-blob` / `s3` / `gcs` / `byo`).

## Layering order

`helm install` applies values in argument order; later files override earlier ones. The deploy script uses:

```
-f values/service.yaml
[-f values/pod-monitor-on.yaml]               # if CRDs detected
[-f values/gpu-pool.yaml]                     # if GPU nodes detected (gpu-pool-gke.yaml on GKE)
-f scripts/values/.storage-values.yaml         # runtime-rendered storage fragment
--set global.osmoImageLocation=...             # cluster-specific overrides
--set global.osmoImageTag=...
--set services.postgres.serviceName=...
--set services.redis.serviceName=...
... etc
[-f user-provided-values.yaml]                 # --helm-values / --service-helm-values
[--set user.provided=value]                    # --helm-set / --service-helm-set
```

The backend-operator chart uses the same pattern: `values/backend-operator.yaml`,
then generated per-cluster `--set` overrides, then `--helm-values` /
`--backend-operator-helm-values`.

## Security note: minimal mode auth

`service.yaml` ships with `gateway.oauth2Proxy.enabled: false` and `gateway.authz.enabled: false` — matching the [minimal deploy docs](../../docs/deployment_guide/appendix/deploy_minimal.rst). The gateway then trusts client-supplied `x-osmo-{user,roles,allowed-pools}` headers. **Do not expose this gateway to untrusted networks.** For production, use the standard deploy guide which keeps OAuth2 + authz enabled.
