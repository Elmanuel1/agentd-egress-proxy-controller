# Egress proxy demo on kind

Hand-written manifests for what agentd-egress-proxy-controller writes for one organization (`org_Demo01`), one workspace (`wrk_Demo01`) and one cloud environment (`env_Demo01`). `up.sh` builds them on a local kind cluster and checks the design end to end. The `e2e` workflow (`.github/workflows/e2e.yml`) runs the same script.

## Run it

Needs Docker with about 4 GB of memory free, kind, kubectl, openssl, jq and curl. It works on macOS (Apple silicon or Intel) and Linux.

```bash
deploy/demo/up.sh
```

`up.sh` creates the kind cluster `epc-demo`, installs everything below and runs the checks, in about five minutes. It writes the cluster's kubeconfig to `~/.cache/epc-demo/kubeconfig` (or `$EPC_DEMO_KUBECONFIG`) and never changes your current kubectl context. To look around afterwards:

```bash
export KUBECONFIG=~/.cache/epc-demo/kubeconfig
```

Delete the cluster with:

```bash
deploy/demo/down.sh
```

## What runs

| Namespace | Objects | Role |
|---|---|---|
| `org-demo` | none yet | The organization's namespace. |
| `ws-demo` | ServiceAccount `iron-proxy`, Certificate `iron-proxy-ca`, ConfigMap `proxy-env-demo-config`, Deployment, Service, NetworkPolicy and HorizontalPodAutoscaler `proxy-env-demo` | The workspace's proxy for `env_Demo01`: stock iron-proxy 0.59.0 pinned by digest, plus a reload watcher. |
| `sandboxes` | NetworkPolicy `sandbox-egress`, three sandbox pods | Sandbox stand-ins. Egress is denied except DNS and TCP 8080 to proxy namespaces. |
| `cert-manager` | Secret `agentd-root-ca`, ClusterIssuer `agentd-root-ca` | The root CA. It issues each workspace's intermediate CA. |
| `moto` | moto server 5.2.5 | Stands in for AWS Secrets Manager. |
| `upstream` | HTTPS echo server behind `api`, `other`, `blocked` and `missing` | Fake upstream that returns the SHA-256 of each header it received, so no credential value reaches a sandbox. |
| `observability` | OpenTelemetry Collector (contrib 0.165.0) and its NetworkPolicy, from `deploy/observability/collector.yaml` | Receives the proxy's OTLP audit log records on 4318 and counts them into request metrics. Only iron-proxy pods in proxy namespaces reach it. |

## How a request flows

1. A sandbox sends `CONNECT api.upstream.svc.cluster.local:8443` to `proxy-env-demo.ws-demo:8080`. The proxy's NetworkPolicy admits it only if the pod carries `agentd.dev/workspace: wrk_Demo01` and `agentd.dev/environment: env_Demo01`.
2. The allowlist checks the host. A host outside it gets `403`.
3. The proxy terminates TLS with a leaf certificate signed by the workspace intermediate. The sandbox trusts only the root, and the proxy sends the intermediate with each leaf.
4. On the credential's host, the `secrets` transform replaces the stand-in `agentd-ph-crd_Demo01` in any header with the value at `agentd/wrk_Demo01/vlt_Demo01/crd_Demo01` (JSON key `secret_value`) in Secrets Manager. On other hosts the stand-in passes through unchanged.
5. The proxy dials the upstream. `upstream_deny_cidrs` refuses internal addresses, including `169.254.169.254`, even for an allowed name.
6. The proxy sends one OTLP log record per request to the Collector. `OTEL_RESOURCE_ATTRIBUTES` puts `agentd.workspace_id` and `agentd.environment_id` on every record.

## Metrics

iron-proxy 0.59.0 exports audit log records, not metrics. Each record has `action` (`allow`, `reject` or `error`), `rejected_by` on a reject, `method`, and `request_transforms`: a list of `{name, action, duration_ms, annotations}`. The `secrets` transform's annotations hold `swapped` after a swap and `secret_unavailable` when a credential could not be read. The Collector turns them into metrics:

- `transform/flatten` sets the record attributes `swapped` and `secret_unavailable` to `true` when that annotation is in `request_transforms`.
- The `count` connector emits `egress_proxy_requests{action, rejected_by, swapped}`, with `rejected_by="none"` when nothing rejected the request. An allowed `CONNECT` only opens a tunnel and is not counted; the request inside it is.
- It also emits `egress_proxy_secret_failures`, the requests for which a credential could not be read.
- `transform/drop_tenant_ids` removes the workspace and environment ids from the metrics, so they stay on the logs only.

The demo's `file` exporter writes the records and metrics as OTLP JSON to the Collector's stdout, where the checks read them. A deployment replaces it with an `otlp` exporter to its own backends.

## What the checks prove

- The stand-in in a header is replaced with the real value on the allowed host.
- It is not replaced on another allowed host, nor over plain HTTP to the allowed host (`require_tls`).
- A host outside the allowlist is refused with `403` at `CONNECT`.
- `169.254.169.254` is refused, by IP and through an allowed name that resolves to it.
- An unlabelled sandbox pod, and a pod labelled for another environment, cannot connect to the proxy.
- A labelled pod can connect, and cannot bypass the proxy to the upstream or to the internet (checked against a control request that does reach the internet from outside the sandbox policy).
- The HorizontalPodAutoscaler scales the proxy from 1 to 5 replicas on CPU and memory at 70%.
- Deleting the intermediate CA Secret makes cert-manager issue a new one that chains to the root.
- A ConfigMap change reaches the running proxy through the watcher.
- A config the proxy rejects is logged at `ERROR` by the watcher, and the proxy keeps serving the last good config, not the startup one.
- A credential whose secret cannot be read leaves its stand-in in place and the request goes on.
- `egress_proxy_requests` counts exactly the requests the checks made: 1 allowed and swapped, 3 allowed and not swapped, 3 rejected by the allowlist, 1 failed dial. `egress_proxy_secret_failures` counts the 1 request whose secret could not be read.
- The log records carry the workspace and environment ids, and the metrics carry neither. The credential value never reaches the Collector, and a sandbox cannot connect to it.

## Not shown here

- Object names are short (`ws-demo`, `proxy-env-demo`). The controller derives them from the ids, as the plan's section 4 sets out.
- The controller puts a fingerprint of the management-key Secret and the intermediate CA Secret in the pod template's annotations, so a change to either rolls the proxy pods. These manifests carry no fingerprint, so after the CA restore check the running proxy keeps signing with the old intermediate, which still chains to the root.

## Demo-only stand-ins

Each is marked `Demo:` where it appears.

- The root CA is made by `scripts/root-ca.sh`. In production External Secrets fills the same Secret from AWS Secrets Manager.
- The proxy reaches moto through `AWS_ENDPOINT_URL` with dummy keys. In production it uses EKS Pod Identity.
- The proxy trusts the fake upstream's CA through `SSL_CERT_FILE`. In production it uses the image's system roots.
- `upstream_deny_cidrs` lets the proxy dial the kind pod subnet `10.244.0.0/16`, where the fake upstream runs. In production all of `10.0.0.0/8` is denied.
- The allowlist holds `metadata.demo.test`, which CoreDNS resolves to `169.254.169.254`.
- The allowlist holds `missing.upstream.svc.cluster.local`, the host of a second credential whose secret was never written to Secrets Manager.
- The Collector's `file` exporter writes to stdout for the checks.
- The management key Secret is made by `scripts/proxy.sh`. In production the controller makes it.

## Reload watcher

iron-proxy reloads its config on `POST /v1/reload` at the management listener, `127.0.0.1:9092`, with `Authorization: Bearer <IRON_MANAGEMENT_API_KEY>`. Stock `configmap-reload` has no flag for a request header, so the watcher is a shell loop in the same pinned iron-proxy image. It hashes the mounted config every 5 seconds and posts one reload per change. A failed reload is logged at `ERROR` with the proxy's answer; the proxy keeps its running config.

## Scripts

`up.sh` runs, in order: `scripts/install-cert-manager.sh`, `scripts/root-ca.sh`, `scripts/fixtures.sh`, `scripts/observability.sh`, `scripts/proxy.sh`, `scripts/assert.sh` (it sources `scripts/assert-collector.sh`). `install-cert-manager.sh` and `dump.sh` can be rerun on their own; the others create objects once, so rerun them with `down.sh` then `up.sh`. `scripts/dump.sh` prints cluster state, without Secret data. Pinned versions live in `scripts/lib.sh`.
