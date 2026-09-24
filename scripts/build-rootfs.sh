#!/bin/sh
# build-rootfs.sh: Mounts, strips, optimizes, and repacks an Alpine rootfs image
# Designed to run in a CI container with SYS_ADMIN capabilities / loop devices.

set -eu

BASE_ARCHIVE="${1:-alpine-base.raw.tar.gz}"
OUTPUT_ARCHIVE="${2:-alpine-lite.raw.tar.gz}"
MOUNT_DIR="/mnt/rootfs"
SCRIPT_DIR="$(dirname "$0")"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source .env if present
if [ -f "${REPO_DIR}/.env" ]; then
    . "${REPO_DIR}/.env"
fi

echo "==> [1/6] Extracting base raw disk archive: ${BASE_ARCHIVE}..."
tar -xzf "${BASE_ARCHIVE}"

if [ ! -f "disk.raw" ]; then
    echo "ERROR: disk.raw not found in archive!"
    exit 1
fi

echo "==> [2/6] Setting up loop device and scanning partitions..."
LOOP_DEV=$(losetup -fP --show disk.raw)
echo "Mounted loop device: ${LOOP_DEV}"

# In Docker containers, the kernel registers the partitions in /sys/block/loop0/loop0p*
# but devtmpfs/udev does not create the device nodes in /dev.
# Create the block device nodes via mknod if they are missing:
for p in 1 2; do
    if [ ! -e "${LOOP_DEV}p${p}" ]; then
        SYS_DEV="/sys/block/$(basename ${LOOP_DEV})/$(basename ${LOOP_DEV})p${p}/dev"
        if [ -f "${SYS_DEV}" ]; then
            DEV_NUM=$(cat "${SYS_DEV}")
            MAJOR=$(echo "${DEV_NUM}" | cut -d: -f1)
            MINOR=$(echo "${DEV_NUM}" | cut -d: -f2)
            echo "Creating device node ${LOOP_DEV}p${p} with major:minor ${MAJOR}:${MINOR}..."
            mknod -m 660 "${LOOP_DEV}p${p}" b "${MAJOR}" "${MINOR}"
        fi
    fi
done

cleanup() {
    echo "==> Cleaning up mountpoints and loop devices..."
    set +e
    umount -l "${MOUNT_DIR}/dev" 2>/dev/null || true
    umount -l "${MOUNT_DIR}/proc" 2>/dev/null || true
    umount -l "${MOUNT_DIR}/sys" 2>/dev/null || true
    umount -l "${MOUNT_DIR}/boot/efi" 2>/dev/null || true
    umount -l "${MOUNT_DIR}" 2>/dev/null || true
    if [ -n "${LOOP_DEV:-}" ]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "${MOUNT_DIR}"

if [ -e "${LOOP_DEV}p2" ]; then
    mount "${LOOP_DEV}p2" "${MOUNT_DIR}"
    if [ -e "${LOOP_DEV}p1" ]; then
        mount "${LOOP_DEV}p1" "${MOUNT_DIR}/boot/efi" 2>/dev/null || true
    fi
else
    echo "Partition 2 device node could not be created!"
    ls -la /dev/loop*
    exit 1
fi

mount --bind /dev "${MOUNT_DIR}/dev"
mount --bind /proc "${MOUNT_DIR}/proc"
mount --bind /sys "${MOUNT_DIR}/sys"

echo "==> [3/6] Purging bloated daemons & installing alpine-lite packages..."
# Ensure DNS works inside chroot
cp /etc/resolv.conf "${MOUNT_DIR}/etc/resolv.conf.bak"
cat << 'EOF' > "${MOUNT_DIR}/etc/resolv.conf"
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

chroot "${MOUNT_DIR}" apk update
chroot "${MOUNT_DIR}" apk add --no-cache \
    dropbear \
    dropbear-openrc \
    zram-init \
    zram-init-openrc \
    sfdisk \
    partx \
    e2fsprogs-extra

# Remove heavy daemons and unneeded cloud packages:
# dhcpcd (7 processes), openssh (~12MB RSS), chrony, acpid, and tiny-cloud
chroot "${MOUNT_DIR}" apk del --purge \
    dhcpcd \
    dhcpcd-openrc \
    tiny-cloud \
    tiny-cloud-openrc \
    openssh \
    openssh-server \
    openssh-client-default \
    openssh-client-common \
    openssh-keygen \
    openssh-server-common \
    chrony \
    chrony-openrc \
    chrony-common \
    acpid \
    acpid-openrc \
    yaml \
    yx || true

# Revert DNS
mv "${MOUNT_DIR}/etc/resolv.conf.bak" "${MOUNT_DIR}/etc/resolv.conf"

echo "==> [4/6] Updating OpenRC runlevels and installing cloud-lite..."
# Install lightweight multi-cloud bootstrap service (replaces tiny-cloud for GCP, AWS, Azure)
cp "${REPO_DIR}/scripts/cloud-lite" "${MOUNT_DIR}/etc/init.d/cloud-lite"
chmod 755 "${MOUNT_DIR}/etc/init.d/cloud-lite"
chroot "${MOUNT_DIR}" rc-update add cloud-lite default

# Dropbear SSH & BusyBox NTP
chroot "${MOUNT_DIR}" rc-update add dropbear default
chroot "${MOUNT_DIR}" rc-update add ntpd default
# ZRAM swap device at boot
chroot "${MOUNT_DIR}" rc-update add zram-init boot

# Remove deleted services from runlevels
for svc in dhcpcd sshd chronyd acpid tiny-cloud-boot tiny-cloud-early tiny-cloud-main tiny-cloud-final; do
    chroot "${MOUNT_DIR}" rc-update del "${svc}" boot 2>/dev/null || true
    chroot "${MOUNT_DIR}" rc-update del "${svc}" default 2>/dev/null || true
    rm -f "${MOUNT_DIR}/etc/init.d/${svc}" 2>/dev/null || true
done

echo "==> [5/6] Executing setup-lite (ACPI signal 12, sysctl, headless blacklists, zram)..."
TARGET="${MOUNT_DIR}" CLOUD=gcp SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}" sh "${REPO_DIR}/scripts/setup-lite"

# Ensure dual-stack network config uses BusyBox udhcpc & udhcpc6
mkdir -p "${MOUNT_DIR}/usr/share/udhcpc"
cat << 'EOF' > "${MOUNT_DIR}/usr/share/udhcpc/default6.script"
#!/bin/sh
# Dedicated DHCPv6 handler for BusyBox udhcpc6 on Alpine Linux

case "$1" in
    deconfig)
        [ -n "$ipv6" ] && ip -6 addr del "$ipv6"/128 dev "$interface" 2>/dev/null || true
        ;;
    renew|bound)
        if [ -n "$ipv6" ]; then
            ip -6 addr add "$ipv6"/128 dev "$interface"
        fi
        if [ -n "$dns" ]; then
            for server in $dns; do
                grep -q "$server" /etc/resolv.conf 2>/dev/null || echo "nameserver $server" >> /etc/resolv.conf
            done
        fi
        ;;
esac
exit 0
EOF
chmod 755 "${MOUNT_DIR}/usr/share/udhcpc/default6.script"

cat << 'EOF' > "${MOUNT_DIR}/etc/network/interfaces"
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    post-up udhcpc6 -R -b -p /var/run/udhcpc6.eth0.pid -i eth0 -s /usr/share/udhcpc/default6.script
EOF

echo "==> [6/6] Zero-filling free space and repacking raw image..."
rm -rf "${MOUNT_DIR}/var/cache/apk/*" "${MOUNT_DIR}/root/.ash_history" "${MOUNT_DIR}/var/log/*"

# Zero fill unused space on filesystem to maximize gzip compression
dd if=/dev/zero of="${MOUNT_DIR}/zero.fill" bs=1M status=none || true
rm -f "${MOUNT_DIR}/zero.fill"

# Unmount cleanly before archiving
umount -l "${MOUNT_DIR}/dev" 2>/dev/null || true
umount -l "${MOUNT_DIR}/proc" 2>/dev/null || true
umount -l "${MOUNT_DIR}/sys" 2>/dev/null || true
umount -l "${MOUNT_DIR}/boot/efi" 2>/dev/null || true
umount "${MOUNT_DIR}" 2>/dev/null || umount -l "${MOUNT_DIR}" || true
losetup -D 2>/dev/null || true
LOOP_DEV=""

TARGET_FORMAT="${TARGET_FORMAT:-gcp}"

# If format is vhdx or qcow2, use qemu-img to convert
case "${TARGET_FORMAT}" in
    vhdx|hyperv)
        VHDX_OUTPUT="${OUTPUT_ARCHIVE%.tar.gz}"
        VHDX_OUTPUT="${VHDX_OUTPUT%.raw}"
        VHDX_OUTPUT="${VHDX_OUTPUT%.vhdx}.vhdx"
        echo "Converting optimized raw disk to dynamic VHDX: ${VHDX_OUTPUT}..."
        qemu-img convert -f raw -O vhdx -o subformat=dynamic disk.raw "${VHDX_OUTPUT}"
        rm -f disk.raw
        echo "==> Done! Generated Hyper-V Gen2 VHDX: ${VHDX_OUTPUT}"
        ;;
    qcow2|kvm|qemu)
        QCOW2_OUTPUT="${OUTPUT_ARCHIVE%.tar.gz}"
        QCOW2_OUTPUT="${QCOW2_OUTPUT%.raw}"
        QCOW2_OUTPUT="${QCOW2_OUTPUT%.qcow2}.qcow2"
        echo "Converting optimized raw disk to compressed QCOW2: ${QCOW2_OUTPUT}..."
        qemu-img convert -c -f raw -O qcow2 disk.raw "${QCOW2_OUTPUT}"
        rm -f disk.raw
        echo "==> Done! Generated QCOW2: ${QCOW2_OUTPUT}"
        ;;
    raw)
        RAW_OUTPUT="${OUTPUT_ARCHIVE%.tar.gz}"
        echo "Preserving uncompressed disk.raw as ${RAW_OUTPUT}..."
        [ "$RAW_OUTPUT" != "disk.raw" ] && mv disk.raw "${RAW_OUTPUT}"
        echo "==> Done! Generated: ${RAW_OUTPUT}"
        ;;
    *)
        echo "Compressing optimized raw disk into ${OUTPUT_ARCHIVE}..."
        tar --numeric-owner -Sczf "${OUTPUT_ARCHIVE}" disk.raw
        rm -f disk.raw
        echo "==> Done! Generated: ${OUTPUT_ARCHIVE}"
        ;;
esac
