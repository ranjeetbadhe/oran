#!/bin/bash
# One-time hub setup for "Deploy applications". Run on the bastion, 'oc' logged in to the HUB as cluster-admin.
#
#   GITHUB_TOKEN_FILE=/root/github-ro-token  PULL_SECRET_FILE=/root/registry-auth.json \
#     bash hub-setup.sh https://github.com/<org>
#
#   https://github.com/<org>  the GitHub organisation (or user) holding the app repos. Apps are then added
#                      from the portal by repo URL; Argo CD accepts any repo under this org and nothing else.
#   GITHUB_TOKEN_FILE  read-only fine-grained PAT (Contents: Read) on the org's app repos
#                      -> Argo CD credential template for https://github.com/<org> (one secret for all repos)
#   PULL_SECRET_FILE   dockerconfigjson for the private registry -> hub secret rhacm-policies/private-registry
#                      (spread to the spokes by the per-app Policy; never stored in Git)
#   Both are OPTIONAL: without them, empty placeholders are created and the operator attaches the two files
#   in the portal (Settings). Contents are never printed. Re-runs keep whatever is already there.
#
# Then add apps in the portal (Deploy applications -> New application). Safe to run again. Changes nothing on the spokes and adds
# NO cluster to telco-sites (clusters join via the portal's "Mark provisioned", or label them yourself).
set -euo pipefail
ARG=${1:?usage: hub-setup.sh https://github.com/<org>}
[[ $ARG =~ ^https://github\.com/([A-Za-z0-9-]+)(/.*)?$ ]] || { echo "Expected https://github.com/<org>"; exit 1; }
ORG=${BASH_REMATCH[1]}; ORGURL="https://github.com/$ORG"
case "${ORG,,}" in *your*|*real-org*|*org-name*|org|example|acme|my-org) echo "'$ORG' is a placeholder: use your real GitHub organisation, e.g. https://github.com/tm-oran"; exit 1;; esac
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT_DIR:-$HERE}
say() { printf '\n== %s\n' "$*"; }

say "1/8 Hub check"
oc whoami >/dev/null
oc get multiclusterhub -A --no-headers | grep -q . || { echo "No MultiClusterHub: log in to the RHACM hub"; exit 1; }

say "2/8 OpenShift GitOps must be the Red Hat operator"
if oc get csv -A 2>/dev/null | grep -qi 'argocd-operator'; then
  echo "Community Argo CD operator (argocd-operator) found. This design needs Red Hat OpenShift GitOps only."; exit 1
fi
SUB=$(oc get subscriptions.operators.coreos.com -A -o jsonpath='{range .items[?(@.spec.name=="openshift-gitops-operator")]}{.metadata.namespace}/{.spec.source}{"\n"}{end}')
if [ -z "$SUB" ]; then
  echo "OpenShift GitOps not installed. Installing from redhat-operators..."
  oc apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata: {name: openshift-gitops-operator, labels: {openshift.io/cluster-monitoring: "true"}}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata: {name: openshift-gitops-operator, namespace: openshift-gitops-operator}
spec: {upgradeStrategy: Default}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: openshift-gitops-operator, namespace: openshift-gitops-operator}
spec: {channel: latest, installPlanApproval: Automatic, name: openshift-gitops-operator,
       source: redhat-operators, sourceNamespace: openshift-marketplace}
YAML
  SUB="openshift-gitops-operator/redhat-operators"
fi
case "$SUB" in */redhat-operators*) echo "OK: $SUB";; *) echo "Subscription source is '$SUB', expected redhat-operators"; exit 1;; esac
echo -n "waiting for Argo CD in openshift-gitops"
for i in $(seq 1 60); do oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1 && break; echo -n .; sleep 10; done; echo
oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=600s
oc rollout status deploy/openshift-gitops-applicationset-controller -n openshift-gitops --timeout=600s

say "3/8 telco-sites cluster set, bindings, placements, GitOpsCluster, acm-placement, AppProject, pull-secret policy"
if [ -n "${PULL_SECRET_FILE:-}" ]; then
  REGISTRIES=$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["auths"])))' "$PULL_SECRET_FILE")
else
  REGISTRIES=$(oc get cm telco-registries -n openshift-gitops -o jsonpath='{.data.hosts}' 2>/dev/null || true)
fi
echo "registry hosts in the pull secret: ${REGISTRIES:-none}"
for ns in rhacm-policies; do                      # namespaces must exist before the server-side dry run
  oc get ns "$ns" >/dev/null 2>&1 || oc create namespace "$ns"
done
sed -e "s#__ORG__#$ORG#g" -e "s#__REGISTRIES__#$REGISTRIES#g" "$HERE/00-telco-sites.yaml.tpl" > "$OUT/.rendered-00.yaml"
oc apply --dry-run=server -f "$OUT/.rendered-00.yaml" >/dev/null
oc apply -f "$OUT/.rendered-00.yaml"; rm -f "$OUT/.rendered-00.yaml"

say "4/8 Argo CD credential template for $ORGURL (all repos of the org)"
if [ -n "${GITHUB_TOKEN_FILE:-}" ]; then
  [ -s "$GITHUB_TOKEN_FILE" ] || { echo "$GITHUB_TOKEN_FILE is empty"; exit 1; }
  PWFILE="$GITHUB_TOKEN_FILE"
elif oc get secret telco-apps-github -n openshift-gitops >/dev/null 2>&1; then
  PWFILE=""; echo "kept existing token in telco-apps-github (uploaded/replaced in the portal: Settings)"
  OLDURL=$(oc get secret telco-apps-github -n openshift-gitops -o jsonpath='{.data.url}' | base64 -d)
  if [ "$OLDURL" != "$ORGURL" ]; then
    oc patch secret telco-apps-github -n openshift-gitops --type=merge \
      -p "{\"data\":{\"url\":\"$(echo -n "$ORGURL" | base64 -w0)\"}}" >/dev/null
    echo "credential URL changed: $OLDURL -> $ORGURL"
  fi
else
  PWFILE=$(mktemp); echo -n "upload-in-portal-settings" > "$PWFILE"
  echo "created placeholder: the operator uploads the GitHub access file in the portal (Settings)"
fi
if [ -n "$PWFILE" ]; then
  # A placeholder must NOT be active: Argo CD would send it to GitHub and break public repos of the org.
  # 'repo-creds-pending' is ignored by Argo CD; the portal switches it to 'repo-creds' when a real token is uploaded.
  TYPE=repo-creds; [ "$PWFILE" != "${GITHUB_TOKEN_FILE:-}" ] && TYPE=repo-creds-pending
  oc create secret generic telco-apps-github -n openshift-gitops --from-literal=type=git --from-literal=url="$ORGURL" \
     --from-literal=username=git --from-file=password="$PWFILE" --dry-run=client -o yaml |
    oc label --local -f - argocd.argoproj.io/secret-type=$TYPE -o yaml | oc apply -f - >/dev/null
  [ "$PWFILE" != "${GITHUB_TOKEN_FILE:-}" ] && rm -f "$PWFILE"
fi

say "5/8 Registry pull secret on the hub (rhacm-policies/private-registry)"
if [ -n "${PULL_SECRET_FILE:-}" ]; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "auths" in d' "$PULL_SECRET_FILE" ||
    { echo "$PULL_SECRET_FILE is not a dockerconfigjson (needs an \"auths\" key)"; exit 1; }
  oc create secret generic private-registry -n rhacm-policies --type=kubernetes.io/dockerconfigjson \
     --from-file=.dockerconfigjson="$PULL_SECRET_FILE" --dry-run=client -o yaml | oc apply -f - >/dev/null
  echo "private-registry applied (content not shown)"
elif oc get secret private-registry -n rhacm-policies >/dev/null 2>&1; then
  echo "kept existing private-registry (replaced in the portal: Settings)"
else
  oc create secret generic private-registry -n rhacm-policies --type=kubernetes.io/dockerconfigjson \
     --from-literal=.dockerconfigjson='{"auths":{}}' >/dev/null
  echo "created empty placeholder: the operator uploads the registry login file in the portal (Settings)"
fi

say "6/8 Portal ServiceAccount oran-apps-portal (least privilege)"
oc get ns oran-baremetal >/dev/null
oc apply -f "$HERE/portal-rbac.yaml"
for i in $(seq 1 15); do T=$(oc get secret oran-apps-portal-token -n oran-baremetal -o jsonpath='{.data.token}' 2>/dev/null); [ -n "$T" ] && break; sleep 2; done
umask 077; echo "$T" | base64 -d > "$OUT/oran-apps-token"
echo "token written to $OUT/oran-apps-token (mode 600, not shown). Copy it to the ansible server for install_portal.sh."

say "7/8 Labels-only guard for the portal account (ValidatingAdmissionPolicy)"
if oc apply --dry-run=server -f "$HERE/portal-labels-only.yaml" >/dev/null 2>"$OUT/.vap.err"; then
  oc apply -f "$HERE/portal-labels-only.yaml"
  MC=$(oc get managedclusters -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -vx local-cluster | head -1 || true)
  if [ -n "$MC" ]; then
    sleep 5; AS="--as=system:serviceaccount:oran-baremetal:oran-apps-portal"
    oc patch managedcluster "$MC" $AS --type=merge --dry-run=server -p '{"metadata":{"labels":{"app.oran/selftest":"enabled"}}}' >/dev/null \
      && echo "self-test 1 OK: app.oran/* label allowed (dry run on $MC)" || echo "self-test 1 FAILED: app label was refused"
    oc patch managedcluster "$MC" $AS --type=merge --dry-run=server -p '{"metadata":{"labels":{"vendor":"x"}}}' >/dev/null 2>&1 \
      && echo "self-test 2 FAILED: other label was allowed" || echo "self-test 2 OK: other labels refused"
    oc patch managedcluster "$MC" $AS --type=merge --dry-run=server -p '{"spec":{"hubAcceptsClient":false}}' >/dev/null 2>&1 \
      && echo "self-test 3 FAILED: spec change was allowed" || echo "self-test 3 OK: spec change refused"
  fi
  cat > "$OUT/.st-appset.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: oran-selftest, namespace: openshift-gitops, labels: {app.oran/app: oran-selftest}}
spec:
  generators: [{list: {elements: [{cluster: in-cluster}]}}]
  template:
    metadata: {name: 'oran-selftest-{{cluster}}'}
    spec: {project: default, source: {repoURL: $ORGURL/x, path: x, targetRevision: main},
           destination: {name: in-cluster, namespace: default}}
YAML
  oc apply --dry-run=server -f "$OUT/.st-appset.yaml" --as=system:serviceaccount:oran-baremetal:oran-apps-portal >/dev/null 2>&1 \
    && echo "self-test 4 FAILED: an ApplicationSet for the hub was allowed" || echo "self-test 4 OK: non-portal ApplicationSet refused"
  cat > "$OUT/.st-ok.yaml" <<YAML
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata: {name: oran-selftest-placement, namespace: openshift-gitops, labels: {app.oran/app: oran-selftest}}
spec: {clusterSets: [telco-sites], predicates: [{requiredClusterSelector: {labelSelector: {matchLabels: {app.oran/oran-selftest: enabled}}}}]}
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: oran-selftest, namespace: openshift-gitops, labels: {app.oran/app: oran-selftest}}
spec:
  generators:
    - clusterDecisionResource:
        configMapRef: acm-placement
        labelSelector: {matchLabels: {cluster.open-cluster-management.io/placement: oran-selftest-placement}}
  template:
    metadata: {name: 'oran-selftest-{{name}}'}
    spec:
      project: telco-apps
      source: {repoURL: $ORGURL/x.git, path: charts/x, targetRevision: main}
      destination: {server: '{{server}}', namespace: oran-selftest}
YAML
  oc apply --dry-run=server -f "$OUT/.st-ok.yaml" --as=system:serviceaccount:oran-baremetal:oran-apps-portal >/dev/null 2>"$OUT/.st-ok.err" \
    && echo "self-test 5 OK: portal-shaped Placement + ApplicationSet allowed" \
    || { echo "self-test 5 FAILED: the portal could not create a valid application:"; cat "$OUT/.st-ok.err"; }
  rm -f "$OUT/.st-appset.yaml" "$OUT/.st-ok.yaml" "$OUT/.st-ok.err"
  AS="--as=system:serviceaccount:oran-baremetal:oran-apps-portal"
  # The portal PATCHes directly (no GET first; it has no read right on secrets), so test exactly that.
  API=$(oc whoami --show-server); PT=$(cat "$OUT/oran-apps-token")
  SP="$API/api/v1/namespaces/openshift-gitops/secrets/telco-apps-github?dryRun=All"
  c6=$(curl -sk -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $PT" -H 'Content-Type: application/merge-patch+json' "$SP" \
       -d '{"metadata":{"labels":{"argocd.argoproj.io/secret-type":"repo-creds"}},"data":{"password":"dGVzdA=="}}')
  [ "$c6" = 200 ] && echo "self-test 6 OK: portal can replace the GitHub token (Settings)" || echo "self-test 6 FAILED: portal cannot update the GitHub token (HTTP $c6)"
  c7=$(curl -sk -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $PT" -H 'Content-Type: application/merge-patch+json' "$SP" -d '{"data":{"url":"aHR0cHM6Ly9ldmlsLmV4YW1wbGU="}}')
  [ "$c7" = 403 ] || [ "$c7" = 422 ] && echo "self-test 7 OK: credential URL locked (HTTP $c7)" || echo "self-test 7 FAILED: unexpected HTTP $c7 when changing the credential URL"
  unset PT
  oc get secret private-registry -n rhacm-policies $AS >/dev/null 2>&1 \
    && echo "self-test 8 FAILED: portal can READ the registry secret" || echo "self-test 8 OK: portal cannot read secrets back"
  for v in oran-apps-portal-labels-only oran-apps-portal-gitops-objects oran-apps-portal-credentials oran-apps-portal-registry-list; do
    w=$(oc get validatingadmissionpolicy $v -o jsonpath='{.status.typeChecking.expressionWarnings}' 2>/dev/null)
    [ -n "$w" ] && echo "WARNING $v type check: $w" || echo "type check OK: $v"
  done
else
  echo "WARNING: hub refused the ValidatingAdmissionPolicy; RBAC still limits the account to managedclusters patch:"
  cat "$OUT/.vap.err"
fi
rm -f "$OUT/.vap.err"

say "8/8 Result"
echo "Clusters in telco-sites:"; oc get managedclusters -l cluster.open-cluster-management.io/clusterset=telco-sites --no-headers 2>/dev/null | sed 's/^/  /' || true
oc get gitopscluster telco-gitops -n openshift-gitops -o jsonpath='{range .status.conditions[*]}  {.type}={.status} {.message}{"\n"}{end}' 2>/dev/null || true
echo "Argo CD: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
echo "Next: install_portal.sh on the ansible server with GITHUB_ORG=$ORG, then add apps from the portal."
