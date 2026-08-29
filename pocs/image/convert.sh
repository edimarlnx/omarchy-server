#!/bin/bash
# Convert a generalized VM disk into the distributable cloud image.
#
#   ./pocs/image/convert.sh <source-disk.qcow2> <out.qcow2>
#
# `qemu-img convert -c -O qcow2`: compressed, and a full convert rather than a
# copy, so the result carries no snapshot chain, no backing file and none of
# the qcow2 refcount churn a 40 GiB disk accumulates during an install. The
# machine was fstrim'ed before it stopped (omarchy-server-generalize phase 2),
# which is what makes the compression worth anything: without the trim, every
# package file the install downloaded and the generalize deleted is still in
# the image as data nothing references.
#
# Writes the image, its .sha256, and prints the size the release asset will be.
set -euo pipefail

src="${1:?source disk}"
dst="${2:?output image}"

command -v qemu-img >/dev/null || { echo "missing tool: qemu-img" >&2; exit 1; }
[[ -f $src ]] || { echo "no such disk: $src" >&2; exit 1; }

mkdir -p "$(dirname "$dst")"
rm -f "$dst" "$dst.sha256"

echo "› converting $src"
started=$(date +%s)
qemu-img convert -p -c -O qcow2 "$src" "$dst"
elapsed=$(($(date +%s) - started))

# The checksum is of the file that will be uploaded, computed here rather than
# by whoever uploads it, so the release asset and the local artifact are
# provably the same bytes.
(cd "$(dirname "$dst")" && sha256sum "$(basename "$dst")" >"$(basename "$dst").sha256")

# The human-readable form, not --output=json: the JSON nests a `children[0]`
# describing the FILE, whose own "virtual-size" is the size on disk and which
# comes FIRST in the document. Any "take the first virtual-size" parse of it
# reports the compressed size as the virtual one, which is what this printed
# until somebody read the output.
virtual=$(qemu-img info "$dst" | sed -n 's/^virtual size:.*(\([0-9]*\) bytes)/\1/p' | head -1)
actual=$(stat -c %s "$dst")

echo
echo "image:    $dst"
echo "size:     $(numfmt --to=iec --suffix=B "$actual") ($actual bytes)"
echo "virtual:  $(numfmt --to=iec --suffix=B "${virtual:-0}")"
echo "sha256:   $(cut -d' ' -f1 <"$dst.sha256")"
echo "convert:  $((elapsed / 60))m$((elapsed % 60))s"

# The GitHub release asset limit this repository publishes under. Saying it
# here means a build that outgrows it fails at the build, not at the upload.
limit=$((2 * 1024 * 1024 * 1024))
if ((actual > limit)); then
  echo
  echo "WARNING: $actual bytes is over the 2 GiB release-asset budget." >&2
fi
