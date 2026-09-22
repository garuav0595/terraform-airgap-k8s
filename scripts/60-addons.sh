#!/usr/bin/env bash
#
# scripts/60-addons.sh
#
# Runs ONCE, on the first master only (main.tf phase 7), after every
# master and worker has joined. Installs ingress-nginx, the
# local-storage StorageClass, and node role labels.
#
# IDEMPOTENT (requirement #11): every step here is `kubectl apply` or
# `kubectl label --overwrite`, both of which converge to the same
# state no matter how many times they run.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

STAGE_DIR=""
ENABLE_INGRESS="true"
ENABLE_STORAGE="true"

usage() {
    echo "Usage: $(basename "$0") --stage-dir DIR [--enable-ingress true|false] [--enable-storage true|false]" >&2
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-dir)       STAGE_DIR="$2"; shift 2 ;;
        --enable-ingress)  ENABLE_INGRESS="$2"; shift 2 ;;
        --enable-storage)  ENABLE_STORAGE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done
[[ -n "${STAGE_DIR}" ]] || { usage; exit 1; }

echo "==> [60-addons] node role labels"
# kubeadm has not auto-labelled worker nodes since 1.20 -- do it
# ourselves so `kubectl get nodes` and node-role selectors (e.g. the
# ingress-nginx nodeSelector for control-plane) actually mean
# something, and so an operator can tell masters and workers apart
# at a glance.
kubectl get nodes -o name | sed 's#node/##' | while read -r node; do
    if kubectl get node "${node}" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' | grep -q .; then
        continue   # already a control-plane node, kubeadm labelled it itself
    fi
    kubectl label node "${node}" node-role.kubernetes.io/worker= --overwrite
done

if [[ "${ENABLE_STORAGE}" == "true" ]]; then
    echo "==> [60-addons] local-storage StorageClass"
    kubectl apply -f "${STAGE_DIR}/local-storage-sc.yaml"
fi

if [[ "${ENABLE_INGRESS}" == "true" ]]; then
    echo "==> [60-addons] ingress-nginx (hostNetwork DaemonSet, control-plane)"
    kubectl apply -f "${STAGE_DIR}/ingress-nginx-daemonset.yaml"
    kubectl -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=180s || true
fi

echo "==> [60-addons] done"
