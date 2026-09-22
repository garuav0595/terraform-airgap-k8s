#!/usr/bin/env bash
#
# scripts/pack-bundle.sh
#
# Runs on the TERRAFORM HOST (invoked by main.tf phase 1, local-exec).
# Validates the bundle/ directory is actually complete -- catching a
# forgotten prepare-bundle.sh or prepare-rpms.sh run HERE, at plan/
# apply time on the machine with internet access, is far cheaper than
# discovering a missing image halfway through kubeadm join on node 4
# of 5 with no way to fetch it. Then packs everything into ONE
# tarball so phase 2 does a single SCP per node instead of thousands
# of small file transfers.
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") --bundle-dir DIR --out FILE" >&2
}

BUNDLE_DIR=""
OUT_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-dir) BUNDLE_DIR="$2"; shift 2 ;;
        --out) OUT_FILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -n "${BUNDLE_DIR}" && -n "${OUT_FILE}" ]] || { usage; exit 1; }

fail=0
require_nonempty_dir() {
    local d="$1" label="$2"
    if [[ ! -d "$d" ]] || [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
        echo "MISSING: ${label} (${d}) is empty or absent." >&2
        echo "  -> did you run bundle/prepare-bundle.sh and bundle/prepare-rpms.sh?" >&2
        fail=1
    fi
}

require_nonempty_dir "${BUNDLE_DIR}/images"    "container image tarballs"
require_nonempty_dir "${BUNDLE_DIR}/rpms"      "offline RPMs"
require_nonempty_dir "${BUNDLE_DIR}/manifests" "fetched manifests (Calico)"

if [[ ! -f "${BUNDLE_DIR}/manifests/calico.yaml" ]]; then
    echo "MISSING: ${BUNDLE_DIR}/manifests/calico.yaml" >&2
    fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
    echo "Bundle is incomplete -- refusing to pack. See messages above." >&2
    exit 1
fi

echo "==> bundle validated OK: $(du -sh "${BUNDLE_DIR}" | cut -f1) total"

mkdir -p "$(dirname "${OUT_FILE}")"

# Idempotency: only re-pack (and thus only cause a re-upload trigger
# downstream) if the content actually changed. tar's mtimes make the
# tarball itself non-reproducible byte-for-byte, so we hash the
# INPUT tree, not the output tarball.
NEW_HASH="$(find "${BUNDLE_DIR}" -type f \( -path '*/images/*' -o -path '*/rpms/*' -o -path '*/manifests/*' -o -path '*/bin/*' \) -print0 \
    | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"

OLD_HASH="none"
[[ -f "${OUT_FILE}.sha256" ]] && OLD_HASH="$(cat "${OUT_FILE}.sha256")"

if [[ "${NEW_HASH}" == "${OLD_HASH}" && -f "${OUT_FILE}" ]]; then
    echo "==> bundle unchanged (sha256 ${NEW_HASH:0:12}...), reusing existing ${OUT_FILE}"
else
    echo "==> packing ${BUNDLE_DIR} -> ${OUT_FILE}"
    tar -C "${BUNDLE_DIR}" -czf "${OUT_FILE}" images rpms manifests $( [[ -d "${BUNDLE_DIR}/bin" ]] && echo bin )
    echo "${NEW_HASH}" > "${OUT_FILE}.sha256"
fi

# Version marker consumed by locals.bundle_trigger, so the guard/upload
# phases only re-run when the packed content actually changed.
echo "${NEW_HASH}" > "${BUNDLE_DIR}/.bundle-version"

echo "==> $(du -sh "${OUT_FILE}" | cut -f1) packed at ${OUT_FILE}"
