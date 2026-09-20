# Trusted-network Backend access

The standalone `service` and `backend-operator` charts support credential-free
operator connections on a trusted private network. The public gateway remains
on its existing listener. This option does not alter workflow runtime tokens or
the unified `osmo` chart's authentication configuration.

## Configuration

Control-plane overlay:

```yaml
gateway:
  trustedBackend:
    enabled: true
    port: 10081
```

Backend overlay:

```yaml
global:
  serviceUrl: http://osmo-gateway-backend.osmo.svc.cluster.local
  loginMethod: none
```

Adjust the gateway name and namespace for the installation. The new Service is
always ClusterIP. Public ingress and Cloudflare tunnels continue targeting the
ordinary gateway Service. Access to the private listener is the trust boundary;
any caller that can reach it receives the fixed Backend identity.

The listener accepts `/api/agent/` connections and GET requests to
`/api/configs/backend/{name}` and `/api/configs/backend_test/{name}`. Other routes
return 404. It removes caller credentials and workflow context, overwrites
identity headers with `osmo-backend`, and invokes existing role authorization
when `gateway.authz.enabled` is true.

The operator uses `--trust_network true`, skips credential loading and JWT
exchange, and retains in-cluster Kubernetes authentication. Its existing
WebSocket reconnect loop and progress probes remain active. A prolonged outage
can still cause probe-driven restarts.

## Verification

```bash
bazel test //src/operator/utils/tests:test_login \
  //src/lib/utils/tests:test_login \
  //src/lib/utils/tests:test_client \
  //src/service/core/auth/tests:test_backend_secret_auth
bash deployments/charts/service/tests/render-tests.sh
python3 deployments/charts/service/tests/test_trusted_backend_runtime.py
```

The runtime test uses Docker and `envoyproxy/envoy:v1.38.1` to exercise the
rendered listener against a local fixture. It checks credential-free WebSocket
handshakes, fixed identity headers, and rejection of unrelated routes and
configuration writes. The render tests verify that the public listener and
Service are unchanged and that operator credential mounts are omitted.

## GKE verification, 2026-09-20

Cluster context: `gke_pranalab-infra_asia-southeast1-b_osmo`.

- `osmo-minimal` upgraded from revision 8 to 9.
- `osmo-operator` upgraded from revision 3 to 4.
- Operator image tag: `6.4.0-prana-trusted-20260920-102740`.
- Both operator Deployments use the new internal Service, with no login Secret
  mount. Both new Pods were Ready with restart count 0 after the smoke workflow.
- Backend `default` reported `ONLINE`.
- Unauthenticated internal GET `/api/configs/backend/default` returned 200.
- Internal login/workflow requests and backend configuration writes returned 404.
- Unauthenticated public requests still returned the Cloudflare login redirect.
- CPU workflow `verify-trusted-backend-1` completed; task `hello` exited with 0
  on `gke-osmo-training-cpu-a4d57702-zi1g`.

The Python targets, chart render suite, and Envoy runtime tests passed. Ruff
baseline comparison found no new findings in the modified operator files; the
new chart test files passed Ruff.

Deployment used snapshots of the installed Helm charts with only the relevant
template changes and small overlays. The existing public Envoy listener and
upstream configuration were preserved. The gateway rolled because its config
checksum changed. The test-runner image was pinned to its existing tag, keeping
its task specification unchanged; its global-values checksum changed.

Local deployment evidence and chart snapshots are under
`~/.local/state/osmo-gcp/trusted-backend-20260920T102740/`. These private deployment
artifacts are not part of the repository.

## Rollback of this deployment

Restore the operators first, while both gateway entry points still exist:

```bash
helm rollback osmo-operator 3 -n osmo-operator --wait --timeout 10m
osmo backend list
helm rollback osmo-minimal 8 -n osmo --wait --timeout 10m
```

The original authentication Secrets were retained. After rollback, verify the
backend is online and rerun `deployments/workflows/verify-hello.yaml`.
