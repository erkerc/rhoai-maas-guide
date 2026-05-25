# RHOAI Models-as-a-Service (MaaS) Guide

Self-contained guide for deploying **RHOAI 3.4 Models-as-a-Service** on OpenShift.

This guide uses **Kustomize-based deployment** (no ArgoCD required), includes **status gates at every phase boundary**, provides **automation scripts** for complex steps, and ships a **simulator model** for CPU-only testing.

## Prerequisites

| Requirement | Version |
|-------------|---------|
| OpenShift | 4.19+ |
| `oc` CLI | cluster-admin access |
| `kustomize` | 5.x (or use `oc kustomize`) |
| `envsubst` | from `gettext` |
| `jq` | any recent version |
| `curl` | any recent version |

---

## Phase Guide

### [Phase 1: Prerequisites](01-prerequisites/README.md)

> Install the operator subscriptions required by RHOAI 3.4 MaaS.

| Directory | Time |
|-----------|------|
| `01-prerequisites/` | 5-10 min |

```bash
oc apply -k 01-prerequisites/operators/
```

---

### [Phase 2: Platform Configuration](02-platform-config/README.md)

> Configure Kuadrant/Authorino (auth and rate limiting), User Workload Monitoring, GatewayClass, and the MaaS Gateway.

| Directory | Time |
|-----------|------|
| `02-platform-config/` | 5-10 min |

```bash
oc apply -k 02-platform-config/kuadrant/
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=120s
oc apply -k 02-platform-config/uwm/
oc apply -f 02-platform-config/gatewayclass.yaml

export CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || echo "router-certs-default")
envsubst '${CLUSTER_DOMAIN} ${CERT_NAME}' < 02-platform-config/gateway.yaml.tmpl | oc apply -f -
```

---

### [Phase 3: RHOAI Configuration](03-rhoai-config/README.md)

> Configure the RHOAI operator instances — DataScienceCluster, DSCInitialization, and Dashboard settings.

| Directory | Time |
|-----------|------|
| `03-rhoai-config/` | 5-10 min |

```bash
oc apply -k 03-rhoai-config/
```

---

### [Phase 4: MaaS Platform Infrastructure](04-maas-platform/README.md)

> Deploy the PostgreSQL database and configure Authorino TLS for the MaaS platform.

| Directory | Time |
|-----------|------|
| `04-maas-platform/` | 5 min |

```bash
./scripts/setup-maas.sh --from-phase 4
```

---

### [Phase 5: Model Deployment](05-maas-models/README.md)

> Deploy LLM models and register them with MaaS — use the simulator for CPU-only testing, or GPU models for production workloads.

| Directory | Time |
|-----------|------|
| `05-maas-models/` | 1-15 min |

```bash
./scripts/deploy-model.sh --model simulator
```

---

### [Phase 6: Verification](06-verification/README.md)

> Run end-to-end verification of the MaaS deployment (tenants, API keys, inference, rate limiting).

| Directory | Time |
|-----------|------|
| `06-verification/` | 5 min |

```bash
./06-verification/verify.sh
```

---

### [Phase 7: Observability](07-observability/README.md) *(Optional)*

> Add observability enhancements on top of UWM — Cluster Observability Operator and Gateway telemetry dashboards.

| Directory | Time |
|-----------|------|
| `07-observability/` | 5 min |

```bash
# Included automatically when using the all-in-one script with --with-observability
./scripts/setup-maas.sh --with-observability
```

---

## Quick Start: All-in-One

A single script handles the entire lifecycle — from operator installation through model deployment and verification. Each phase is idempotent; re-running skips what's already done.

```bash
./scripts/setup-maas.sh
```

With observability:

```bash
./scripts/setup-maas.sh --with-observability
```

Resume from a specific phase (e.g. after a Phase 4 failure):

```bash
./scripts/setup-maas.sh --from-phase 4
```

## Available Models

| Model | GPU Required | VRAM | Use Case |
|-------|-------------|------|----------|
| `simulator` | No | None | Testing/demo (CPU-only) |
| `granite-tiny-gpu` | Yes | < 40 GiB | Small GPU (T4, L4, A10) |
| `gpt-oss-20b` | Yes | >= 40 GiB | Large GPU (L40S, A100, H100) |

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup-maas.sh` | End-to-end orchestrator — all 7 phases with state detection |
| `scripts/deploy-model.sh` | Deploy model with GPU auto-detection |
| `scripts/verify-maas.sh` | E2E verification wrapper |

## CRD Reference

All CRDs belong to API group `maas.opendatahub.io/v1alpha1`.

| CRD | Namespace | Purpose |
|-----|-----------|---------|
| MaaSModelRef | Same as LLMInferenceService (e.g., `llm`) | Register model for MaaS |
| MaaSAuthPolicy | `models-as-a-service` | Define access policies |
| MaaSSubscription | `models-as-a-service` | Rate limits per tier |
| Tenant | `models-as-a-service` | Auto-bootstrapped by controller |

## Documentation

- [RHOAI 3.4 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas)
- [Upstream MaaS Documentation](https://opendatahub-io.github.io/models-as-a-service/latest/)
- [Upstream MaaS Architecture](https://opendatahub-io.github.io/models-as-a-service/latest/concepts/architecture/)

## License

See [LICENSE](LICENSE).
