#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# scripts/pre-push refuses tags that are not signed vX.Y.Z tags on a commit
# of the remote main whose VERSION and dkms.conf say X.Y.Z.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/scripts/pre-push"
work=$(mktemp -d)
export GNUPGHOME="$work/gnupg"; mkdir -m 700 "$GNUPGHOME"
trap 'gpgconf --kill gpg-agent >/dev/null 2>&1; rm -rf "$work"' EXIT
fail=0
ok()  { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }
zero=0000000000000000000000000000000000000000

gpg -q --batch --pinentry-mode loopback --passphrase '' \
	--quick-gen-key "Hook Test <hook@example.org>" ed25519 sign never 2>/dev/null
fpr=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')

git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/r" 2>/dev/null
cd "$work/r" || exit 1
git config user.name "Hook Test"; git config user.email hook@example.org
git config user.signingkey "$fpr"; git config commit.gpgsign false
setv() { echo "$1" > VERSION; echo "PACKAGE_VERSION=\"$1\"" > dkms.conf; git add -A; git commit -qm "$2"; }
echo 'PACKAGE_VERSION="0.1.2"' > dkms.conf; git add -A; git commit -qm "release before VERSION existed"; c_old=$(git rev-parse HEAD)
setv 0.1.3 "last commit of 0.1.3"; c_rel=$(git rev-parse HEAD)
setv 0.1.4 "bump to 0.1.4"
git push -q origin HEAD:main 2>/dev/null
git checkout -q -b side "$c_rel"; echo x > side.txt; git add side.txt; git commit -qm side; c_side=$(git rev-parse HEAD)
git checkout -q -

push() { # <tag ref name> <object sha> <expected rc> <label>
	printf 'refs/tags/%s %s refs/tags/%s %s\n' "$1" "$2" "$1" "$zero" |
		"$hook" origin "$work/origin.git" > "$work/out" 2>&1
	local rc=$?
	if [ $rc -eq "$3" ]; then ok "$4"; else bad "$4 (rc=$rc)"; cat "$work/out"; fi
}

git tag -s v0.1.3 -m v0.1.3 "$c_rel"
push v0.1.3 "$(git rev-parse v0.1.3)" 0 "signed v0.1.3 on the commit before the bump is accepted"
git tag -s v0.1.9 -m v0.1.9 "$c_rel"
push v0.1.9 "$(git rev-parse v0.1.9)" 1 "tag name that does not match VERSION is refused"
git tag -s release-1 -m r "$c_rel"
push release-1 "$(git rev-parse release-1)" 1 "tag not named vX.Y.Z is refused"
git tag -s v0.1.5 -m v0.1.5 "$c_side"
push v0.1.5 "$(git rev-parse v0.1.5)" 1 "tag on a commit that is not on main is refused"
git tag -a v0.1.6 -m v0.1.6 "$c_rel"
push v0.1.6 "$(git rev-parse v0.1.6)" 1 "unsigned annotated tag is refused"
git tag v0.1.7 "$c_rel"
push v0.1.7 "$(git rev-parse v0.1.7)" 1 "lightweight tag is refused"
git tag -s v0.1.2 -m v0.1.2 "$c_old"
push v0.1.2 "$(git rev-parse v0.1.2)" 0 "older release without VERSION is checked against dkms.conf only"
printf 'refs/tags/v0.1.3 %s refs/tags/v0.1.3 %s\n' "$zero" "$(git rev-parse v0.1.3)" |
	"$hook" origin "$work/origin.git" >/dev/null 2>&1 && ok "tag deletion is not blocked by the hook" || bad "tag deletion blocked"
printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$zero" |
	"$hook" origin "$work/origin.git" >/dev/null 2>&1 && ok "branch push without tags passes" || bad "branch push blocked"
exit $fail
