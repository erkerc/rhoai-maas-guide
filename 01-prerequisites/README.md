# Phase 1: Prerequisites

Install the operator subscriptions required by Red Hat OpenShift AI (RHOAI) 3.4 Models as a Service (MaaS).

## Operator Overview

| Operator | Namespace | Purpose |
|----------|-----------|---------|
| Red Hat OpenShift AI (`rhods-operator`) | `redhat-ods-operator` | Core RHOAI platform -- model serving, dashboards, pipelines |
| Red Hat Connectivity Link (`rhcl-operator`) | `openshift-operators` | API gateway policies -- authentication (Authorino) and rate limiting (Limitador) for MaaS endpoints |
| cert-manager (`openshift-cert-manager-operator`) | `cert-manager-operator` | TLS certificate lifecycle management for serving endpoints |
| OpenShift Service Mesh 3 (`servicemeshoperator3`) | `openshift-operators` | Istio-based service mesh for inference traffic routing via Gateway API |
| Leader Worker Set (`leader-worker-set`) | `openshift-lws-operator` | Coordinates multi-replica workloads for distributed inference and training |

### Optional GPU Operators

| Operator | Namespace | Purpose |
|----------|-----------|---------|
| Node Feature Discovery (`nfd`) | `openshift-nfd` | Detects hardware features (GPUs, CPU flags) and labels nodes accordingly |
| NVIDIA GPU Operator (`gpu-operator-certified`) | `nvidia-gpu-operator` | Installs NVIDIA drivers, device plugin, and monitoring for GPU workloads |

## Installation

### Step 1: Install Required Operators

```bash
oc apply -k 01-prerequisites/operators/
```

This installs all five required operator subscriptions. OLM will resolve and install each operator automatically.

### Step 2 (Optional): Install GPU Operators

If your cluster has GPU nodes (or you plan to add them), install the GPU operators:

```bash
oc apply -k 01-prerequisites/gpu/
```

## Verification

### Wait for Operator CSVs to Succeed

After applying the subscriptions, wait for each operator's ClusterServiceVersion to reach the `Succeeded` phase.

**Required operators:**

```bash
oc wait csv -n redhat-ods-operator -l operators.coreos.com/rhods-operator.redhat-ods-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

oc wait csv -n openshift-operators -l operators.coreos.com/rhcl-operator.openshift-operators="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

oc wait csv -n cert-manager-operator -l operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

oc wait csv -n openshift-operators -l operators.coreos.com/servicemeshoperator3.openshift-operators="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

oc wait csv -n openshift-lws-operator -l operators.coreos.com/leader-worker-set.openshift-lws-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
```

**GPU operators (if installed):**

```bash
oc wait csv -n openshift-nfd -l operators.coreos.com/nfd.openshift-nfd="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s

oc wait csv -n nvidia-gpu-operator -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
```

### Verify CRDs Are Available

Check that the key CRDs have been registered:

```bash
# RHOAI
oc get crd datascienceclusters.datasciencecluster.opendatahub.io

# Connectivity Link / Kuadrant
oc get crd kuadrants.kuadrant.io

# cert-manager
oc get crd certificates.cert-manager.io

# Service Mesh 3
oc get crd istios.sailoperator.io

# Leader Worker Set
oc get crd leaderworkersets.leaderworkerset.x-k8s.io
```

### Quick Status Check

List all operator subscriptions and their current CSVs:

```bash
oc get subscriptions.operators.coreos.com -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,CSV:.status.currentCSV,STATE:.status.state'
```

## Directory Structure

```
01-prerequisites/
  operators/
    kustomization.yaml          # aggregates all operator subdirectories
    cert-manager/
    connectivity-link/
    leader-worker-set/
    rhoai-operator/
    service-mesh/
  gpu/
    kustomization.yaml          # aggregates NFD + NVIDIA
    nfd/
    nvidia-operator/
```

## References

- [RHOAI 3.4 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas)
- [Upstream MaaS Documentation](https://opendatahub-io.github.io/models-as-a-service/latest/)
- [RHOAI 3.4 Installation Guide](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/installing_and_uninstalling_openshift_ai_self-managed/index)
