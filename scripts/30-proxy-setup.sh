#!/usr/bin/env bash
#
# scripts/30-proxy-setup.sh
#
# Runs on the VIP-fronting nodes only (main.tf phase 4, when
# manage_vip = true). Installs haproxy + keepalived offline, and
# fixes up the one thing Terraform could not know at render time:
# the actual NIC name (requirement #8). The haproxy.cfg and
# keepalived.conf placed at --stage-dir were already rendered
# per-node by templatefile() in main.tf (ports, priorities, unicast
# peers, etc.) -- this script's only job is local host-specific glue.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

STAGE_DIR=""
NODE_IP=""

usage() { echo "Usage: $(basename "$0") --stage-dir DIR --node-ip IP" >&2; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-dir) STAGE_DIR="$2"; shift 2 ;;
        --node-ip)   NODE_IP="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done
[[ -n "${STAGE_DIR}" && -n "${NODE_IP}" ]] || { usage; exit 1; }

echo "==> [30-proxy-setup] on $(hostname), VIP node IP ${NODE_IP}"

# --- install haproxy + keepalived offline, if not already present ---
if ! rpm -q haproxy >/dev/null 2>&1 || ! rpm -q keepalived >/dev/null 2>&1; then
    dnf install -y --disablerepo='*' "${STAGE_DIR}/rpms"/haproxy-*.rpm "${STAGE_DIR}/rpms"/keepalived-*.rpm \
        || dnf install -y --disablerepo='*' "${STAGE_DIR}/rpms"/*.rpm
fi

# --- resolve the real NIC name (requirement #8) ---
# `ip -4 -o addr show` lists every IPv4 address with its owning
# interface; grep for the address Terraform was told this node has.
IFACE="$(ip -4 -o addr show | awk -v ip="${NODE_IP}" '$0 ~ ip"/" {print $2; exit}')"
if [[ -z "${IFACE}" ]]; then
    echo "could not find an interface holding ${NODE_IP} -- check topology tfvars vs. actual host IPs" >&2
    ip -4 -o addr show >&2
    exit 1
fi
echo "    resolved interface: ${IFACE}"

mkdir -p /opt/k8s-airgap

install_if_changed() {
    local src="$1" dst="$2"
    if ! cmp -s "${src}" "${dst}" 2>/dev/null; then
        cp "${src}" "${dst}"
        echo "    updated ${dst}"
        return 0
    fi
    return 1
}

HAPROXY_CHANGED=0
KEEPALIVED_CHANGED=0

install_if_changed "${STAGE_DIR}/haproxy.cfg" /etc/haproxy/haproxy.cfg && HAPROXY_CHANGED=1

# Substitute the real interface name into the rendered keepalived
# config's INTERFACE_PLACEHOLDER before comparing/installing.
sed "s/INTERFACE_PLACEHOLDER/${IFACE}/" "${STAGE_DIR}/keepalived.conf" > /tmp/keepalived.conf.rendered
install_if_changed /tmp/keepalived.conf.rendered /etc/keepalived/keepalived.conf && KEEPALIVED_CHANGED=1
rm -f /tmp/keepalived.conf.rendered

install -m 0755 "${STAGE_DIR}/check_apiserver.sh" /opt/k8s-airgap/check_apiserver.sh

systemctl enable haproxy keepalived >/dev/null 2>&1 || true

# Only restart what actually changed -- restarting keepalived
# unconditionally on every re-apply would cause a needless VRRP
# election (and a brief VIP blip) even when nothing about this
# node's config changed.
if [[ "${HAPROXY_CHANGED}" -eq 1 ]] || ! systemctl is-active --quiet haproxy; then
    systemctl restart haproxy
    echo "    haproxy (re)started"
fi
if [[ "${KEEPALIVED_CHANGED}" -eq 1 ]] || ! systemctl is-active --quiet keepalived; then
    systemctl restart keepalived
    echo "    keepalived (re)started"
fi

echo "==> [30-proxy-setup] done"
