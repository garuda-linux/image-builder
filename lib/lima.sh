# shellcheck shell=bash
# The Lima image: the root layer on the disk layout of lib/disk.sh.

post_lima() {
  local raw="$OUTPUT_DIR/garuda-lima.raw"

  disk_mount "$raw"
  disk_fstab
  # Lima reads boot output from the serial console (serial.log)
  disk_boot loglevel=3 quiet console=tty0 console=ttyS0,115200
  disk_unmount

  disk_qcow2 "$raw" garuda-lima
}
