#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Prints the internal-header set to build against for a kernel release.
# Unknown kernels are refused (exit 1): the HDA internal headers are not part
# of the kernel's public API and must match the running kernel exactly.
case "$1" in
7.0.0-43-generic|7.0.0-44-generic)
	echo ubuntu-7.0 ;;
*)
	if printf '%s\n' "$1" | grep -Eqx '7\.0\.[0-9]+'; then
		echo mainline-7.0
	else
		echo "select-headers: kernel '$1' is not supported (see README, 'Supported kernels')" >&2
		exit 1
	fi ;;
esac
