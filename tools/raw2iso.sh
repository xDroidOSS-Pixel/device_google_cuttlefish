#!/bin/bash
#
# Copyright (C) 2022 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -e
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

usage() {
  echo "usage: $0 [-h] -i input.raw -o output.iso"
  exit 1
}

input=
output=

while getopts ":hi:o:" opt; do
  case "${opt}" in
    h)
      usage
      ;;
    i)
      input="${OPTARG}"
      ;;
    o)
      output="${OPTARG}"
      ;;
    \?)
      echo "Invalid option: ${OPTARG}" >&2
      usage
      ;;
    :)
      echo "Invalid option: ${OPTARG} requires an argument" >&2
      usage
      ;;
  esac
done

if [[ -z "${input}" ]]; then
  echo "Must specify input file!"
  usage
fi

if [[ -z "${output}" ]]; then
  echo "Must specify output file!"
  usage
fi

grub_cmdline="ro net.ifnames=0 8250.nr_uarts=1 console=ttyS0 loglevel=4"
grub_rootfs="LABEL=rootfs"

# Validate format of the input disk
/sbin/sgdisk -p "${input}" | grep -q "Disk identifier (GUID)" || \
  ( echo "${input} is not a GUID partitioned disk!" && exit 2 )
partitions="$(/sbin/sgdisk -p "${input}" | \
                grep -m1 -A2 "Number  Start (sector)" | tail -n2)"
( IFS=$'\n'
for line in $partitions; do
  IFS=' ' read -r -a partition <<< "$line"
  if [[ "${partition[0]}" = "1" && "${partition[5]}" != "EF00" ]]; then
    echo "${input} partition 1 is not an ESP!" && exit 3
  fi
  if [[ "${partition[0]}" = "2" && "${partition[6]}" != "rootfs" ]]; then
    echo "${input} partition 2 is not rootfs!" && exit 4
  fi
done )

failure() {
  echo "ISO generation process failed." >&2
  rm -f "${output}"
}
trap failure ERR

mount=$(mktemp -d)
mount_remove() {
  rmdir "${mount}"
}
trap mount_remove EXIT

workdir=$(mktemp -d)
workdir_remove() {
  rm -rf "${workdir}"
  mount_remove
}
trap workdir_remove EXIT

# Build a grub.cfg for CD booting
cat >"${workdir}"/grub.cfg <<EOF
set timeout=0
menuentry "Linux" {
  linux /vmlinuz ${grub_cmdline} root=${grub_rootfs} init=/bin/sh
  initrd /initrd.img
}
EOF

# Build harddisk install script
cat >"${workdir}"/install.sh << EOF
#!/bin/sh
set -e
set -u
SCRIPT_DIR=\$(CDPATH= cd -- "\$(dirname -- "\${0}")" && pwd -P)
sgdisk --load-backup="\${SCRIPT_DIR}"/gpt.img \${1}
dd if="\${SCRIPT_DIR}"/esp.img of=\${1}1 bs=16M
mkfs.ext4 -L ROOT -U \$(cat \${SCRIPT_DIR}/rootfs_uuid) \${1}2
mount \${1}2 /media
tar -C /media -Spxf \${SCRIPT_DIR}/rootfs.tar.lz4
umount /media
EOF
chmod a+x "${workdir}"/install.sh

# Back up the GPT so we can restore it when installing
/sbin/sgdisk --backup="${workdir}"/gpt.img "${input}" >/dev/null

loopfile="$(/sbin/losetup -f)"
sudo losetup -P "${loopfile}" "${input}"
loopdev_remove() {
  sudo losetup -d "${loopfile}"
  workdir_remove
}
trap loopdev_remove EXIT

# Back up the ESP so we can restore it when installing
touch "${workdir}"/esp.img
sudo dd if="${loopfile}p1" of="${workdir}"/esp.img status=none >/dev/null

# Determine the architecture of the disk from the portable GRUB image path
sudo mount "${loopfile}p1" "${mount}"
unmount() {
  sudo umount "${mount}"
  loopdev_remove
}
trap unmount EXIT
grub_blob=$(cd "${mount}" && echo EFI/Boot/*)
case "${grub_blob}" in
  EFI/Boot/BOOTAA64.EFI)
    grub_arch=arm64-efi
    grub_cd=gcdaa64.efi
    ;;
  EFI/Boot/BOOTIA64.EFI)
    grub_arch=x86_64-efi
    grub_cd=gcdx64.efi
    ;;
  *)
    echo "Unknown GRUB architecture for ${grub_blob}!"
    exit 5
    ;;
esac
sudo umount "${mount}"
trap loopdev_remove EXIT

# Mount original rootfs and remove previous patching, then tar
rootfs_uuid=$(sudo blkid -s UUID -o value "${loopfile}p2")
sudo mount "${loopfile}p2" "${mount}"
trap unmount EXIT
sudo rm -f "${mount}"/root/esp.img "${mount}"/root/gpt.img
sudo rm -f "${mount}"/root/rootfs.tar.lz4
sudo rm -f "${mount}"/root/rootfs_uuid
sudo rm -f "${mount}"/boot/grub/eltorito.img
sudo rm -f "${mount}"/boot/grub/${grub_arch}/grub.cfg
sudo rm -rf "${mount}"/tmp/*
sudo rm -rf "${mount}"/var/tmp/*
( cd "${mount}" && sudo tar -Szcpf "${workdir}"/rootfs.tar.lz4 * )

# Prepare a new ESP for the ISO's El Torito image
mkdir -p "${workdir}/EFI/Boot"
cp "${mount}/usr/lib/grub/${grub_arch}/monolithic/${grub_cd}" \
  "${workdir}/${grub_blob}"
newfs_msdos -L SYSTEM -F 12 \
  -m 0xf8 -o 0 -c 4 -a 4 -h 64 -u 32 -S 512 -s 4096 -C 2M \
  "${workdir}"/eltorito.img >/dev/null
mmd -i "${workdir}"/eltorito.img EFI EFI/Boot
mcopy -o -i "${workdir}"/eltorito.img -s "${workdir}/EFI" ::

# Build ISO from rootfs
sudo cp "${workdir}"/esp.img "${workdir}"/gpt.img "${mount}"/root
sudo cp "${workdir}"/rootfs.tar.lz4 "${workdir}"/install.sh "${mount}"/root
echo -n "${rootfs_uuid}" | sudo tee "${mount}"/root/rootfs_uuid >/dev/null
sudo cp "${workdir}"/eltorito.img "${mount}"/boot/grub
sudo cp "${workdir}"/grub.cfg "${mount}"/boot/grub/${grub_arch}/grub.cfg
sudo chown root:root \
  "${mount}"/root/esp.img "${mount}"/root/gpt.img \
  "${mount}"/boot/grub/eltorito.img \
  "${mount}"/boot/grub/${grub_arch}/grub.cfg
rm -f "${output}"
touch "${output}"
sudo xorriso \
  -as mkisofs -r -checksum_algorithm_iso sha256,sha512 -V rootfs "${mount}" \
  -o "${output}" -e boot/grub/eltorito.img -no-emul-boot \
  -append_partition 2 0xef "${workdir}"/eltorito.img \
  -partition_cyl_align all

echo "Output ISO generated at '${output}'."