#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# The release version is written only in VERSION; everything else must
# agree with it or not mention it.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
ok()  { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

ver=$(cat "$here/VERSION" 2>/dev/null)
[[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "VERSION is x.y.z ($ver)" || bad "VERSION missing or malformed: '$ver'"

dk=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$here/dkms.conf")
[ "$dk" = "$ver" ] && ok "dkms.conf PACKAGE_VERSION matches VERSION" || bad "dkms.conf has '$dk', VERSION has '$ver'"

# no hard-coded release in the README
hits=$(grep -nE '(macbookair6-cs4208[-/]|v)[0-9]+\.[0-9]+\.[0-9]+' "$here/README.md")
[ -z "$hits" ] && ok "README does not hard-code a version" || { bad "README hard-codes a version:"; echo "$hits"; }

# every release tag carries its own version in dkms.conf
if git -C "$here" rev-parse --git-dir >/dev/null 2>&1; then
	for t in $(git -C "$here" tag -l 'v[0-9]*'); do
		tv=$(git -C "$here" show "$t:dkms.conf" 2>/dev/null | sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p')
		[ "v$tv" = "$t" ] && ok "tag $t has PACKAGE_VERSION $tv" || bad "tag $t has PACKAGE_VERSION '$tv'"
	done
	last=$(git -C "$here" tag -l 'v[0-9]*' --sort=-v:refname | head -1)
	if [ -n "$last" ]; then
		top=$(printf '%s\n%s\n' "${last#v}" "$ver" | sort -V | tail -1)
		[ "$top" = "$ver" ] && ok "VERSION ($ver) is not older than the last tag ($last)" || bad "VERSION $ver is older than $last"
	fi
fi

# set-version.sh updates both files and refuses bad input
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/r/scripts"; cp "$here/VERSION" "$here/dkms.conf" "$work/r/"; cp "$here/scripts/set-version.sh" "$work/r/scripts/" 2>/dev/null
if [ -x "$work/r/scripts/set-version.sh" ]; then
	"$work/r/scripts/set-version.sh" 9.8.7 >/dev/null 2>&1
	[ "$(cat "$work/r/VERSION")" = 9.8.7 ] && grep -qx 'PACKAGE_VERSION="9.8.7"' "$work/r/dkms.conf" \
		&& ok "set-version.sh updates VERSION and dkms.conf" || bad "set-version.sh did not update both files"
	"$work/r/scripts/set-version.sh" 1.2 >/dev/null 2>&1 && bad "set-version.sh accepted '1.2'" || ok "set-version.sh refuses '1.2'"
	[ "$(cat "$work/r/VERSION")" = 9.8.7 ] && ok "refused input leaves files unchanged" || bad "refused input changed VERSION"
else bad "scripts/set-version.sh missing"; fi
exit $fail
