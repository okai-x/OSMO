# OSMO on Google Cloud: development example

This example follows the Terraform examples inside OSMO. It manages its own
resources in an **existing project with billing enabled**; it does not read or
depend on the separate `infra` repository. It does not adopt existing clusters.

## Resources

- Dedicated VPC, private subnet, Cloud NAT and private service access.
- Zonal GKE Standard cluster, DNS control-plane endpoint, private nodes and
  Workload Identity Federation enabled. The CPU pool has two `e2-standard-4`
  nodes. `gpu_node_pool_enabled = true` adds a Spot GPU pool that scales from
  zero to `gpu_node_pool_max_size`; GKE installs the driver, so no GPU Operator
  is needed. GPU quota is per project and region, not per cluster.
  `training_node_pool_enabled = true` adds a `training-cpu` pool tainted
  `osmo-workload=training:NoSchedule` that starts at `training_node_pool_min_size`
  nodes (default 1) and autoscales up to `training_node_pool_max_size` (default 2)
  for pending pods. The autoscaler never raises an empty pool to its floor on its
  own, so raising the floor later needs a manual resize. OSMO workflow pods select
  the pool through the `cloud.google.com/gke-nodepool` label; platform services
  stay on the CPU pool.
- Private Cloud SQL PostgreSQL 16, zonal availability, backups and point-in-time
  recovery. The database uses `db-custom-2-7680`.
- Private Memorystore Redis 7.2, BASIC tier, 1 GiB, AUTH enabled. TLS is on by
  default; `redis_transit_encryption_mode = "DISABLED"` turns it off for clients
  that cannot trust the instance CA.
- Private GCS bucket, bucket-scoped storage service account and HMAC credentials.
  `bucket_force_destroy = true` lets `destroy` empty a non-empty bucket.
- GKE node service account with the default node role and Artifact Registry read
  access in the target project. Artifact Registry repositories/images are not created.

This is a development baseline, not a production HA configuration. Cloud SQL
accepts only encrypted connections (`ssl_mode = ENCRYPTED_ONLY`); clients
encrypt traffic without verifying the server identity against its private IP.

GCS uses HMAC because the current `GSBackend.data_auth` rejects default credentials.
Enabling GKE Workload Identity does not remove that application limitation.

## Prerequisites

Install Terraform >= 1.9 or compatible OpenTofu, Google Cloud CLI,
`gke-gcloud-auth-plugin`, `kubectl`, Helm, jq and the OSMO CLI. Configure both
gcloud login and Application Default Credentials for the intended identity.
That identity needs permission to enable APIs and manage the resources above,
including project IAM bindings, storage HMAC keys, and cluster administration.
Organization policies must allow HMAC keys and the selected location.

## Usage

`deployments/scripts/deploy-osmo-minimal.sh --provider gcp` drives this example
through `deployments/scripts/gcp/terraform.sh`. It writes `terraform.tfvars` in
this directory, runs `terraform init` and `apply`, reads the sensitive
`deployment` output, configures kubectl through the cluster's DNS endpoint and
installs OSMO with the `gcs` storage backend:

```bash
gcloud auth login
gcloud auth application-default login
deployments/scripts/deploy-osmo-minimal.sh --provider gcp \
  --project-id <existing-project-id> --gcp-region asia-southeast1 --cluster-name osmo-dev
```

The driver sets `redis_transit_encryption_mode = "DISABLED"` because the minimal
service chart trusts only public CAs, and `deletion_protection = false` plus
`bucket_force_destroy = true` so that `--destroy` removes the environment
completely. `--gpu-node-pool` enables the Spot GPU pool; `TF_GPU_MACHINE_TYPE`
and `TF_GPU_ACCELERATOR_TYPE` override its shape. `TF_TRAINING_NODE_POOL_ENABLED=true`
enables the training pool; `TF_TRAINING_MACHINE_TYPE`,
`TF_TRAINING_NODE_POOL_MIN_SIZE` and `TF_TRAINING_NODE_POOL_MAX_SIZE` override
its shape. Edit `terraform.tfvars` for any other variable and re-run.

Direct Terraform use works too: create `terraform.tfvars` with at least
`project_id` and `cluster_name`, then run `terraform init` and `terraform apply`
here. The `deployment` output carries every connection detail and credential;
never print or commit it.

## State and teardown

State lives in this directory as `terraform.tfstate`, excluded by the Terraform
`.gitignore`. It holds the PostgreSQL password, Redis AUTH string and HMAC secret
in plain text even though the output is marked sensitive; back it up securely
and move to a protected remote backend before sharing control. Deleting the
state does not delete cloud resources.

Nodes, managed databases, disks, NAT and stored data bill until destroyed.
`deploy-osmo-minimal.sh --provider gcp --destroy` runs `terraform destroy` with
the driver's tfvars. A manual `terraform destroy` with the variable defaults
stops at the protected cluster and database and at a non-empty bucket until
`deletion_protection` and `bucket_force_destroy` are changed.

## Local verification

```bash
terraform -chdir=deployments/terraform/gcp/example init -backend=false
terraform -chdir=deployments/terraform/gcp/example validate
bazel test //deployments/scripts/tests:test_gcp_terraform_driver
```

Validation checks syntax and schema only. Runtime acceptance is a successful
`deploy-osmo-minimal.sh --provider gcp` run including its smoke workflows.

## Training pool scale test

With `training_node_pool_enabled = true` and
`deployments/values/training-pool-gke.yaml` layered onto both charts,
`deployments/workflows/verify-scale-cpu.yaml` checks the autoscaling chain:
two gang-scheduled tasks whose pods together exceed one `e2-standard-4` node
stay pending until the cluster autoscaler adds a second training node, then
run and exit 0. Submit it with `osmo workflow submit`, then confirm the tasks
landed on two different `training-cpu` nodes, a `TriggeredScaleUp` event named
the pool, and the pool returned to `training_node_pool_min_size` nodes about
ten minutes after the workflow finished. Adding nodes by hand does not count as
a pass.
