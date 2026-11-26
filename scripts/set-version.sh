#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Sets the release version. VERSION is the only place where it is
# written; dkms.conf needs a literal PACKAGE_VERSION, so it is updated
# from it. The README takes the version from the release tag.
#
#   scripts/set-version.sh <major.minor.patch>
#
# Then commit, open a pull request, merge, and only then create the
# signed tag v<version> (see CONTRIBUTING.md, "Releasing").
set -eu
v=${1:-}
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <major.minor.patch>" >&2; exit 2; }
top=$(cd "$(dirname "$0")/.." && pwd)
printf '%s\n' "$v" > "$top/VERSION"
sed -i "s/^PACKAGE_VERSION=\".*\"\$/PACKAGE_VERSION=\"$v\"/" "$top/dkms.conf"
grep -qx "PACKAGE_VERSION=\"$v\"" "$top/dkms.conf" || { echo "dkms.conf was not updated" >&2; exit 1; }
echo "version set to $v in VERSION and dkms.conf"
