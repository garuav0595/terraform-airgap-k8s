#!/usr/bin/env bash
#
# bundle/prepare-rpms.sh
#
# *** RUN THIS ON A MACHINE WITH INTERNET ACCESS -- NEVER ON A NODE. ***
#
# Downloads (does not install) every RPM the offline install
# (scripts/10-install-packages.sh) needs, fully dependency-resolved,
# into bundle/rpms/. Two modes (requirement #6):
#
#   --mode host       Run directly on a subscribed RHEL 9 host that
#                      has internet. Cleanest: dependency resolution
#                      happens against the exact userspace the target
#                      nodes run.
#
#   --mode container  (DEFAULT.) Re-exec this same script inside a
#                      `--platform linux/amd64` EL9 container (Rocky
#                      or Alma) via docker/podman. For operators on a
#                      Mac who have no spare subscribed RHEL box.
#
#                      CAVEAT: Rocky/Alma base packages (glibc,
#                      openssl, etc.) carry different vendor/build
#                      tags than RHEL's. In practice this is harmless
#                      -- the target RHEL 9 nodes already have those
#                      base packages installed at an equal-or-newer
#                      version, so dnf on the node skips them as
#                      already-satisfied and only installs what's
#                      actually missing (containerd, kubelet, kubeadm,
#                      kubectl, and their k8s-specific deps). If a node
#                      ever reports a conflicting base package during
#                      scripts/10-install-packages.sh, that means this
#                      node's base packages have drifted from RHEL's
#                      defaults -- re-run this script in --mode host
#                      on a real subscribed RHEL 9 box instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_RPMS="${SCRIPT_DIR}/rpms"

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.33.0}"
KUBERNETES_MINOR="$(echo "${KUBERNETES_VERSION}" | cut -d. -f1,2)"   # e.g. 1.33
KUBERNETES_RPM_RELEASE="${KUBERNETES_RPM_RELEASE:-150500.1.1}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.2.2}"

MODE="container"
IMAGE="docker.io/rockylinux/rockylinux:9"

usage() {
    cat <<-EOT
	Usage: $(basename "$0") [--mode host|container] [--image IMAGE]

	  --mode host       run directly on a subscribed RHEL 9 host (needs
	                     root + internet on THIS host)
	  --mode container  (default) re-exec inside a linux/amd64 EL9
	                     container via docker/podman -- for Macs
	  --image IMAGE     override the EL9 container image
	                     (default: ${IMAGE})
	EOT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

mkdir -p "${OUT_RPMS}"

if [[ "${MODE}" == "container" ]]; then
    ENGINE=""
    if command -v docker >/dev/null 2>&1; then ENGINE="docker";
    elif command -v podman >/dev/null 2>&1; then ENGINE="podman";
    else echo "need docker or podman for --mode container" >&2; exit 1; fi

    echo "==> re-exec'ing inside ${IMAGE} (--platform linux/amd64) via ${ENGINE}"
    exec "${ENGINE}" run --rm \
        --platform linux/amd64 \
        -v "${SCRIPT_DIR}:/bundle" \
        -e KUBERNETES_VERSION="${KUBERNETES_VERSION}" \
        -e KUBERNETES_RPM_RELEASE="${KUBERNETES_RPM_RELEASE}" \
        -e CONTAINERD_VERSION="${CONTAINERD_VERSION}" \
        "${IMAGE}" \
        bash /bundle/prepare-rpms.sh --mode host
fi

# ---- from here on: --mode host, either real RHEL 9 or the EL9 container ----
if [[ "${EUID}" -ne 0 ]]; then
    echo "must run as root (dnf download needs to write repo cache)" >&2
    exit 1
fi

echo "==> adding the Kubernetes v${KUBERNETES_MINOR} EL9 repo"
cat >/etc/yum.repos.d/kubernetes.repo <<-EOT
	[kubernetes]
	name=Kubernetes v${KUBERNETES_MINOR}
	baseurl=https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR}/rpm/
	enabled=1
	gpgcheck=1
	gpgkey=https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR}/rpm/repodata/repomd.xml.key
EOT

echo "==> adding the containerd (docker-ce) EL9 repo"
dnf -y install dnf-plugins-core >/dev/null
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

dnf -y install 'dnf-command(download)'

echo "==> resolving + downloading RPMs into ${OUT_RPMS}"
dnf download --resolve --alldeps --destdir "${OUT_RPMS}" \
    "containerd.io-${CONTAINERD_VERSION}" \
    "kubelet-${KUBERNETES_VERSION}-${KUBERNETES_RPM_RELEASE}" \
    "kubeadm-${KUBERNETES_VERSION}-${KUBERNETES_RPM_RELEASE}" \
    "kubectl-${KUBERNETES_VERSION}-${KUBERNETES_RPM_RELEASE}" \
    cri-tools \
    kubernetes-cni \
    conntrack-tools \
    socat \
    ipvsadm \
    ipset \
    iproute-tc \
    ethtool \
    container-selinux \
    policycoreutils-python-utils \
    haproxy \
    keepalived

# containerd's own binary tarball (not always packaged identically
# across distros) is also grabbed directly, pinned to the same
# version, so 10-install-packages.sh has one consistent source of
# truth either way.
echo "==> fetching containerd ${CONTAINERD_VERSION} static binaries as a fallback"
mkdir -p "${SCRIPT_DIR}/bin"
curl -fsSL -o "${SCRIPT_DIR}/bin/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" \
    "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"

sha256sum "${OUT_RPMS}"/*.rpm 2>/dev/null | sha256sum | awk '{print $1}' >> "${SCRIPT_DIR}/.bundle-version" || true

echo "==> done. RPMs: ${OUT_RPMS}"
