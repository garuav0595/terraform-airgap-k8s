#!/usr/bin/env bash
#
# scripts/50-join.sh
#
# Runs on every master EXCEPT the first (main.tf phase 6a, gated by
# wait-cp-ready.sh beforehand) and every worker (phase 6b, parallel).
# One script for both roles -- the difference is entirely captured in
# the already-rendered kubeadm-join.yaml (the `controlPlane:` stanza
# is only present for control-plane joins, see
# templates/kubeadm-join.yaml.tftpl).
#
# IDEMPOTENT (requirement #11): if /etc/kubernetes/kubelet.conf
# already exists, this node has already joined -- exit 0 untouched.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

STAGE_DIR=""
usage() { echo "Usage: $(basename "$0") --stage-dir DIR" >&2; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-dir) STAGE_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done
[[ -n "${STAGE_DIR}" ]] || { usage; exit 1; }

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    echo "==> [50-join] /etc/kubernetes/kubelet.conf already exists -- already joined, nothing to do"
    exit 0
fi

echo "==> [50-join] running kubeadm join"
kubeadm join --config "${STAGE_DIR}/kubeadm-join.yaml"
echo "==> [50-join] joined"
