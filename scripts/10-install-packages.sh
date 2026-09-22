#!/usr/bin/env bash
#
# scripts/10-install-packages.sh
#
# Runs on EVERY node (main.tf phase 3, after 00-node-prep.sh and the
# bundle tarball has already been unpacked to --stage-dir by this
# same phase). Installs containerd + kubelet/kubeadm/kubectl from the
# RPMs in the bundle -- `dnf install <path-to-local-rpms>/*.rpm`, NOT
# `dnf install <package-name>` -- there is no repo to resolve against
# on the node, only the dependency-closed set prepare-rpms.sh already
# downloaded.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

STAGE_DIR=""
KUBE_VERSION=""
CONTAINERD_VERSION=""
PAUSE_VERSION=""

usage() {
    echo "Usage: $(basename "$0") --stage-dir DIR --kube-version X --containerd-version X --pause-version X" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-dir)          STAGE_DIR="$2"; shift 2 ;;
        --kube-version)       KUBE_VERSION="$2"; shift 2 ;;
        --containerd-version) CONTAINERD_VERSION="$2"; shift 2 ;;
        --pause-version)      PAUSE_VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done
[[ -n "${STAGE_DIR}" && -n "${KUBE_VERSION}" ]] || { usage; exit 1; }

RPM_DIR="${STAGE_DIR}/rpms"
echo "==> [10-install-packages] installing from ${RPM_DIR}"

if [[ ! -d "${RPM_DIR}" ]] || [[ -z "$(ls -A "${RPM_DIR}" 2>/dev/null)" ]]; then
    echo "no RPMs found at ${RPM_DIR} -- did phase 2/3 unpack the bundle correctly?" >&2
    exit 1
fi

# --- idempotency: skip entirely if already installed at this version ---
NEED_INSTALL=0
for pkg in containerd.io "kubelet-${KUBE_VERSION}" "kubeadm-${KUBE_VERSION}" "kubectl-${KUBE_VERSION}"; do
    if ! rpm -q "${pkg}" >/dev/null 2>&1; then
        NEED_INSTALL=1
    fi
done

if [[ "${NEED_INSTALL}" -eq 1 ]]; then
    echo "    installing offline (dnf localinstall against ${RPM_DIR}/*.rpm)"
    # --disablerepo=* : belt-and-braces -- even though there's no
    # egress on an air-gapped node anyway, this guarantees dnf never
    # so much as *attempts* a metadata refresh against a repo it
    # can't reach, which would otherwise stall the whole install on
    # a DNS/connect timeout.
    dnf install -y --disablerepo='*' "${RPM_DIR}"/*.rpm
else
    echo "    containerd/kubelet/kubeadm/kubectl already installed at pinned versions, skipping"
fi

systemctl enable containerd >/dev/null 2>&1 || true
systemctl enable kubelet    >/dev/null 2>&1 || true

# --- containerd config ---
# Regenerated every run (cheap, deterministic) rather than guarded by
# an idempotency check, so a version bump always lands correctly.
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# cgroup driver MUST match the kubelet's (systemd, set in
# KubeletConfiguration via kubeadm) or the kubelet refuses to start
# with a cgroup driver mismatch error.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# sandbox_image (the pause image) must point at a tag we actually
# preloaded (requirement #4) -- if this drifts from what
# 20-load-images.sh imported, every pod sandbox creation fails with
# ErrImageNeverPull before a single container starts.
sed -i "s#sandbox_image = .*#sandbox_image = \"registry.k8s.io/pause:${PAUSE_VERSION}\"#" /etc/containerd/config.toml

systemctl restart containerd
systemctl restart kubelet 2>/dev/null || true   # kubelet crash-loops until kubeadm init/join; expected

echo "==> [10-install-packages] done ($(kubeadm version -o short 2>/dev/null || echo unknown))"
