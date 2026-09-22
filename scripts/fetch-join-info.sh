#!/usr/bin/env bash
#
# scripts/fetch-join-info.sh
#
# Invoked by Terraform's `data "external"` (main.tf, after phase 5b)
# on the TERRAFORM HOST. Implements the external data source protocol:
# reads a JSON object of query arguments on stdin, must print exactly
# one JSON object of string->string on stdout.
#
# This is the ONE piece of cluster state that cannot exist until
# `kubeadm init` has actually run -- the CA public-key hash -- so it
# is the only thing read back from the cluster at all (requirement
# #10). Everything else (bootstrap token, certificate-key) is
# generated up front by Terraform's random provider, precisely so
# nothing else needs an external/read-back round trip.
#
# The hash this prints is PUBLIC: it is the exact value kubeadm
# itself publishes, unauthenticated, in the kube-public/cluster-info
# ConfigMap for any client to discover the cluster CA. Reading it
# over SSH here is a convenience, not a secret exfiltration -- no
# private key material is ever read or transmitted.
set -euo pipefail

QUERY_JSON="$(cat)"

get_arg() {
    python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" <<<"${QUERY_JSON}"
}

HOST="$(get_arg host)"
SSH_USER="$(get_arg user)"
SSH_KEY="$(get_arg ssh_key)"
SSH_PORT="$(get_arg ssh_port)"
SSH_PORT="${SSH_PORT:-22}"

if [[ -z "${HOST}" || -z "${SSH_USER}" ]]; then
    echo '{"error":"missing host or user in external data source query"}' >&2
    exit 1
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "${SSH_PORT}")
[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=(-i "${SSH_KEY}")

REMOTE_CMD='openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt -noout \
    | openssl rsa -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -hex | sed "s/^.* //"'

HASH="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "${REMOTE_CMD}")"
HASH="$(echo -n "${HASH}" | tr -d '[:space:]')"

if [[ ! "${HASH}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "{\"error\":\"unexpected CA hash output from ${HOST}: ${HASH}\"}" >&2
    exit 1
fi

python3 -c "import json; print(json.dumps({'ca_cert_hash': '${HASH}'}))"
