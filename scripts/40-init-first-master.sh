#!/usr/bin/env bash
#
# scripts/40-init-first-master.sh
#
# Runs ONCE, on the first master only (main.tf phase 5).
#
# IDEMPOTENT (requirement #11): if /etc/kubernetes/admin.conf already
# exists, this node has already been kubeadm-init'd -- exit 0
# untouched. A re-apply must never re-run `kubeadm init` against a
# live control-plane node; kubeadm itself would refuse anyway, but we
# check first so the failure is an obvious log line, not a kubeadm
# stack trace.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

STAGE_DIR=""
CERTIFICATE_KEY=""

usage() { echo "Usage: $(basename "$0") --stage-dir DIR --certificate-key HEX" >&2; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-dir)       STAGE_DIR="$2"; shift 2 ;;
        --certificate-key) CERTIFICATE_KEY="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done
[[ -n "${STAGE_DIR}" && -n "${CERTIFICATE_KEY}" ]] || { usage; exit 1; }

if [[ -f /etc/kubernetes/admin.conf ]]; then
    echo "==> [40-init-first-master] /etc/kubernetes/admin.conf already exists -- already initialised, nothing to do"
    exit 0
fi

echo "==> [40-init-first-master] running kubeadm init"

# --certificate-key here (not in the YAML -- v1beta3 InitConfiguration
# has no field for it) enables --upload-certs: the control-plane certs
# get encrypted with this key and stashed in a Secret in kube-system,
# so additional masters joining with --control-plane can fetch them
# without any cert material ever touching the Terraform host or SSH
# session. The key itself was generated once by Terraform
# (random_id.certificate_key) -- see requirement #10.
kubeadm init \
    --config "${STAGE_DIR}/kubeadm-init.yaml" \
    --upload-certs \
    --certificate-key "${CERTIFICATE_KEY}"

mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chmod 0600 /root/.kube/config

echo "==> [40-init-first-master] kubeadm init complete"
