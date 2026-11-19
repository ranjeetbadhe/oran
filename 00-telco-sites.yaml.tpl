# One-time RHACM <-> OpenShift GitOps wiring for all telco sites. Applied by hub-setup.sh.
# __ORG__ = GitHub organisation/user that holds the app repos; __REGISTRIES__ = registry hosts in the pull secret.
apiVersion: v1
kind: Namespace
metadata: {name: rhacm-policies}
---
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata: {name: telco-sites}
spec:
  clusterSelector: {selectorType: ExclusiveClusterSetLabel}   # membership = label cluster.open-cluster-management.io/clusterset=telco-sites
---
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata: {name: telco-sites, namespace: openshift-gitops}
spec: {clusterSet: telco-sites}
---
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata: {name: telco-sites, namespace: rhacm-policies}
spec: {clusterSet: telco-sites}
---
# Every telco site, registered in Argo CD up front by GitOpsCluster telco-gitops.
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata: {name: all-telco, namespace: openshift-gitops}
spec:
  clusterSets: [telco-sites]
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - {key: name, operator: NotIn, values: [local-cluster]}
            - {key: local-cluster, operator: NotIn, values: ["true"]}
  tolerations:
    - {key: cluster.open-cluster-management.io/unreachable, operator: Exists}
    - {key: cluster.open-cluster-management.io/unavailable, operator: Exists}
---
apiVersion: apps.open-cluster-management.io/v1beta1
kind: GitOpsCluster
metadata: {name: telco-gitops, namespace: openshift-gitops}
spec:
  argoServer: {cluster: local-cluster, argoNamespace: openshift-gitops}
  placementRef: {kind: Placement, apiVersion: cluster.open-cluster-management.io/v1beta1, name: all-telco}
---
# Lets ApplicationSets use RHACM placement decisions as a cluster generator.
apiVersion: v1
kind: ConfigMap
metadata: {name: acm-placement, namespace: openshift-gitops}
data:
  apiVersion: cluster.open-cluster-management.io/v1beta1
  kind: placementdecisions
  statusListKey: decisions
  matchKey: clusterName
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: appset-read-placementdecisions, namespace: openshift-gitops}
rules:
  - apiGroups: [cluster.open-cluster-management.io]
    resources: [placementdecisions]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: appset-read-placementdecisions, namespace: openshift-gitops}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: appset-read-placementdecisions}
subjects:
  - {kind: ServiceAccount, name: openshift-gitops-applicationset-controller, namespace: openshift-gitops}
---
# Argo CD project for telco apps: only the GitHub app repo, never the hub itself.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: telco-apps, namespace: openshift-gitops}
spec:
  description: Applications deployed to telco sites (labels set from the O-RAN portal)
  sourceRepos: ["https://github.com/__ORG__/*"]          # any repo of this GitHub org, nothing else
  destinations:
    - {name: '*', namespace: '*', server: '*'}
    - {name: '!in-cluster', namespace: '*', server: '!https://kubernetes.default.svc'}
  clusterResourceWhitelist:
    - {group: '*', kind: '*'}
---
# Every telco site, for RHACM policies (image pull secret).
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata: {name: telco-all, namespace: rhacm-policies}
spec:
  clusterSets: [telco-sites]
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - {key: name, operator: NotIn, values: [local-cluster]}
            - {key: local-cluster, operator: NotIn, values: ["true"]}
  tolerations:
    - {key: cluster.open-cluster-management.io/unreachable, operator: Exists}
    - {key: cluster.open-cluster-management.io/unavailable, operator: Exists}
---
# Registry hosts covered by rhacm-policies/private-registry (host names only, no credentials).
# The portal checks an app's image.repository against this list before onboarding it.
apiVersion: v1
kind: ConfigMap
metadata: {name: telco-registries, namespace: openshift-gitops}
data:
  hosts: "__REGISTRIES__"
---
# ONE pull-secret policy for all apps: secret private-registry in every namespace labelled
# app.oran/pull-secret=true on every telco site. Argo CD creates each app namespace with that label
# (ApplicationSet managedNamespaceMetadata), so new apps need no new policy.
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: telco-pull-secret
  namespace: rhacm-policies
  annotations:
    policy.open-cluster-management.io/standards: NIST SP 800-53
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata: {name: telco-pull-secret}
        spec:
          remediationAction: enforce
          severity: high
          evaluationInterval: {compliant: 10m, noncompliant: 10s}
          namespaceSelector:
            matchLabels: {app.oran/pull-secret: "true"}
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Secret
                type: kubernetes.io/dockerconfigjson
                metadata: {name: private-registry}
                data:
                  .dockerconfigjson: '{{hub fromSecret "rhacm-policies" "private-registry" ".dockerconfigjson" hub}}'
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata: {name: telco-pull-secret, namespace: rhacm-policies}
placementRef: {apiGroup: cluster.open-cluster-management.io, kind: Placement, name: telco-all}
subjects:
  - {apiGroup: policy.open-cluster-management.io, kind: Policy, name: telco-pull-secret}
