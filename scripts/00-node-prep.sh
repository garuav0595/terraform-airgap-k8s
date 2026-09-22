#!/usr/bin/env bash
#
# scripts/00-node-prep.sh
#
# Runs on EVERY node (main.tf phase 3). Baseline RHEL 9 prep that has
# nothing to do with Kubernetes packages specifically: hostname,
# /etc/hosts, swap, SELinux, firewalld, kernel modules, sysctls, and
# (opt-in) egress proxy config. Idempotent: every step either checks
# current state first or uses a command that's a no-op when already
# applied.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

NODE_NAME=""
HOSTS_FILE=""
HTTP_PROXY_URL=""
HTTPS_PROXY_URL=""
NO_PROXY_CSV=""

usage() {
    cat <<-EOT
	Usage: $(basename "$0") --node-name NAME --hosts-file FILE \\
	           [--http-proxy URL] [--https-proxy URL] [--no-proxy CSV]
	EOT
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-name)    NODE_NAME="$2"; shift 2 ;;
        --hosts-file)   HOSTS_FILE="$2"; shift 2 ;;
        --http-proxy)   HTTP_PROXY_URL="$2"; shift 2 ;;
        --https-proxy)  HTTPS_PROXY_URL="$2"; shift 2 ;;
        --no-proxy)     NO_PROXY_CSV="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done
[[ -n "${NODE_NAME}" && -n "${HOSTS_FILE}" ]] || { usage; exit 1; }

echo "==> [00-node-prep] ${NODE_NAME}"

# --- hostname ---
if [[ "$(hostnamectl --static)" != "${NODE_NAME}" ]]; then
    hostnamectl set-hostname "${NODE_NAME}"
    echo "    hostname set to ${NODE_NAME}"
fi

# --- /etc/hosts, managed (air-gapped sites usually have no node-FQDN
# DNS at all) ---
MARK_BEGIN="# BEGIN k8s-airgap managed block"
MARK_END="# END k8s-airgap managed block"
if grep -qF "${MARK_BEGIN}" /etc/hosts 2>/dev/null; then
    # Idempotent update: replace the block between markers in place.
    awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
        $0==b {skip=1}
        !skip {print}
        $0==e {skip=0}
    ' /etc/hosts > /etc/hosts.new
    mv /etc/hosts.new /etc/hosts
fi
{
    echo "${MARK_BEGIN}"
    cat "${HOSTS_FILE}"
    echo "${MARK_END}"
} >> /etc/hosts
echo "    /etc/hosts updated ($(wc -l < "${HOSTS_FILE}") entries)"

# --- swap off, permanently ---
# kubelet refuses to start with swap on (unless explicitly configured
# to tolerate it, which we don't -- predictable memory behaviour
# matters more than squeezing a bit more headroom out of small nodes).
if swapon --summary | grep -q .; then
    swapoff -a
fi
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
echo "    swap disabled"

# --- SELinux: permissive (per build spec defaults) ---
# Not "disabled": permissive still labels and logs would-be denials
# (useful for later hardening to enforcing), it just doesn't block
# kubelet/containerd, which on RHEL 9 still occasionally trips over
# missing kubernetes-specific SELinux policy without a registry to
# pull `container-selinux` fixes from.
if [[ "$(getenforce)" != "Permissive" ]]; then
    setenforce 0 || true
fi
sed -ri 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
echo "    SELinux set to permissive"

# --- firewalld: disabled (per build spec defaults) ---
# See README's firewall port table for sites that must keep it on --
# this default assumes the network boundary is handled upstream
# (this is an internal, air-gapped segment).
if systemctl is-enabled firewalld >/dev/null 2>&1; then
    systemctl disable --now firewalld
fi
echo "    firewalld disabled"

# --- kernel modules + sysctls Kubernetes networking needs ---
cat >/etc/modules-load.d/k8s.conf <<-EOT
	overlay
	br_netfilter
EOT
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes.conf <<-EOT
	net.bridge.bridge-nf-call-iptables  = 1
	net.bridge.bridge-nf-call-ip6tables = 1
	net.ipv4.ip_forward                 = 1
EOT
sysctl --system >/dev/null
echo "    kernel modules + sysctls applied"

# --- NetworkManager must not manage CNI interfaces (requirement #13) ---
# Without this, NetworkManager sees cali* / tunl* veth pairs come up
# and "helpfully" tries to manage them (assign DHCP, reset routes),
# fighting Calico for the same interfaces and causing intermittent
# pod-to-pod connectivity loss that looks like a CNI bug but isn't.
mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/k8s-unmanaged.conf <<-EOT
	[keyfile]
	unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:wireguard.cali
EOT
if systemctl is-active NetworkManager >/dev/null 2>&1; then
    systemctl reload NetworkManager || systemctl restart NetworkManager
fi
echo "    NetworkManager configured to ignore CNI interfaces"

# --- optional egress proxy (opt-in, off by default) ---
# CRITICAL: this whole block is skipped entirely when both URLs are
# empty. No later phase may ever come to depend on the proxy being
# reachable -- the spec is explicit that it's unreliable for node
# bootstrap. See variables.tf http_proxy_url / locals.tf no_proxy_list.
if [[ -n "${HTTP_PROXY_URL}" || -n "${HTTPS_PROXY_URL}" ]]; then
    echo "    configuring egress proxy (opt-in: http_proxy_url/https_proxy_url set)"

    {
        echo "http_proxy=${HTTP_PROXY_URL}"
        echo "https_proxy=${HTTPS_PROXY_URL:-${HTTP_PROXY_URL}}"
        echo "HTTP_PROXY=${HTTP_PROXY_URL}"
        echo "HTTPS_PROXY=${HTTPS_PROXY_URL:-${HTTP_PROXY_URL}}"
        echo "no_proxy=${NO_PROXY_CSV}"
        echo "NO_PROXY=${NO_PROXY_CSV}"
    } > /tmp/.k8s-airgap-proxy-env
    # Replace any previously-written block idempotently.
    sed -i '/^http_proxy=/d;/^https_proxy=/d;/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^no_proxy=/d;/^NO_PROXY=/d' /etc/environment
    cat /tmp/.k8s-airgap-proxy-env >> /etc/environment
    rm -f /tmp/.k8s-airgap-proxy-env

    mkdir -p /etc/systemd/system/containerd.service.d
    cat >/etc/systemd/system/containerd.service.d/http-proxy.conf <<-EOT
		[Service]
		Environment="HTTP_PROXY=${HTTP_PROXY_URL}"
		Environment="HTTPS_PROXY=${HTTPS_PROXY_URL:-${HTTP_PROXY_URL}}"
		Environment="NO_PROXY=${NO_PROXY_CSV}"
	EOT
    # containerd is (re)started by 10-install-packages.sh / 20-load-images.sh
    # after this, so a daemon-reload now is enough; no restart here.
    systemctl daemon-reload

    if [[ -f /etc/dnf/dnf.conf ]] && ! grep -q '^proxy=' /etc/dnf/dnf.conf; then
        echo "proxy=${HTTP_PROXY_URL}" >> /etc/dnf/dnf.conf
    fi
    echo "    proxy env written to /etc/environment, containerd drop-in, /etc/dnf/dnf.conf"
else
    echo "    no egress proxy configured (http_proxy_url/https_proxy_url empty) -- zero-egress bootstrap"
fi

echo "==> [00-node-prep] done on ${NODE_NAME}"
