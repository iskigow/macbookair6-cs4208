#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Refuses to publish private data or Apple files. Run before every push:
#   scripts/check-publish.sh [path]      (default: current directory)
# Exit 0 when clean, 1 with a list of hits, 2 on error (never "clean" on error).
#
# Checked: file names and contents (binary files and symlink targets too).
# In a git work tree: the files git would publish (tracked or not ignored),
# every commit reachable from any ref (contents, file names, authors,
# committers, messages) and annotated tags.
#
# Extra private patterns (names, e-mail addresses, host names) go in the
# untracked file .git/check-publish-patterns, one extended regex per line,
# so they are never published themselves.
set -u
root=${1:-.}
cd "$root" || exit 2

pattern='/home/|gmail|proton\.me|superpowers|AppleHDA\.kext|\.kc\b|layout[0-9]+\.xml|Platforms\.xml|NOTES\.md|co-authored-by|claude-session|claude\.ai/code'
names='\.kext(/|$)|\.kc$|\.zlib$|(^|/)AppleHDA$'
self='^(\./)?(scripts/check-publish\.sh|tests/test-check-publish\.sh)$'
hits=0
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

# grep wrapper: prints matches with a label, sets hits; exit 2 on grep errors
check() { # <label> <grep args...>   (input on stdin or files in args)
	local label=$1 out rc
	shift
	out=$(grep "$@"); rc=$?
	if [ $rc -gt 1 ]; then echo "check-publish: grep failed ($label)" >&2; exit 2; fi
	if [ $rc -eq 0 ]; then printf '%s\n' "$out" | sed "s|^|$label: |"; hits=1; fi
	return 0
}

in_git=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then in_git=1; fi

# local private patterns: validated, blank lines dropped
: > "$tmp/local"
if [ $in_git -eq 1 ]; then
	local_pat="$(git rev-parse --git-dir)/check-publish-patterns"
	if [ -f "$local_pat" ]; then
		while IFS= read -r l; do
			[ -n "${l//[[:space:]]/}" ] || continue
			grep -qE -e "$l" </dev/null; [ $? -le 1 ] ||
				{ echo "check-publish: invalid pattern in $local_pat: $l" >&2; exit 2; }
			printf '%s\n' "$l" >> "$tmp/local"
		done < "$local_pat"
	fi
fi
printf '%s\n' "$pattern" > "$tmp/all"
cat "$tmp/local" >> "$tmp/all"

# files to check
if [ $in_git -eq 1 ]; then
	git ls-files -z --cached --others --exclude-standard > "$tmp/files" || exit 2
else
	find . -path ./.git -prune -o ! -type d -print0 > "$tmp/files" || exit 2
fi

while IFS= read -r -d '' f; do
	[[ $f =~ $self ]] && continue
	check "name" -iE -e "$names" -f "$tmp/all" <<< "$f"
	if [ -L "$f" ]; then
		check "link $f" -iE -f "$tmp/all" <<< "$(readlink "$f")"
	elif [ -f "$f" ]; then
		check "$f" -naiE -f "$tmp/all" -- "$f"
	fi
done < "$tmp/files"

if [ $in_git -eq 1 ] && git rev-parse -q --verify HEAD >/dev/null; then
	mapfile -t revs < <(git rev-list --all) || exit 2
	# contents of every reachable commit (the tool's own files excluded)
	out=$(git grep -naiE -f "$tmp/all" "${revs[@]}" -- . \
		':!scripts/check-publish.sh' ':!tests/test-check-publish.sh'); rc=$?
	[ $rc -gt 1 ] && { echo "check-publish: git grep failed" >&2; exit 2; }
	[ $rc -eq 0 ] && { printf 'history: %s\n' "$out" | head -50; hits=1; }
	check "history name" -iE -e "$names" -f "$tmp/all" < <(git log --all --name-only --format= | sort -u)
	check "git identity" -iE -f "$tmp/all" < <(git log --all --format='%an <%ae>%n%cn <%ce>' | sort -u)
	check "git message" -iE -f "$tmp/all" < <(git log --all --format='%h %B')
	check "tag" -iE -f "$tmp/all" < <(git for-each-ref refs/tags \
		--format='%(refname:short) %(taggername) %(taggeremail)%0a%(contents)')
fi

[ $hits -eq 0 ] && echo "check-publish: clean" || echo "check-publish: FAILED" >&2
exit $hits
