# RHOAI Models-as-a-Service (MaaS) Guide

Guide to deploy RHOAI 3.4 Models-as-a-Service on OpenShift.

- Kustomize manifests with status gates between every phase
- Single automation script for end-to-end deployment
- CPU-only simulator model for validation without GPUs

Requires OpenShift 4.19+ with cluster-admin access.

## Phases

Each phase has its own README with step-by-step instructions, status gates, and troubleshooting.

| Phase | Description | Time |
|-------|-------------|------|
| [1. Prerequisites](01-prerequisites/README.md) | Operator subscriptions (RHOAI, RHCL, cert-manager, Service Mesh, LWS) | 5-10 min |
| [2. Platform Configuration](02-platform-config/README.md) | Kuadrant/Authorino, User Workload Monitoring, GatewayClass, Gateway | 5-10 min |
| [3. RHOAI Configuration](03-rhoai-config/README.md) | DataScienceCluster, DSCInitialization, Dashboard settings | 5-10 min |
| [4. MaaS Platform](04-maas-platform/README.md) | PostgreSQL database, Authorino TLS configuration | 5 min |
| [5. Model Deployment](05-maas-models/README.md) | Deploy and register LLM models with MaaS | 1-15 min |
| [6. Verification](06-verification/README.md) | End-to-end checks (API keys, inference, rate limiting) | 5 min |
| [7. Observability](07-observability/README.md) *(optional)* | COO subscription + Gateway telemetry dashboards | 5 min |

## Quick Start

A single script runs all phases end-to-end. Each phase is idempotent - re-running skips what is already done.

```bash
./scripts/setup-maas.sh
```

Resume from a specific phase after a failure:

```bash
./scripts/setup-maas.sh --from-phase 4
```

With observability (Cluster Observability Operator + Gateway telemetry):

```bash
./scripts/setup-maas.sh --with-observability
```

## Available Models

| Model | GPU Required | VRAM | Use Case |
|-------|-------------|------|----------|
| `simulator` | No | None | Testing/demo (CPU-only) |
| `granite-tiny-gpu` | Yes | < 40 GiB | Small GPU (T4, L4, A10) |
| `gpt-oss-20b` | Yes | >= 40 GiB | Large GPU (L40S, A100, H100) |

## Documentation

- [RHOAI 3.4 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas)
- [Upstream MaaS Documentation](https://opendatahub-io.github.io/models-as-a-service/latest/)
- [Upstream MaaS Architecture](https://opendatahub-io.github.io/models-as-a-service/latest/concepts/architecture/)

## License

See [LICENSE](LICENSE).
