#!/bin/bash
# Build the iOS root filesystem image for sky: one case-sensitive HFS+ volume
# holding the iOS root plus its cryptexes, for the userdata partition.
#
#   mkiosroot.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]     (SIZE default 12G)
#
# Ported from ios-sweet's tools/mkiosroot.sh (nabu). Differences: volume label
# and comments; the layout and all the XNU-specific fixups are unchanged, since
# they are properties of iOS 16.7 + our kernel, not of the board.
#
# Why each step exists (from the original, kept verbatim in intent):
#   * The IPSW images are raw APFS with LZBITMAP-compressed files, read through
#     apfs-fuse, so the HFS+ copy ends up uncompressed.
#   * On a device /private/preboot is its own volume holding the cryptexes;
#     here they live inside the one volume.
#   * Owners, modes, symlinks and hard links are preserved (rsync -aH as root).
#   * The volume is journaled: XNU replays the journal after a panic.
#   * /System/Library/Caches/com.apple.dyld must hard-link the SystemOS cryptex
#     shared cache, because ignition_level=1 looks there.
#   * /private/var/keybags/systembag.kb is the plain-plist system keybag that
#     keybagd reads when /defaults/no-effaceable-storage is present.
#   * logd's stores must exist with owner _logd (272) and a .migrated marker,
#     else libtrace panics with "BUG IN LIBTRACE: Failed to migrate directory".
set -euo pipefail

[[ $# -ge 4 ]] || { sed -n '2,20p' "$0"; exit 2; }
os=$(realpath "$1") sysos=$(realpath "$2") appos=$(realpath "$3") out=$4 size=${5:-12G}
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }

missing_tools=()
for tool in apfs-fuse mkfs.hfsplus rsync; do
	command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if [[ ${#missing_tools[@]} -gt 0 ]]; then
	echo "Error: missing host utilities: ${missing_tools[*]}" >&2
	echo "  Ubuntu/Debian: sudo apt install apfs-fuse hfsprogs rsync" >&2
	exit 1
fi

work=$(mktemp -d)
mounts=()
cleanup() {
	local busy=0
	for m in "${mounts[@]}"; do
		mountpoint -q "$m" && { sudo umount "$m" 2>/dev/null || true; }
		mountpoint -q "$m" && busy=1
	done
	if [[ $busy == 0 ]]; then
		rm -f "$work"/*.dmg
		rmdir "$work"/* "$work" 2>/dev/null || true
	else
		echo "still mounted under $work: left in place" >&2
	fi
}
trap cleanup EXIT

# apfs-fuse splits its options on ',' (iPhone10,3 paths contain one): use links.
# Keep the .dmg suffix because apfs-fuse only parses UDIF images by extension.
apfs_mount() {
	ln -s "$1" "$work/$2.dmg"
	mkdir "$work/$2"
	sudo "$(command -v apfs-fuse)" "$work/$2.dmg" "$work/$2"
	mounts+=("$work/$2")
}
apfs_mount "$os" os
apfs_mount "$sysos" sysos
apfs_mount "$appos" appos

truncate -s "$size" "$out"
mkfs.hfsplus -s -J -v iOSRoot "$out"
mkdir "$work/root"
sudo mount -t hfsplus -o loop,force "$out" "$work/root"
mounts=("$work/root" "${mounts[@]}")

copy() {
	echo "copying $1 -> ${2#"$work/root"}"
	sudo mkdir -p "$2"
	sudo rsync -aH --numeric-ids "$1/" "$2/"
}
copy "$work/os/root" "$work/root"
copy "$work/sysos/root" "$work/root/private/preboot/Cryptexes/OS"
copy "$work/appos/root" "$work/root/private/preboot/Cryptexes/App"

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
sudo mkdir -p "$work/root/System/Library/Caches/com.apple.dyld"
for f in "$work/root/$dsc"/*; do
	sudo ln "$f" "$work/root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# dyld does not search the cryptexes at ignition level 1: hard-link every
# cryptex file with no counterpart in the OS root (libobjc-trampolines,
# libffi-trampolines, libstdc++, ...) to its root path.
for c in OS App; do
	(cd "$work/root/private/preboot/Cryptexes/$c" && sudo find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if ! sudo test -e "$work/root/$f" && ! sudo test -L "$work/root/$f"; then
			sudo mkdir -p "$work/root/$(dirname "$f")"
			src="$work/root/private/preboot/Cryptexes/$c/$f"
			# Linux hfsplus cannot hard-link symlinks: copy those.
			if sudo test -L "$src"; then sudo cp -P "$src" "$work/root/$f"; else sudo ln "$src" "$work/root/$f"; fi
			echo "linked $c:/$f"
		fi
	done
done

# logd's log stores, normally made at restore.
db="$work/root/private/var/db"
sudo install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
sudo install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	sudo install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
sudo install -d -m 0700 -o 0 -g 0 "$work/root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' |
	sudo install -m 0600 -o 0 -g 0 /dev/stdin "$work/root/private/var/keybags/systembag.kb"

df -h "$work/root"
sudo umount "$work/root"
# Linux hfsplus decomposes some non-ASCII names differently from Apple's tables;
# let fsck_hfs rewrite them, then verify.
fsck.hfsplus -f -y "$out" | grep -v 'Illegal name' || true
fsck.hfsplus -f -n "$out"
echo "iOS root image ready: $out"
