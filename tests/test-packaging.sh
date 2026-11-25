#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# packaging/Makefile: refuses unknown kernels (once, with a clear message,
# non-zero exit) and uses every header of the selected set, generic.h included.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
pk="$here/packaging"
kver=$(uname -r)
fail=0

out=$(make -C "$pk" KVER=7.0.0-999-generic 2>&1); rc=$?
n=$(grep -c "is not supported" <<< "$out")
if [ $rc -ne 0 ] && [ "$n" -eq 1 ]; then echo "ok:   unknown kernel refused once (rc=$rc)"
else echo "FAIL: unknown kernel: rc=$rc, message count $n"; echo "$out"; fail=1; fi

# a header set overriding generic.h and hda_jack.h must be the one compiled
set=test-probe-$$
mkdir "$pk/headers/$set"; trap 'rm -rf "$pk/headers/$set"; make -s -C "$pk" clean' EXIT
for h in generic.h hda_jack.h; do
	echo "#error probe-$h-used" > "$pk/headers/$set/$h"
	out=$(make -C "$pk" KVER="$kver" HEADER_SET="$set" 2>&1)
	if grep -q "probe-$h-used" <<< "$out"; then echo "ok:   $h from the header set is used"
	else echo "FAIL: $h from the header set is ignored"; fail=1; fi
	rm "$pk/headers/$set/$h"
done
exit $fail
