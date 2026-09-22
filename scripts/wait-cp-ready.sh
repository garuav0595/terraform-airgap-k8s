#!/usr/bin/env bash
#
# scripts/wait-cp-ready.sh
#
# Runs on the TERRAFORM HOST (invoked by main.tf phase 6a as a
# local-exec, once per additional master, BEFORE that master's own
# 50-join.sh remote-exec). This is the serialisation gate for
# requirement #2: two nodes running `kubeadm join --control-plane`
# concurrently race on the etcd member list -- one can be added as a
# learner while the other is mid-promotion, stalling quorum. So each
# additional master blocks here until --expect control-plane nodes
# are already Ready, before it's allowed to proceed to its own join.
#
# Crucially, this SSHes INTO the first master and runs `kubectl` over
# that SSH session -- it never copies /etc/kubernetes/admin.conf back
# to the Terraform host. No cluster credential ever leaves the first
# master.
set -euo pipefail

HOST=""
SSH_USER=""
SSH_KEY=""
SSH_PORT="22"
EXPECT=""
TIMEOUT="600"

usage() {
    echo "Usage: $(basename "$0") --host IP --user USER [--ssh-key PATH] [--ssh-port N] --expect N [--timeout SECONDS]" >&2
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)      HOST="$2"; shift 2 ;;
        --user)      SSH_USER="$2"; shift 2 ;;
        --ssh-key)   SSH_KEY="$2"; shift 2 ;;
        --ssh-port)  SSH_PORT="$2"; shift 2 ;;
        --expect)    EXPECT="$2"; shift 2 ;;
        --timeout)   TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done
[[ -n "${HOST}" && -n "${SSH_USER}" && -n "${EXPECT}" ]] || { usage; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "${SSH_PORT}")
[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=(-i "${SSH_KEY}")

REMOTE_CMD='sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes \
    -l node-role.kubernetes.io/control-plane \
    --no-headers 2>/dev/null | awk "\$2==\"Ready\"" | wc -l'

echo "==> [wait-cp-ready] waiting for >= ${EXPECT} Ready control-plane node(s), via ${SSH_USER}@${HOST}"

deadline=$(( $(date +%s) + TIMEOUT ))
while true; do
    ready_count="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "${REMOTE_CMD}" || echo 0)"
    ready_count="${ready_count//[^0-9]/}"
    ready_count="${ready_count:-0}"

    if [[ "${ready_count}" -ge "${EXPECT}" ]]; then
        echo "==> [wait-cp-ready] ${ready_count}/${EXPECT} Ready -- proceeding"
        exit 0
    fi

    if [[ $(date +%s) -ge ${deadline} ]]; then
        echo "timed out after ${TIMEOUT}s waiting for ${EXPECT} Ready control-plane node(s) (last seen: ${ready_count})" >&2
        exit 1
    fi

    echo "    ${ready_count}/${EXPECT} Ready so far, waiting..."
    sleep 5
done
