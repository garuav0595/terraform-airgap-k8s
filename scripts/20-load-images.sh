#!/usr/bin/env bash
#
# scripts/20-load-images.sh
#
# Runs on EVERY node (main.tf phase 3, after containerd is installed
# and running). Imports every image tarball from the bundle straight
# into containerd's content store.
#
# MUST use the "k8s.io" containerd namespace (requirement #4) -- that
# is the namespace the CRI plugin (and therefore the kubelet and
# every `crictl`/`kubectl` image reference) looks in. `ctr images
# import` with no -n defaults to the "default" namespace, which is
# invisible to Kubernetes entirely; that mistake looks like a
# successful import right up until the first pod schedule fails with
# ErrImageNeverPull.
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

IMAGES_DIR="${STAGE_DIR}/images"
[[ -d "${IMAGES_DIR}" ]] || { echo "no images dir at ${IMAGES_DIR}" >&2; exit 1; }

echo "==> [20-load-images] importing into containerd namespace k8s.io"

shopt -s nullglob
count=0
skipped=0
for tarball in "${IMAGES_DIR}"/*.tar; do
    name="$(basename "${tarball}")"
    # Idempotent: `ctr images import` itself is safe to re-run (it's
    # content-addressed), but skip the (slow, disk-IO-heavy) import
    # entirely when nothing changed, so re-applies are fast.
    marker="/var/lib/k8s-airgap-image-import/${name}.imported"
    if [[ -f "${marker}" ]] && [[ "${marker}" -nt "${tarball}" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    ctr -n k8s.io images import "${tarball}"
    mkdir -p "$(dirname "${marker}")"
    touch "${marker}"
    count=$((count + 1))
done
shopt -u nullglob

echo "==> [20-load-images] imported ${count}, skipped ${skipped} (already present)"

echo "==> verifying against k8s.io namespace:"
ctr -n k8s.io images ls -q | sed 's/^/    /'
