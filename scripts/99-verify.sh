#!/usr/bin/env bash
#
# scripts/99-verify.sh
#
# Runs ONCE, on the first master only (main.tf phase 8, the final
# phase). Prints a health report and, critically, EXITS NON-ZERO ON
# ANY FAILURE -- remote-exec provisioner failures fail the
# `terraform apply` itself, so a cluster that looks fine but isn't
# (a node stuck NotReady, a CrashLooping CoreDNS, a missing etcd
# member) is caught here rather than being handed to whoever runs
# this next as "done".
set -uo pipefail   # deliberately not -e: we want to run every check
                    # and report all failures, not bail on the first
export KUBECONFIG=/etc/kubernetes/admin.conf

EXPECT_NODES=""
API_VIP=""
API_VIP_PORT=""
MANAGE_VIP="true"

usage() {
    echo "Usage: $(basename "$0") --expect-nodes N [--api-vip IP --api-vip-port PORT] [--manage-vip true|false]" >&2
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect-nodes) EXPECT_NODES="$2"; shift 2 ;;
        --api-vip)      API_VIP="$2"; shift 2 ;;
        --api-vip-port) API_VIP_PORT="$2"; shift 2 ;;
        --manage-vip)   MANAGE_VIP="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done
[[ -n "${EXPECT_NODES}" ]] || { usage; exit 1; }

FAILED=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILED=1; }

echo "==> [99-verify] cluster health report"

echo "-- nodes --"
kubectl get nodes -o wide || fail "kubectl get nodes failed"
NOT_READY="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"' | wc -l)"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
if [[ "${NOT_READY}" -eq 0 && "${TOTAL_NODES}" -eq "${EXPECT_NODES}" ]]; then
    pass "${TOTAL_NODES}/${EXPECT_NODES} nodes Ready"
else
    fail "${TOTAL_NODES}/${EXPECT_NODES} nodes present, ${NOT_READY} not Ready"
fi

echo "-- kube-system pods --"
kubectl -n kube-system get pods -o wide || fail "kubectl get pods -n kube-system failed"
BAD_PODS="$(kubectl -n kube-system get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)"
if [[ "${BAD_PODS}" -eq 0 ]]; then
    pass "all kube-system pods Running/Completed"
else
    fail "${BAD_PODS} kube-system pod(s) not Running/Completed"
fi

echo "-- CoreDNS --"
COREDNS_READY="$(kubectl -n kube-system get deploy coredns -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [[ "${COREDNS_READY:-0}" -ge 1 ]]; then
    pass "CoreDNS has ${COREDNS_READY} ready replica(s)"
else
    fail "CoreDNS has no ready replicas"
fi

echo "-- Calico --"
CALICO_DESIRED="$(kubectl -n kube-system get ds calico-node -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
CALICO_READY="$(kubectl -n kube-system get ds calico-node -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
if [[ "${CALICO_DESIRED:-0}" -gt 0 && "${CALICO_READY}" == "${CALICO_DESIRED}" ]]; then
    pass "calico-node ${CALICO_READY}/${CALICO_DESIRED} ready"
else
    fail "calico-node ${CALICO_READY:-0}/${CALICO_DESIRED:-0} ready"
fi

echo "-- etcd membership --"
ETCD_MEMBERS="$(kubectl -n kube-system exec -i "$(kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}')" -- \
    sh -c 'ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list' 2>/dev/null | wc -l)"
EXPECT_MASTERS="${EXPECT_MASTERS:-}"
if [[ -n "${ETCD_MEMBERS}" && "${ETCD_MEMBERS}" -gt 0 ]]; then
    pass "etcd reports ${ETCD_MEMBERS} member(s)"
else
    fail "could not enumerate etcd members"
fi

if [[ "${MANAGE_VIP}" == "true" && -n "${API_VIP}" ]]; then
    echo "-- API VIP --"
    if curl --silent --insecure --max-time 5 --output /dev/null "https://${API_VIP}:${API_VIP_PORT}/healthz"; then
        pass "VIP ${API_VIP}:${API_VIP_PORT} answering /healthz"
    else
        fail "VIP ${API_VIP}:${API_VIP_PORT} not answering -- check haproxy/keepalived (systemctl status haproxy keepalived; ip -4 -o addr show)"
    fi
fi

echo "-- ingress-nginx (if enabled) --"
if kubectl get ns ingress-nginx >/dev/null 2>&1; then
    ING_DESIRED="$(kubectl -n ingress-nginx get ds ingress-nginx-controller -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
    ING_READY="$(kubectl -n ingress-nginx get ds ingress-nginx-controller -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
    if [[ "${ING_DESIRED:-0}" -gt 0 && "${ING_READY}" == "${ING_DESIRED}" ]]; then
        pass "ingress-nginx-controller ${ING_READY}/${ING_DESIRED} ready"
    else
        fail "ingress-nginx-controller ${ING_READY:-0}/${ING_DESIRED:-0} ready"
    fi
else
    echo "  [SKIP] ingress-nginx not installed"
fi

echo "=================================================="
if [[ "${FAILED}" -eq 0 ]]; then
    echo "==> [99-verify] ALL CHECKS PASSED"
    exit 0
else
    echo "==> [99-verify] ONE OR MORE CHECKS FAILED -- failing this apply"
    exit 1
fi
