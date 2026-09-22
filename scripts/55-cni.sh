#!/usr/bin/env bash
#
# scripts/55-cni.sh
#
# Runs ONCE, on the first master only (main.tf phase 5b), AFTER
# kubeadm init and BEFORE any other node is allowed to join
# (requirement #3): a node with no CNI never leaves NotReady, and
# CoreDNS stays Pending forever waiting on pod networking. Both the
# control-plane join gate (wait-cp-ready.sh) and 99-verify.sh key off
# `Ready`, so this has to run first, unconditionally, in its own
# phase separate from 60-addons.sh.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf

STAGE_DIR=""
POD_SUBNET=""
ENCAPSULATION="ipip"
BLOCK_SIZE="26"

usage() {
    echo "Usage: $(basename "$0") --stage-dir DIR --pod-subnet CIDR [--encapsulation ipip|vxlan] [--block-size N]" >&2
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-dir)     STAGE_DIR="$2"; shift 2 ;;
        --pod-subnet)    POD_SUBNET="$2"; shift 2 ;;
        --encapsulation) ENCAPSULATION="$2"; shift 2 ;;
        --block-size)    BLOCK_SIZE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done
[[ -n "${STAGE_DIR}" && -n "${POD_SUBNET}" ]] || { usage; exit 1; }

SRC="${STAGE_DIR}/manifests/calico.yaml"
[[ -f "${SRC}" ]] || { echo "missing ${SRC} -- did prepare-bundle.sh fetch it?" >&2; exit 1; }

echo "==> [55-cni] applying Calico (pod_subnet=${POD_SUBNET} encapsulation=${ENCAPSULATION} blockSize=${BLOCK_SIZE})"

RENDERED="/tmp/calico-rendered.yaml"
cp "${SRC}" "${RENDERED}"

# The stock manifest ships CALICO_IPV4POOL_CIDR commented out with a
# default of 192.168.0.0/16 -- must match our actual pod_subnet or
# routes never converge between nodes.
sed -i \
    -e "s#\(- name: CALICO_IPV4POOL_CIDR\)#\1#" \
    "${RENDERED}"
python3 - "${RENDERED}" "${POD_SUBNET}" "${ENCAPSULATION}" "${BLOCK_SIZE}" <<-'PYEOF'
	import re, sys
	path, pod_subnet, encap, block_size = sys.argv[1:5]
	with open(path) as f:
	    text = f.read()

	def set_or_insert_env(text, name, value, after_marker="- name: CLUSTER_TYPE"):
	    # Uncomment + set value if the var already exists (commented or not).
	    pattern = re.compile(
	        r'(#?\s*- name: %s\n#?\s*value:).*' % re.escape(name)
	    )
	    if pattern.search(text):
	        return pattern.sub(r'          - name: %s\n            value: "%s"' % (name, value), text, count=1)
	    # Otherwise inject right after CLUSTER_TYPE, once, per container block.
	    return text.replace(
	        after_marker,
	        "%s\n          - name: %s\n            value: \"%s\"" % (after_marker, name, value),
	        1,
	    )

	text = set_or_insert_env(text, "CALICO_IPV4POOL_CIDR", pod_subnet)
	text = set_or_insert_env(text, "CALICO_IPV4POOL_BLOCK_SIZE", block_size)
	if encap == "vxlan":
	    text = set_or_insert_env(text, "CALICO_IPV4POOL_IPIP", "Never")
	    text = set_or_insert_env(text, "CALICO_IPV4POOL_VXLAN", "Always")
	else:
	    text = set_or_insert_env(text, "CALICO_IPV4POOL_IPIP", "Always")
	    text = set_or_insert_env(text, "CALICO_IPV4POOL_VXLAN", "Never")

	with open(path, "w") as f:
	    f.write(text)
	PYEOF

# imagePullPolicy IfNotPresent everywhere (requirement #4) -- the
# stock manifest doesn't set this explicitly, which defaults to
# Always for :latest-style tags and IfNotPresent for pinned tags, but
# we pin it explicitly rather than rely on that implicit behaviour.
sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g' "${RENDERED}"
if ! grep -q "imagePullPolicy: IfNotPresent" "${RENDERED}"; then
    sed -i '/^\s*image: docker.io\/calico/a\          imagePullPolicy: IfNotPresent' "${RENDERED}"
fi

kubectl apply -f "${RENDERED}"

echo "==> [55-cni] waiting for calico-node DaemonSet rollout on this (first) master"
kubectl -n kube-system rollout status daemonset/calico-node --timeout=180s

echo "==> [55-cni] waiting for this node to report Ready"
for i in $(seq 1 60); do
    if kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -q '^Ready'; then
        echo "==> [55-cni] node Ready"
        exit 0
    fi
    sleep 5
done

echo "node did not become Ready within timeout after applying CNI" >&2
kubectl get nodes -o wide >&2
kubectl -n kube-system get pods -o wide >&2
exit 1
