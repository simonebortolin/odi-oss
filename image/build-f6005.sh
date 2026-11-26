#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Simone Bortolin
# SPDX-License-Identifier: GPL-2.0-or-later

#
# Assemble a flashable cramfs image for the ZTE F6005 (CIG G-97CP).
#
# The CIG bootloader expects a cramfs filesystem with /uImage inside it,
# optionally followed by a 4-byte checksum. The bootloader:
#   1. Reads the cramfs from the image partition (Image A or Image B)
#   2. Extracts /uImage from the cramfs
#   3. Loads /uImage to RAM at 0x80000000
#   4. Boots with root=/dev/mtdblock2 (the cramfs partition itself)
#
# Flash layout (16 MB SPI NOR):
#   0x000000 - 0x02CF00  Bootloader (CIG BSP V3.09.15, U-Boot 2011.12)
#   0x030000 - 0x040000  Environment
#   0x040000 - 0x050000  Config
#   0x200000 - 0x900000  Image A (7 MB, cramfs)
#   0x900000 - 0x1000000 Image B (7 MB, cramfs)
#
# Flashing on the device via serial console:
#   upgdimage 0 <tftp-server-ip> <filename>    # writes Image A
#   upgdimage 1 <tftp-server-ip> <filename>    # writes Image B
#   set activeimage imagea                      # select Image A for next boot
#
# The output is a single cramfs file, ready for TFTP to the bootloader's
# upgdimage command.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$("$ROOT/tools/source-date-epoch.sh")}
export SOURCE_DATE_EPOCH
umask 022
fmt_epoch() { date -u -d "@$SOURCE_DATE_EPOCH" "$1" 2>/dev/null || date -u -r "$SOURCE_DATE_EPOCH" "$1"; }

# Image A and Image B are each 7 MB (0x700000 = 7340032 bytes).
IMAGE_PART=$((0x700000))

COMP=${COMP:-xz}
BS=${BS:-262144}

TOOLS=${TOOLS_IMAGE:-odi-oss-image}
GITREV=$(git -C "$ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo nogit)
VERSION=${VERSION:-odi-oss-f6005-$(fmt_epoch +%y%m%d)-$GITREV}
BUSYBOX=${BUSYBOX:-$ROOT/out/busybox}
KCONFIG=${KCONFIG:-}
BIN_DIR=${BIN_DIR:-$ROOT/out/bin}
ASSET_DIR=${ASSET_DIR:-$ROOT/out/confd-assets}
PKG_DIR=${PKG_DIR:-$ROOT/out}

KERNEL=${KERNEL:-}
if [ -z "$KERNEL" ]; then
	[ -f "$ROOT/build/kernel-618/uImage" ] && KERNEL=$ROOT/build/kernel-618/uImage
fi
if [ -z "$KCONFIG" ]; then
	KERNEL_DIR=$(dirname "${KERNEL:-/dev/null}")
	[ -f "$KERNEL_DIR/config" ] && KCONFIG=$KERNEL_DIR/config
fi

STAGE=$ROOT/build/rootfs-f6005
OUT=$ROOT/out/image

say()  { printf '\n== %s\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }
size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

missing=""
[ -n "$KERNEL" ] && [ -f "$KERNEL" ] || missing="$missing
  kernel         make kernel ODI_BOARD=f6005 (or KERNEL=<uImage>)"
[ -f "$BUSYBOX" ] || missing="$missing
  busybox        make busybox (at $BUSYBOX)"
[ -z "$missing" ] ||
	die "image/build-f6005.sh: missing inputs:$missing"

say "build environment"
docker build -q -t "$TOOLS" -f "$ROOT/image/Dockerfile" "$ROOT/image" >/dev/null
run() { docker run --rm -e SOURCE_DATE_EPOCH -v "$ROOT:/work" -w /work "$TOOLS" "$@"; }

say "staging the rootfs"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,sbin,lib,etc,dev,proc,sys,var,mnt,root}

install -m 755 "$BUSYBOX" "$STAGE/bin/busybox"

say "linking busybox applets"
APPLETS=$(run qemu-mips-static "${BUSYBOX#"$ROOT/"}" --list)
[ -n "$APPLETS" ] || die "busybox --list produced nothing"
n=0
for a in $APPLETS; do
	[ "$a" = busybox ] && continue
	case "$a" in
	init|telnetd|mdev|ifconfig|route|reboot|halt|poweroff|klogd|syslogd|\
	insmod|rmmod|lsmod|modprobe|switch_root|sysctl|logread|watchdog|\
	start-stop-daemon|udhcpc|arp|nameif|vconfig|brctl|devmem|setconsole)
		ln -sf ../bin/busybox "$STAGE/sbin/$a" ;;
	*)
		ln -sf busybox "$STAGE/bin/$a" ;;
	esac
	n=$((n + 1))
done
echo "  $n applets"
[ -e "$STAGE/bin/sh" ]    || die "busybox has no sh applet -- nothing would boot"
[ -e "$STAGE/sbin/init" ] || die "busybox has no init applet -- nothing would boot"

say "applying the skeleton"
cp -a "$ROOT/rootfs/skeleton/." "$STAGE/"
chmod 755 "$STAGE"/etc/init.d/* "$STAGE"/etc/scripts/*

say "register replay tables (from tools/regtrace/tables)"
FW_OUT=$ROOT/out/firmware/odi
mkdir -p "$FW_OUT" "$STAGE/lib/firmware/odi"
for t in sdkinit modload gpon_init; do
	run python3 tools/regtrace/replayblob.py build "tools/regtrace/tables/$t.txt" - \
		> "$FW_OUT/$t.bin.tmp" || die "replayblob.py build of $t failed"
	mv "$FW_OUT/$t.bin.tmp" "$FW_OUT/$t.bin"
	install -m 644 "$FW_OUT/$t.bin" "$STAGE/lib/firmware/odi/$t.bin"
done

rm -rf "$STAGE/tmp"
ln -s /var/tmp "$STAGE/tmp"

say "our binaries (from $BIN_DIR)"
found=0
for b in diag omcid omcli omciprobe omcicap nv igmpd metricsd confd; do
	if [ -f "$BIN_DIR/$b" ]; then
		install -m 755 "$BIN_DIR/$b" "$STAGE/bin/$b"
		printf '  %-10s %8d\n' "$b" "$(size "$BIN_DIR/$b")"
		found=$((found + 1))
	fi
done
[ "$found" = 0 ] &&
	echo "  none -- this image boots to a shell and runs no service of ours"
[ -f "$STAGE/bin/omcli" ] && ln -sf omcli "$STAGE/bin/omcicli"

say "kernel modules"
echo "  none -- odi_switch is built into vmlinux (CONFIG_ODI_SWITCH=y)"

say "upstream packages (from $PKG_DIR)"
pkg=0
for p in dropbearmulti ip; do
	if [ -f "$PKG_DIR/$p" ]; then
		if [ "$p" = dropbearmulti ]; then
			install -m 755 "$PKG_DIR/$p" "$STAGE/sbin/$p"
			ln -sf dropbearmulti "$STAGE/sbin/dropbear"
			ln -sf dropbearmulti "$STAGE/sbin/dropbearkey"
			ln -sf ../sbin/dropbearmulti "$STAGE/bin/scp"
		else
			install -m 755 "$PKG_DIR/$p" "$STAGE/sbin/$p"
		fi
		printf '  %-10s %8d\n' "$p" "$(size "$PKG_DIR/$p")"
		pkg=$((pkg + 1))
	fi
done
[ "$pkg" = 0 ] && echo "  none"

say "build manifest"
{
	echo "image=$VERSION"
	echo "board=f6005"
	echo "built=$(fmt_epoch '+%Y-%m-%dT%H:%MZ')"
	kver=$(sed -n "s/^# Linux\/[^ ]* \([0-9][^ ]*\) Kernel Configuration.*/\1/p" "${KCONFIG:-/dev/null}" 2>/dev/null | head -n 1)
	echo "kernel=${kver:-$(basename "$KERNEL")}"
	echo "version:   $VERSION"
	echo "board:     ZTE F6005 (CIG G-97CP)"
	echo "built:     $(fmt_epoch '+%Y-%m-%dT%H:%M:%SZ')"
} > "$STAGE/etc/odi-build"
echo "$VERSION -- $(fmt_epoch '+%a %d %b %Y %H:%M:%S %Z')" > "$STAGE/etc/version"

say "accounts"
PW=${ROOT_PW:-locked}
"$ROOT/image/gen-root-account.sh" "$STAGE" "$OUT" "$VERSION" "$PW"
echo "  root password: $PW"

# The CIG bootloader extracts /uImage from the cramfs, so the kernel lives
# inside the root filesystem image.
say "embedding the kernel as /uImage"
cp "$KERNEL" "$STAGE/uImage"
KSIZE=$(size "$KERNEL")
printf '  uImage: %d bytes\n' "$KSIZE"

# Build the cramfs image. mkcramfs is from util-linux.
say "building cramfs image"
CRAMFS=$ROOT/build/f6005.cramfs
run mkcramfs "$STAGE" "$CRAMFS" 2>&1 | sed 's/^/  /'

ISIZE=$(size "$CRAMFS")
printf '  cramfs:  %10d / %10d bytes  (%d spare)\n' \
	"$ISIZE" "$IMAGE_PART" "$((IMAGE_PART - ISIZE))"

if [ "$ISIZE" -gt "$IMAGE_PART" ]; then
	die "REFUSING: cramfs image exceeds the 7 MB partition by $((ISIZE - IMAGE_PART)) bytes"
fi

mkdir -p "$OUT"
FINAL=$OUT/$VERSION.cramfs
cp "$CRAMFS" "$FINAL"

say "done"
ls -l "$FINAL"
cat <<EOF

This cramfs image is for the ZTE F6005 (CIG G-97CP). Flash via serial:
    tftp 0x80000000 $VERSION.cramfs
    upgdimage 0 <tftp-server-ip> $VERSION.cramfs
    set activeimage imagea
    reboot
EOF
