# Egress proxy demo on kind

Hand-written manifests for what agentd-egress-proxy-controller writes for one organization (`org_Demo01`), one workspace (`wrk_Demo01`) and one cloud environment (`env_Demo01`). The `e2e` workflow (`.github/workflows/e2e.yml`) builds them on kind and checks the design end to end. It runs in CI only.

## What runs

| Namespace | Objects | Role |
|---|---|---|
| `org-demo` | none yet | The organization's namespace. |
| `ws-demo` | ServiceAccount `iron-proxy`, Certificate `iron-proxy-ca`, ConfigMap `proxy-env-demo-config`, Deployment, Service, NetworkPolicy and HorizontalPodAutoscaler `proxy-env-demo` | The workspace's proxy for `env_Demo01`: stock iron-proxy 0.59.0 pinned by digest, plus a reload watcher. |
| `sandboxes` | NetworkPolicy `sandbox-egress`, three sandbox pods | Sandbox stand-ins. Egress is denied except DNS and TCP 8080 to proxy namespaces. |
| `cert-manager` | Secret `agentd-root-ca`, ClusterIssuer `agentd-root-ca` | The root CA. It issues each workspace's intermediate CA. |
| `localstack` | LocalStack 4.9 | Stands in for AWS Secrets Manager. |
| `upstream` | HTTPS echo server behind `api`, `other` and `blocked` | Fake upstream that returns the headers it received. |

## How a request flows

1. A sandbox sends `CONNECT api.upstream.svc.cluster.local:8443` to `proxy-env-demo.ws-demo:8080`. The proxy's NetworkPolicy admits it only if the pod carries `agentd.dev/workspace: wrk_Demo01` and `agentd.dev/environment: env_Demo01`.
2. The allowlist checks the host. A host outside it gets `403`.
3. The proxy terminates TLS with a leaf certificate signed by the workspace intermediate. The sandbox trusts only the root, and the proxy sends the intermediate with each leaf.
4. On the credential's host, the `secrets` transform replaces the stand-in `agentd-ph-crd_Demo01` in any header with the value at `agentd/wrk_Demo01/vlt_Demo01/crd_Demo01` (JSON key `secret_value`) in Secrets Manager. On other hosts the stand-in passes through unchanged.
5. The proxy dials the upstream. `upstream_deny_cidrs` refuses internal addresses, including `169.254.169.254`, even for an allowed name.

## What the workflow checks

- The stand-in in a header is replaced with the real value on the allowed host.
- It is not replaced on another allowed host.
- A host outside the allowlist is refused with `403` at `CONNECT`.
- `169.254.169.254` is refused, by IP and through an allowed name that resolves to it.
- An unlabelled sandbox pod, and a pod labelled for another environment, cannot connect to the proxy.
- A labelled pod can connect, and cannot bypass the proxy.
- Deleting the intermediate CA Secret makes cert-manager issue a new one that chains to the root.
- A ConfigMap change reaches the running proxy through the watcher.

## Demo-only stand-ins

Each is marked `Demo:` where it appears.

- The root CA is made by `scripts/root-ca.sh`. In production External Secrets fills the same Secret from AWS Secrets Manager.
- The proxy reaches LocalStack through `AWS_ENDPOINT_URL` with dummy keys. In production it uses EKS Pod Identity.
- The proxy trusts the fake upstream's CA through `SSL_CERT_FILE`. In production it uses the image's system roots.
- `upstream_deny_cidrs` lets the proxy dial the kind pod subnet `10.244.0.0/16`, where the fake upstream runs. In production all of `10.0.0.0/8` is denied.
- The allowlist holds `metadata.demo.test`, which CoreDNS resolves to `169.254.169.254`.
- The management key Secret is made by `scripts/proxy.sh`. In production the controller makes it.

## Reload watcher

iron-proxy reloads its config on `POST /v1/reload` at the management listener, `127.0.0.1:9092`, with `Authorization: Bearer <IRON_MANAGEMENT_API_KEY>`. Stock `configmap-reload` has no flag for a request header, so the watcher is a shell loop in the same pinned iron-proxy image. It hashes the mounted config every 5 seconds and posts a reload when the hash changes, retrying until the reload succeeds.

## Scripts

Run in this order by the workflow: `install-cert-manager.sh`, `root-ca.sh`, `fixtures.sh`, `proxy.sh`, `assert.sh`. `dump.sh` prints cluster state when a step fails, without Secret data.
