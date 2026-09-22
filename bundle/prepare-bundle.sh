#!/usr/bin/env bash
#
# bundle/prepare-bundle.sh
#
# *** RUN THIS ON A MACHINE WITH INTERNET ACCESS -- NEVER ON A NODE. ***
#
# Pulls every container image the cluster needs, saves each as an
# OCI tarball under bundle/images/, and fetches the upstream manifests
# we don't author ourselves (Calico's CRDs). The output directory is
# what scripts/pack-bundle.sh later tars up and Terraform SCPs to
# every node -- nothing in this script ever touches a cluster node.
#
# Requires: docker or podman, with buildx/qemu emulation available if
# you are NOT already on linux/amd64 (Apple Silicon: podman machine or
# Docker Desktop both support this out of the box).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_IMAGES="${SCRIPT_DIR}/images"
OUT_MANIFESTS="${SCRIPT_DIR}/manifests"

# --- versions (keep these in sync with variables.tf defaults) ---
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.33.0}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.2.2}"
CALICO_VERSION="${CALICO_VERSION:-v3.29.3}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-v1.12.2}"
INGRESS_NGINX_CERTGEN_VERSION="${INGRESS_NGINX_CERTGEN_VERSION:-v1.5.3}"
COREDNS_VERSION="${COREDNS_VERSION:-v1.12.0}"
ETCD_VERSION="${ETCD_VERSION:-3.5.21-0}"
PAUSE_VERSION="${PAUSE_VERSION:-3.10.1}"

# Apple Silicon builds this bundle but RHEL nodes are x86_64 -- forcing
# the platform on every pull is requirement #5. Getting this wrong
# doesn't fail here, it fails at 3am on a node with "exec format error".
PLATFORM="linux/amd64"

usage() {
    cat <<-EOT
	Usage: $(basename "$0") [--engine docker|podman]

	Pulls and saves (as .tar, forced --platform ${PLATFORM}) every
	container image this cluster needs into bundle/images/, and
	fetches the Calico manifest into bundle/manifests/.
	EOT
}

ENGINE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) ENGINE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "${ENGINE}" ]]; then
    if command -v docker >/dev/null 2>&1; then ENGINE="docker";
    elif command -v podman >/dev/null 2>&1; then ENGINE="podman";
    else echo "need docker or podman on this (internet-connected) machine" >&2; exit 1; fi
fi
echo "==> using container engine: ${ENGINE}"

mkdir -p "${OUT_IMAGES}" "${OUT_MANIFESTS}"

pull_and_save() {
    local ref="$1"
    local fname
    fname="$(echo "${ref}" | tr '/:' '__').tar"
    echo "==> pulling ${ref} (${PLATFORM})"
    "${ENGINE}" pull --platform "${PLATFORM}" "${ref}"
    echo "==> saving ${ref} -> images/${fname}"
    "${ENGINE}" save --output "${OUT_IMAGES}/${fname}" "${ref}"
}

# --- images kubeadm itself needs ---
# (mirrors `kubeadm config images list --kubernetes-version vX` --
#  kept explicit/pinned here rather than shelled out to kubeadm, since
#  kubeadm isn't installed on this internet-connected build machine.)
CORE_IMAGES=(
    "registry.k8s.io/kube-apiserver:v${KUBERNETES_VERSION}"
    "registry.k8s.io/kube-controller-manager:v${KUBERNETES_VERSION}"
    "registry.k8s.io/kube-scheduler:v${KUBERNETES_VERSION}"
    "registry.k8s.io/kube-proxy:v${KUBERNETES_VERSION}"
    "registry.k8s.io/coredns/coredns:${COREDNS_VERSION}"
    "registry.k8s.io/etcd:${ETCD_VERSION}"
    # Both pause tags: kubelet's compiled-in default and the pinned
    # patch release can differ across kubelet builds -- ship both so
    # neither one is a surprise ErrImageNeverPull (requirement #5).
    "registry.k8s.io/pause:3.10"
    "registry.k8s.io/pause:${PAUSE_VERSION}"
)

# --- Calico (requirement #4/#13 depend on this being preloaded) ---
CALICO_IMAGES=(
    "docker.io/calico/cni:${CALICO_VERSION}"
    "docker.io/calico/node:${CALICO_VERSION}"
    "docker.io/calico/kube-controllers:${CALICO_VERSION}"
    "docker.io/calico/pod2daemon-flexvol:${CALICO_VERSION}"
)

# --- ingress-nginx ---
INGRESS_IMAGES=(
    "registry.k8s.io/ingress-nginx/controller:${INGRESS_NGINX_VERSION}"
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:${INGRESS_NGINX_CERTGEN_VERSION}"
)

for img in "${CORE_IMAGES[@]}" "${CALICO_IMAGES[@]}" "${INGRESS_IMAGES[@]}"; do
    pull_and_save "${img}"
done

echo "==> fetching Calico manifest v${CALICO_VERSION}"
curl -fsSL -o "${OUT_MANIFESTS}/calico.yaml" \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

# Version marker consumed by locals.bundle_trigger in the Terraform
# project, so a re-apply only re-packs/re-uploads when this bundle's
# actual content changed.
sha256sum "${OUT_IMAGES}"/*.tar "${OUT_MANIFESTS}"/*.yaml 2>/dev/null \
    | sha256sum | awk '{print $1}' > "${SCRIPT_DIR}/.bundle-version"

echo "==> done. Images: ${OUT_IMAGES}  Manifests: ${OUT_MANIFESTS}"
echo "==> next: run bundle/prepare-rpms.sh, then scripts/pack-bundle.sh"
