#!/bin/bash
set -euo pipefail

debug=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--debug)
      debug=true
      shift
      ;;
    *)
      echo "Usage: $0 [-d|--debug]" >&2
      exit 2
      ;;
  esac
done

KUBECONFIG="${KUBECONFIG:?KUBECONFIG must be set}"
export KUBECONFIG

if [[ -z "${PULLSECRET:-}" ]]; then
  read -r -p "Path to the pull-secret JSON file: " PULLSECRET
fi
if [[ ! -f "$PULLSECRET" || ! -r "$PULLSECRET" ]]; then
  echo "ERROR: Pull-secret file does not exist or is not readable: $PULLSECRET" >&2
  exit 1
fi

SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_rsa.pub"
if [[ ! -f "$SSH_PUBLIC_KEY_FILE" || ! -r "$SSH_PUBLIC_KEY_FILE" ]]; then
  echo "ERROR: SSH public key does not exist or is not readable: $SSH_PUBLIC_KEY_FILE" >&2
  exit 1
fi

ssh_public_key=$(<"$SSH_PUBLIC_KEY_FILE")
ssh_public_key=${ssh_public_key//$'\n'/}
if [[ -z "$ssh_public_key" ]]; then
  echo "ERROR: SSH public key is empty: $SSH_PUBLIC_KEY_FILE" >&2
  exit 1
fi

if ! pull_secret_base64=$(base64 -e "$PULLSECRET" 2>/dev/null); then
  pull_secret_base64=$(base64 -w 0 "$PULLSECRET")
fi
pull_secret_base64=${pull_secret_base64//$'\n'/}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

pull_secret_base64=$(escape_sed_replacement "$pull_secret_base64")
ssh_public_key=$(escape_sed_replacement "$ssh_public_key")

oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  channel: stable-4.22
  installPlanApproval: Automatic
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for LVM operator CSV to succeed..."
for i in $(seq 1 30); do
  csv=$(oc get csv -n openshift-storage 2>/dev/null | grep lvms || true)
  if echo "$csv" | grep -q "Succeeded"; then
    echo "$csv"
    echo "LVM operator installed successfully."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Timed out waiting for LVM operator CSV."
    exit 1
  fi
  sleep 10
done

echo "=== Creating LVMCluster ==="

oc apply -f - <<'EOF'
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
    - name: vg1
      default: true
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        overprovisionRatio: 10
      fstype: xfs
EOF

echo "Waiting for LVMCluster to become ready..."
for i in $(seq 1 30); do
  status=$(oc get lvmcluster lvmcluster -n openshift-storage -o jsonpath='{.status.ready}' 2>/dev/null || true)
  state=$(oc get lvmcluster lvmcluster -n openshift-storage -o jsonpath='{.status.state}' 2>/dev/null || true)
  if [ "$status" = "true" ]; then
    echo "LVMCluster is ready."
    break
  fi
  if [ "$state" = "Failed" ]; then
    echo "ERROR: LVMCluster failed." >&2
    oc get lvmcluster lvmcluster -n openshift-storage \
      -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}) {.message}{"\n"}{end}' >&2 || true
    oc describe lvmcluster lvmcluster -n openshift-storage >&2 || true
    oc get events -n openshift-storage --sort-by=.lastTimestamp >&2 || true
    exit 1
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Timed out waiting for LVMCluster (state: ${state:-unknown})." >&2
    oc get lvmcluster lvmcluster -n openshift-storage -o yaml >&2 || true
    exit 1
  fi
  sleep 10
done

echo "=== Verifying default StorageClass ==="
oc get sc

echo "=== Installing OpenShift Virtualization (CNV) ==="

oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for CNV operator CSV to succeed..."
for i in $(seq 1 60); do
  csv=$(oc get csv -n openshift-cnv 2>/dev/null | grep kubevirt-hyperconverged || true)
  if echo "$csv" | grep -q "Succeeded"; then
    echo "$csv"
    echo "CNV operator installed successfully."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: Timed out waiting for CNV operator CSV."
    exit 1
  fi
  sleep 10
done

echo "=== Creating HyperConverged CR ==="

oc apply -f - <<'EOF'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
EOF

echo "Waiting for HyperConverged to become available..."
for i in $(seq 1 60); do
  ready=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  progressing=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)
  echo "Attempt $i: Available=$ready Progressing=$progressing"
  if [ "$ready" = "True" ] && [ "$progressing" = "False" ]; then
    echo "HyperConverged is ready!"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: Timed out waiting for HyperConverged."
    exit 1
  fi
  sleep 15
done

echo "Installing cert-manager ..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.3/cert-manager.yaml
kubectl wait --for=condition=Available --timeout=300s deployment cert-manager -n cert-manager
kubectl wait --for=condition=Available deployment cert-manager-webhook -n cert-manager
kubectl wait --for=condition=Available deployment cert-manager-cainjector -n cert-manager

echo "Installing core CAPI and capk..."
clusterctl init --infrastructure kubevirt --bootstrap "-" --control-plane "-"

echo "=== Making CAPI controller compatible with OpenShift SCCs..."
for i in $(seq 1 60); do
  if oc get deployment capi-controller-manager -n capi-system >/dev/null 2>&1; then
    oc patch deployment capi-controller-manager -n capi-system --type=strategic \
      -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","securityContext":{"runAsUser":null,"runAsGroup":null}}]}}}}'
    oc rollout status deployment/capi-controller-manager -n capi-system --timeout=120s
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: Timed out waiting for CAPI controller deployment." >&2
    exit 1
  fi
  sleep 10
done

echo "Install openshift assisted capi provider ..."
oc apply -k capboa
oc apply -k capcoa

echo "Installing assisted service ..."
oc apply -k install_assisted
oc apply -f install_assisted/agentconfig.yaml

echo "=== Waiting for assisted-service to become available ..."
until oc wait --for=condition=available --timeout=300s deployment/assisted-service -n assisted-installer &>/dev/null; do
  echo "Deployment not ready or not created yet. Retrying in 5 seconds..."
  sleep 5
done
echo "assisted-service is available!"

oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: kubevirt-tenant
  labels:
    pod-security.kubernetes.io/enforce: privileged
EOF

oc create secret generic infra-cluster-credentials \
  --from-file=kubeconfig=$KUBECONFIG \
  -n kubevirt-tenant

echo "=== Deploying tenant cluster ==="
generated_manifest=$(mktemp "${TMPDIR:-/tmp}/capoa_capk_deploy.XXXXXX.yaml")
cleanup() {
  if [[ "$debug" == true ]]; then
    echo "Generated manifest preserved at: $generated_manifest"
  else
    rm -f "$generated_manifest"
  fi
}
trap cleanup EXIT
sed \
  -e "s|__PULL_SECRET_BASE64__|$pull_secret_base64|g" \
  -e "s|__SSH_PUBLIC_KEY__|$ssh_public_key|g" \
  capoa_capk_deploy.yaml >"$generated_manifest"
oc apply -f "$generated_manifest"

echo "=== Done ==="
