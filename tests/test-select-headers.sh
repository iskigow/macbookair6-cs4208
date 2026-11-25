#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Checks that packaging/select-headers.sh maps only known kernels to a header set.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
sel="$here/packaging/select-headers.sh"
fail=0

expect() { # <kernelrelease> <expected set | FAIL>
	local out rc
	out=$("$sel" "$1" 2>/dev/null); rc=$?
	if [ "$2" = FAIL ]; then
		if [ $rc -eq 0 ]; then echo "FAIL: $1 -> '$out' (expected refusal)"; fail=1
		else echo "ok:   $1 refused"; fi
	else
		if [ $rc -ne 0 ] || [ "$out" != "$2" ]; then echo "FAIL: $1 -> '$out' rc=$rc (expected $2)"; fail=1
		else echo "ok:   $1 -> $out"; fi
	fi
}

expect 7.0.0-43-generic ubuntu-7.0
expect 7.0.0-44-generic ubuntu-7.0
expect 7.0.0-45-generic FAIL
expect 7.0.0-44-lowlatency FAIL
expect 6.18.0 FAIL
expect 6.17.0-5-generic FAIL
expect 7.0.3 mainline-7.0
expect 7.0 FAIL
expect 7.0.3-arch1-1 FAIL
expect 7.1.0 FAIL
expect "" FAIL

exit $fail
