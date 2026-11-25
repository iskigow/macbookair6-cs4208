#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Builds the pristine import (src/ at the repository's first commit) with
# the current packaging for the running kernel and checks that it is
# machine-code identical to the distribution's stock module (proves that the
# selected internal-header set matches the running kernel). Also builds with
# the wrong header set as a negative control: that build must differ.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
kver=${KVER:-$(uname -r)}
max_diff=4
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# stock module: DKMS's archived original first (DKMS replaces the live one),
# then the distribution path; any compression
stock=""
for f in /var/lib/dkms/*/original_module/"$kver"/*/snd-hda-codec-cs420x.ko* \
	 /lib/modules/"$kver"/kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko*; do
	case "$f" in *.ko|*.ko.zst|*.ko.xz|*.ko.gz) [ -f "$f" ] && { stock=$f; break; } ;; esac
done
[ -n "$stock" ] || { echo "FAIL: no stock module found for $kver"; exit 1; }
case "$stock" in
*.zst) zstd -qdc "$stock" ;;
*.xz)  xz -dc "$stock" ;;
*.gz)  gzip -dc "$stock" ;;
*)     cat "$stock" ;;
esac > "$work/stock.ko" || exit 1
echo "stock module: $stock"

# pristine sources = src/ at the root commit (later commits carry the fixes)
root=$(git -C "$here" rev-list --max-parents=0 HEAD) || { echo "FAIL: needs a git checkout"; exit 1; }
git -C "$here" archive "$root" src | tar -x -C "$work" || exit 1

disasm() { # normalise symbol-label numbers (e.g. __UNIQUE_ID_xxx123)
	objdump -d --no-show-raw-insn "$1" | tail -n +3 | sed -E 's/[0-9]+>/N>/g'
}

build() { # <header set override or empty> <out .ko>
	make -s -C "$here/packaging" KVER="$kver" clean >/dev/null 2>&1
	make -s -C "$here/packaging" KVER="$kver" SRCROOT="$work/src" ${1:+HEADER_SET=$1} > "$work/build.log" 2>&1 \
		|| { cat "$work/build.log"; return 1; }
	cp "$here/packaging/build/$kver/snd-hda-codec-cs420x.ko" "$2"
}

fail=0
set_name=$("$here/packaging/select-headers.sh" "$kver") || { echo "FAIL: $kver unsupported"; exit 1; }

build "" "$work/ours.ko" || { echo "FAIL: build"; exit 1; }
# exactly one hda_local.h, from the expected place
objdir="$here/packaging/build/$kver/codecs/cirrus"
deps=$(cd "$objdir" && grep -o '[^ ]*hda_local\.h' .cs420x.o.cmd | xargs -r realpath | sort -u)
echo "hda_local.h used: $deps"
if [ "$(echo "$deps" | wc -l)" -ne 1 ]; then echo "FAIL: more than one hda_local.h"; fail=1; fi
expected_hdr="$here/packaging/headers/$set_name/hda_local.h"
[ -f "$expected_hdr" ] || expected_hdr="$work/src/sound/hda/common/hda_local.h"
if [ "$deps" != "$here/packaging/build/$kver/common/hda_local.h" ] || ! cmp -s "$deps" "$expected_hdr"; then echo "FAIL: hda_local.h is not the $set_name one"; fail=1; fi

n=$(diff <(disasm "$work/stock.ko") <(disasm "$work/ours.ko") | grep -c '^[<>]')
echo "set $set_name: $n differing lines (max $max_diff)"
[ "$n" -le "$max_diff" ] || fail=1

# negative control: the other header set must change the machine code
other=mainline-7.0; [ "$set_name" = mainline-7.0 ] && other=ubuntu-7.0
build "$other" "$work/wrong.ko" || { echo "FAIL: negative-control build"; exit 1; }
m=$(diff <(disasm "$work/stock.ko") <(disasm "$work/wrong.ko") | grep -c '^[<>]')
echo "negative control ($other): $m differing lines (must be > $max_diff)"
[ "$m" -gt "$max_diff" ] || fail=1
make -s -C "$here/packaging" KVER="$kver" clean >/dev/null 2>&1

[ $fail -eq 0 ] && echo PASS || echo FAIL
exit $fail
