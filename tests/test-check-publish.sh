#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# scripts/check-publish.sh must flag private data / Apple files and pass clean trees.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
chk="$here/scripts/check-publish.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0

expect() { # <dir> <expected rc> <label>
	"$chk" "$1" > "$work/out" 2>&1; local rc=$?
	if [ $rc -ne "$2" ]; then echo "FAIL: $3 (rc=$rc, expected $2)"; cat "$work/out"; fail=1
	else echo "ok:   $3"; fi
}

mkdir "$work/clean"; echo "nothing to see" > "$work/clean/a.txt"
expect "$work/clean" 0 "clean tree passes"

i=0
for bad in '/home/x/file' 'me@gmail.com' 'x@proton.me' 'made with superpowers' \
	   'copy AppleHDA.kext here' 'layout28.xml' 'see NOTES.md'; do
	i=$((i+1)); mkdir "$work/bad$i"; printf '%s\n' "$bad" > "$work/bad$i/f.txt"
	expect "$work/bad$i" 1 "content '$bad' flagged"
done

mkdir "$work/kc"; : > "$work/kc/BaseSystemKernelExtensions.kc"
expect "$work/kc" 1 "Apple kernel collection file name flagged"
mkdir -p "$work/kext/AppleHDA.kext"; : > "$work/kext/AppleHDA.kext/Info.plist"
expect "$work/kext" 1 "kext directory flagged"

# binary file, symlink, Apple resource name, case variants
mkdir "$work/bin"; printf 'x\0/home/s/x\n' > "$work/bin/f.bin"
expect "$work/bin" 1 "private path inside a binary file flagged"
mkdir "$work/ln"; ln -s /home/s/p "$work/ln/link"
expect "$work/ln" 1 "symlink to a home path flagged"
mkdir "$work/zl"; : > "$work/zl/layout113.xml.zlib"
expect "$work/zl" 1 "compressed layout resource flagged"
mkdir "$work/sp"; mkdir "$work/sp/SuperPowers"; : > "$work/sp/SuperPowers/x"
expect "$work/sp" 1 "forbidden word in a path flagged"
mkdir "$work/ca"; printf 'Co-Authored-By: someone\n' > "$work/ca/m.txt"
expect "$work/ca" 1 "Co-Authored-By flagged"
mkdir "$work/cs"; printf 'see https://claude.ai/code/session_x\n' > "$work/cs/m.txt"
expect "$work/cs" 1 "assistant session link flagged"

g="$work/git"; mkdir "$g"; echo ok > "$g/a.txt"
git -C "$g" init -q && git -C "$g" add a.txt
git -C "$g" -c user.name=X -c user.email=x@example.org commit -qm init
expect "$g" 0 "git repo with neutral identity passes"
git -C "$g" -c user.name=X -c user.email=me@gmail.com commit -q --allow-empty -m two
expect "$g" 1 "private e-mail in git identity flagged"

h="$work/git2"; mkdir "$h"; echo ok > "$h/a.txt"
git -C "$h" init -q && git -C "$h" add a.txt
git -C "$h" -c user.name="Jane Secretname" -c user.email=j@example.org commit -qm init
expect "$h" 0 "unlisted name passes"
echo 'secretname' > "$h/.git/check-publish-patterns"
expect "$h" 1 "local private pattern (.git/check-publish-patterns) flagged"


b2="$work/blank"; mkdir "$b2"; git -C "$b2" init -q; echo ok > "$b2/a.txt"; git -C "$b2" add a.txt
git -C "$b2" -c user.name=X -c user.email=x@example.org commit -qm one
printf 'other\n\n' > "$b2/.git/check-publish-patterns"
expect "$b2" 0 "blank line in local patterns does not match everything"

printf 'foo(\n' > "$h/.git/check-publish-patterns"
git -C "$h" -c user.name=X -c user.email=me@gmail.com commit -q --allow-empty -m four
expect "$h" 2 "invalid local pattern is an error, not 'clean'"
rm "$h/.git/check-publish-patterns"

k="$work/hist"; mkdir "$k"; git -C "$k" init -q
echo 'see NOTES.md' > "$k/a.txt"; git -C "$k" add a.txt
git -C "$k" -c user.name=X -c user.email=x@example.org commit -qm one
git -C "$k" rm -q a.txt; echo ok > "$k/b.txt"; git -C "$k" add b.txt
git -C "$k" -c user.name=X -c user.email=x@example.org commit -qm two
expect "$k" 1 "private content in an earlier commit flagged"

m="$work/msg"; mkdir "$m"; git -C "$m" init -q; echo ok > "$m/a.txt"; git -C "$m" add a.txt
git -C "$m" -c user.name=X -c user.email=x@example.org commit -qm $'one\n\nCo-Authored-By: Bot <b@example.org>'
expect "$m" 1 "Co-Authored-By in a commit message flagged"

n="$work/tag"; mkdir "$n"; git -C "$n" init -q; echo ok > "$n/a.txt"; git -C "$n" add a.txt
git -C "$n" -c user.name=X -c user.email=x@example.org commit -qm one
git -C "$n" -c user.name=X -c user.email=me@gmail.com tag -a v1 -m v1
expect "$n" 1 "private e-mail of an annotated tag's tagger flagged"

exit $fail
