#!/bin/sh
# build-local.sh: Helper script to run alpine-cloud-images build locally
# Requires KVM (/dev/kvm) and qemu-system-x86_64 for fast hardware acceleration.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${ROOT_DIR}/build-work"

# Source .env if present
if [ -f "${ROOT_DIR}/.env" ]; then
    . "${ROOT_DIR}/.env"
fi

ALPINE_BRANCH="${ALPINE_BRANCH:-3.24}"
ARCH="${ARCH:-x86_64}"
CLOUD="${CLOUD:-gcp}"
BOOTSTRAP="${BOOTSTRAP:-lite}"

# Parse target format if specified as first argument (e.g., ./build-local.sh vhdx)
TARGET_FORMAT="${1:-${TARGET_FORMAT:-gcp}}"

echo "==> Target export format: ${TARGET_FORMAT}"

# If running directly with root privileges, use the ultra-fast build-rootfs pipeline
if [ "$(id -u)" -eq 0 ] && [ -f "${SCRIPT_DIR}/build-rootfs.sh" ]; then
    echo "==> Running fast rootfs transformation pipeline..."
    TMP_DIR=$(mktemp -d /tmp/alpine-build-XXXXXX)
    cd "${TMP_DIR}"

    BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}/releases/cloud/gcp_alpine-3.24.1-x86_64-uefi-tiny-r0.raw.tar.gz"
    echo "Downloading official base UEFI image from ${BASE_URL}..."
    wget -q --show-progress -c "${BASE_URL}" -O alpine-base.raw.tar.gz

    TARGET_FORMAT="${TARGET_FORMAT}" "${SCRIPT_DIR}/build-rootfs.sh" alpine-base.raw.tar.gz "alpine-lite-3.24.1.${TARGET_FORMAT}"
    
    mkdir -p "${ROOT_DIR}/output"
    mv alpine-lite-3.24.1.* "${ROOT_DIR}/output/"
    rm -rf "${TMP_DIR}"
    echo "==> Build complete! Output artifact: ${ROOT_DIR}/output/"
    exit 0
fi

echo "==> [1/4] Checking prerequisites..."
if [ ! -e /dev/kvm ]; then
    echo "WARNING: /dev/kvm not found! Build will fall back to software TCG emulation (slower)."
else
    echo "KVM acceleration detected (/dev/kvm)."
fi

for cmd in git qemu-img qemu-system-x86_64 parted mkfs.ext4 tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Missing required command: $cmd"
        echo "Run: sudo apt install qemu-system-x86 qemu-utils parted e2fsprogs (Debian/Ubuntu/WSL)"
        exit 1
    fi
done

echo "==> [2/4] Setting up upstream alpine-cloud-images repository..."
mkdir -p "${WORK_DIR}"
if [ ! -d "${WORK_DIR}/alpine-cloud-images/.git" ]; then
    git clone --depth 1 https://gitlab.alpinelinux.org/alpine/cloud/alpine-cloud-images.git "${WORK_DIR}/alpine-cloud-images"
else
    echo "Existing alpine-cloud-images repo found in build-work. Reusing."
fi

cd "${WORK_DIR}/alpine-cloud-images"

echo "==> [3/4] Injecting alpine-lite overlay..."
OVERLAY_DIR="overlays/alpine-lite"
mkdir -p "${OVERLAY_DIR}/configs" "${OVERLAY_DIR}/scripts"
cp "${ROOT_DIR}/configs/alpine-lite.conf" "${OVERLAY_DIR}/configs/"
cp "${ROOT_DIR}/scripts/setup-lite" "${OVERLAY_DIR}/scripts/"
cp "${ROOT_DIR}/scripts/cloud-lite" "${OVERLAY_DIR}/scripts/"
chmod +x "${OVERLAY_DIR}/scripts/setup-lite" "${OVERLAY_DIR}/scripts/cloud-lite"

echo "==> [4/4] Executing upstream ./build..."
echo "Command: ./build local --custom ${OVERLAY_DIR} --only ${ALPINE_BRANCH} ${ARCH} bios ${BOOTSTRAP} vm ${CLOUD}"

./build local \
    --custom "${OVERLAY_DIR}" \
    --only "${ALPINE_BRANCH}" "${ARCH}" "bios" "${BOOTSTRAP}" "vm" "${CLOUD}"

if [ "${TARGET_FORMAT}" = "vhdx" ] || [ "${TARGET_FORMAT}" = "hyperv" ]; then
    LATEST_RAW=$(ls -t output/*.raw 2>/dev/null | head -n1 || true)
    if [ -n "$LATEST_RAW" ]; then
        echo "Converting $LATEST_RAW to VHDX..."
        qemu-img convert -f raw -O vhdx -o subformat=dynamic "$LATEST_RAW" "${LATEST_RAW%.raw}.vhdx"
        echo "==> Generated VHDX: ${LATEST_RAW%.raw}.vhdx"
    fi
fi

echo "==> Build complete! Output located in ${WORK_DIR}/alpine-cloud-images/output/"
