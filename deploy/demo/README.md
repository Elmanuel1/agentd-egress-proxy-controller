# Egress proxy demo on kind

Hand-written manifests for what agentd-egress-proxy-controller writes for one organization (`org_Demo01`), one workspace (`wrk_Demo01`) and one cloud environment (`env_Demo01`), and the OpenTelemetry Collector they report to. `up.sh` builds them on a local kind cluster and checks the design end to end. The `e2e` workflow (`.github/workflows/e2e.yml`) runs the same script.

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

## Production shape and test settings

| Directory | Holds | Test-only settings |
|---|---|---|
| `workspace/`, `namespaces.yaml`, `root-issuer.yaml`, `sandboxes/egress.yaml` | What the controller and platform apply in production. | None. The hosts and credentials in `workspace/config.yaml` are the test pair's rows, as a real pair's rows would be. |
| `../observability/` | The Collector, as the platform runs it. | None. The platform supplies ConfigMap `otel-backend` (the backend's address and the one CA trusted for it) and the policy to reach its backend. |
| `test/workspace/` | Overlay on `workspace/`. | moto's endpoint and dummy keys, the fake upstream's CA, and egress to those two in-cluster stand-ins. |
| `test/observability/` | Overlay on `../observability/`. | Egress to the test backend. `scripts/observability.sh` makes the `otel-backend` ConfigMap with the test backend's address and CA. |
| `fixtures/`, `sandboxes/pods.yaml`, `scripts/` | Stand-ins and the checks. | All of it. |

## What runs

| Namespace | Objects | Role |
|---|---|---|
| `org-demo` | NetworkPolicy `default-deny` | The organization's namespace; no pods yet. |
| `ws-demo` | ServiceAccount `iron-proxy`, Certificate `iron-proxy-ca`, ConfigMap `proxy-env-demo-config`, Deployment, Service, NetworkPolicy and HorizontalPodAutoscaler `proxy-env-demo`, NetworkPolicy `default-deny` | The workspace's proxy for `env_Demo01`: stock iron-proxy 0.59.0 pinned by digest, plus a reload watcher. |
| `sandboxes` | NetworkPolicy `sandbox-egress`, three sandbox pods | Sandbox stand-ins. Egress is denied except DNS and TCP 8080 to proxy namespaces. |
| `cert-manager` | Secret and ClusterIssuer `agentd-root-ca` | The root CA. It issues each workspace's intermediate CA. |
| `observability` | OpenTelemetry Collector (contrib 0.165.0, 2 replicas, PodDisruptionBudget), Collector CA `agentd-otel-ca` (namespaced Issuer, apart from the agentd root), Certificate `otel-collector-tls` from it, NetworkPolicies | Receives the proxy's OTLP audit records over TLS on 4318, counts them into request metrics, and exports both to the backend. Only iron-proxy pods in proxy namespaces reach it. |
| `kube-system` | metrics-server 0.9.1 | Feeds the HorizontalPodAutoscaler. |
| `moto` | moto server 5.2.5 | Stands in for AWS Secrets Manager. Only proxy namespaces reach it. |
| `upstream` | HTTPS echo server, Service `echo` on external IP `203.0.113.10` | Fake upstream that returns the SHA-256 of each header it received, so no credential value reaches a sandbox. Only proxy namespaces reach it. |
| `otel-backend` | A second Collector | Stands in for the metrics and logs backend: receives OTLP/gRPC over TLS and writes it to stdout for the checks. |

## How a request flows

1. A sandbox sends `CONNECT api.upstream.test:443` to `proxy-env-demo.ws-demo:8080`. The proxy's NetworkPolicy admits it only if the pod carries `agentd.dev/workspace: wrk_Demo01` and `agentd.dev/environment: env_Demo01`.
2. The allowlist checks the host. A host outside it gets `403`.
3. The proxy terminates TLS with a leaf certificate signed by the workspace intermediate. The sandbox trusts only the root, and the proxy sends the intermediate with each leaf.
4. On the credential's host, the `secrets` transform replaces the stand-in `agentd-ph-crd_Demo01` in any header with the value at `agentd/wrk_Demo01/vlt_Demo01/crd_Demo01` (JSON key `secret_value`) in Secrets Manager. On other hosts the stand-in passes through unchanged.
5. The proxy dials the upstream. `upstream_deny_cidrs` refuses internal addresses, including `169.254.169.254`, even for an allowed name. The test hosts resolve to `203.0.113.10` (TEST-NET-3), a public address the production list allows; kube-proxy forwards it to the echo pod.
6. The proxy sends one OTLP log record per request to the Collector over HTTPS, checking the Collector's certificate against the Collector CA alone (ConfigMap `otel-ca` in the workspace namespace). A workspace intermediate, whose key sits in every proxy pod of its workspace, cannot sign a certificate the proxies accept for the Collector. `OTEL_RESOURCE_ATTRIBUTES` puts `agentd.workspace_id` and `agentd.environment_id` on every record.

## Network rules

Every namespace the demo owns denies traffic by default and opens only what each workload needs.

- Sandboxes reach cluster DNS and TCP 8080 in proxy namespaces only.
- A proxy admits only its labelled sandboxes on 8080. It reaches cluster DNS, the Collector on 4318, the EKS Pod Identity agent (`169.254.170.23` and `fd00:ec2::23` on 80) for its AWS credentials, and public addresses; private and link-local ranges are refused, and `upstream_deny_cidrs` decides per dial within what is left. The test overlay adds moto and the echo pod.
- The Collector admits iron-proxy pods from proxy namespaces on 4318 and reaches cluster DNS; the backend's policy comes with the backend.
- `cert-manager` and `kube-system` are installed from their upstream manifests without policies; their policies belong to the platform's install of them.

## Metrics

iron-proxy 0.59.0 exports audit log records, not metrics. Each record has `action` (`allow`, `reject` or `error`), `rejected_by` on a reject, `method`, and `request_transforms`: a list of `{name, action, duration_ms, annotations}`. The `secrets` transform's annotations hold `swapped` after a swap and `secret_unavailable` when a credential could not be read. The Collector turns them into metrics:

- `transform/flatten` sets the record attributes `swapped` and `secret_unavailable` to `true` when that annotation is in `request_transforms`.
- The `count` connector emits `egress_proxy_requests{action, rejected_by, swapped}`, with `rejected_by="none"` when nothing rejected the request. An allowed `CONNECT` only opens a tunnel and is not counted; the request inside it is.
- It also emits `egress_proxy_secret_failures`, the requests for which a credential could not be read.
- `transform/drop_tenant_ids` removes the workspace and environment ids from the metrics, so they stay on the logs only.
- `memory_limiter` and `batch` guard and group both pipelines; the `otlp_grpc` exporter queues and retries for up to 5 minutes when the backend is down.

The counts are delta sums, so a backend adds them up across both replicas.

## What the checks prove

- The stand-in in a header is replaced with the real value on the allowed host.
- It is not replaced on another allowed host, nor over plain HTTP to the allowed host (`require_tls`).
- A host outside the allowlist is refused with `403` at `CONNECT`.
- `169.254.169.254` is refused, by IP and through an allowed name that resolves to it.
- An unlabelled sandbox pod, and a pod labelled for another environment, cannot connect to the proxy.
- A labelled pod can connect, and cannot bypass the proxy to the upstream or to the internet (checked against a control request that does reach the internet from outside the sandbox policy).
- The HorizontalPodAutoscaler targets 1 to 5 replicas on CPU and memory at 70%, and reads live values for both from metrics-server.
- Deleting the intermediate CA Secret makes cert-manager issue a new one that chains to the root.
- A ConfigMap change reaches the running proxy through the watcher.
- A config the proxy rejects is logged at `ERROR` by the watcher, and the proxy keeps serving the last good config, not the startup one.
- A credential whose secret cannot be read leaves its stand-in in place and the request goes on.
- `egress_proxy_requests` counts exactly the requests the checks made: 1 allowed and swapped, 3 allowed and not swapped, 3 rejected by the allowlist, 1 failed dial. `egress_proxy_secret_failures` counts the 1 request whose secret could not be read.
- The log records carry the workspace and environment ids, and the metrics carry neither. The credential value never reaches the Collector or its backend.
- The Collector accepts only TLS: plain HTTP from the proxy gets `400`. A sandbox, and a pod with open egress that is not an iron-proxy pod, cannot connect to it.
- The Collector's certificate chains to the Collector CA and not to the agentd root; the proxies' OTLP trust is exactly the Collector CA, and the workspace intermediate does not chain to it.

## Not shown here

- Object names are short (`ws-demo`, `proxy-env-demo`). The controller derives them from the ids, as the plan's section 4 sets out.
- The controller puts a fingerprint of the management-key Secret, the intermediate CA Secret and the `otel-ca` ConfigMap in the pod template's annotations, so a change to any of them rolls the proxy pods. It also copies the Collector CA certificate into every `otel-ca` ConfigMap when cert-manager renews it, within the year before the old copy expires. These manifests carry no fingerprint, so after the CA restore check the running proxy keeps signing with the old intermediate, which still chains to the root.
- AWS itself: EKS Pod Identity and the tag-based IAM rule, External Secrets filling the root CA Secret from Secrets Manager, and KMS. The PR that adds the deploy chart proves them in a real AWS account.

## Stand-ins

- The root CA is made by `scripts/root-ca.sh`. In production External Secrets fills the same Secret from AWS Secrets Manager.
- The proxy reaches moto through `AWS_ENDPOINT_URL` with dummy keys (`test/workspace/`). In production it uses EKS Pod Identity.
- The proxy trusts the fake upstream's CA through `SSL_CERT_FILE` (`test/workspace/`). In production it uses the image's system roots.
- CoreDNS resolves the test hosts to `203.0.113.10` and `metadata.demo.test` to `169.254.169.254` (`scripts/fixtures.sh`).
- metrics-server runs with `--kubelet-insecure-tls`, because kind's kubelets serve self-signed certificates (`scripts/install-metrics-server.sh`).
- The management key Secret, and ConfigMap `otel-ca` with the Collector CA certificate, are made by `scripts/proxy.sh`. In production the controller makes both in each workspace namespace.

## Reload watcher

iron-proxy reloads its config on `POST /v1/reload` at the management listener, `127.0.0.1:9092`, with `Authorization: Bearer <IRON_MANAGEMENT_API_KEY>`. Stock `configmap-reload` has no flag for a request header, so the watcher is a shell loop in the same pinned iron-proxy image. It hashes the mounted config every 5 seconds and posts one reload per change. A failed reload is logged at `ERROR` with the proxy's answer; the proxy keeps its running config.

## Scripts

`up.sh` runs, in order: `scripts/install-cert-manager.sh`, `scripts/install-metrics-server.sh`, `scripts/root-ca.sh`, `scripts/fixtures.sh`, `scripts/observability.sh`, `scripts/proxy.sh`, `scripts/assert.sh` (it sources `scripts/assert-collector.sh`). The two install scripts and `dump.sh` can be rerun on their own; the others create objects once, so rerun them with `down.sh` then `up.sh`. `scripts/dump.sh` prints cluster state, without Secret data. Pinned versions, checksums and image digests live in `scripts/lib.sh`; third-party manifests are checked against their checksum and every image in them is pinned by digest before they are applied.
