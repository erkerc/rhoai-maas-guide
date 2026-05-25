MaaS

Red Hat OpenShift Container Platform Cluster (Multi-Cloud) - 6dqf7

Sources: https://github.com/rhpds/private-maas-automation/blob/main/platform/models-as-a-service/templates/ratelimitpolicy.yaml
https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/scripts/install-maas.sh

0. LWS - https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/components/operators/leader-worker-set/kustomization.yaml
0. Cert-Manager Operator - https://github.com/rh-aiservices-bu/rhoai-nightly/tree/main/components/operators/cert-manager
1. RHCL Subscription - https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/components/operators/connectivity-link/subscription.yaml
2. RHOAI 3.4 - https://github.com/redhat-cop/gitops-catalog/tree/main/openshift-ai/operator/base
3. RHOAI 3.4 DSC - https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/components/instances/rhoai-instance/base/datasciencecluster.yaml
4. RHOAI 3.4 ODHDashboardConfig - https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/components/instances/rhoai-instance/base/odh-dashboard-config.yaml

DOCS - https://docs.redhat.com/en/documentation/monitoring_stack_for_red_hat_openshift/4.20/html/configuring_user_workload_monitoring/preparing-to-configure-the-monitoring-stack-uwm#enabling-monitoring-for-user-defined-projects-uwm_preparing-to-configure-the-monitoring-stack-uwm
5. COO - https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/components/operators/cluster-observability-operator/kustomization.yaml
5.1 UWM - https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/bootstrap/cluster-monitoring-config/cluster-monitoring-config.yaml

DOCS - https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/deploy_models_using_distributed_inference_with_llm-d/configuring-authentication-for-llmd_distributed-inference
6. RHCL Config - https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/components/instances/connectivity-link-instance/base/kustomization.yaml
  https://github.com/opendatahub-io/models-as-a-service/issues/330

DOCS - https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas#maas-prerequisites_maas-deploy
7. https://github.com/rh-aiservices-bu/rhoai-nightly/tree/main/components/instances/maas-instance/chart/templates
PSQL 
GatewayClass
8. https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/components/instances/maas-instance/chart/templates/gatewayclass.yaml

(Optional) MetalLB if its Baremetal or OpenStack
https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking_operators/metallb-operator
(Route + MetalLB + Gateway) because ExternalLB pending

DOCS - https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas#configure-tls-for-maas_maas-deploy
TLS Authorino - https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/scripts/install-maas.sh#L249

Enable MaaS in DSC (also llamastack for genai)
  oc patch datasciencecluster default-dsc --type='merge' \
    -p='{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Managed"}}}}}'

  oc patch datasciencecluster default-dsc --type='merge' \
    -p='{"spec":{"components":{"llamastackoperator":{"managementState":"Managed"}}}}'

If you plan to use vLLM runtime with Models-as-a-Service, you have set spec.dashboardConfig.vLLMDeploymentOnMaaS to true in the OdhDashboardConfig custom resource.

10. Restart Kuadrant
https://github.com/rhpds/private-maas-automation/blob/main/platform/models-as-a-service/files/restart-kuadrant.sh

11. MaaS Setup Models
https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/scripts/setup-maas-model.sh
https://github.com/rh-aiservices-bu/rhoai-nightly/tree/main/components/instances/maas-models/simulator

12. MaaS Completions

  curl -k -X POST
  "https://maas.apps.cluster-4lwgc.dynamic2.redhatworkshops.io/llm/facebook-opt-125m-simulated/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer sk-oai-1FEohU8l0nqWF1lUo_9jOUCXBte4Ksso1vKqmrvZ3uMf1Knk9Tp6xkdL92BcI" \
    -d '{
      "model": "facebook/opt-125m",
      "messages": [
        {"role": "user", "content": "What is the capital of France?"}
      ],
      "max_tokens": 100,
      "temperature": 0.7
    }'