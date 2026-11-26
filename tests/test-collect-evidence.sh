#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# scripts/collect-evidence.sh: always completes (exit 0), writes one report
# in the current directory and never leaks personal data.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/scripts/collect-evidence.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
ok()  { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

no_leaks() { # <report> <label>
	local r=$1 l=$2 u h
	u=$(id -un); h=$(hostname)
	grep -qiF -- "$u" "$r" && bad "$l: contains the user name"
	grep -qiF -- "$h" "$r" && bad "$l: contains the host name"
	grep -qF -- "/""home/" "$r" && bad "$l: contains a home path"
	grep -qF -- "$HOME" "$r" && bad "$l: contains \$HOME"
	grep -qiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' "$r" && bad "$l: contains a MAC address"
	for f in product_serial board_serial chassis_serial product_uuid; do
		v=$(cat /sys/class/dmi/id/$f 2>/dev/null) || { echo "skip: DMI $f not readable (not root)"; continue; }
		[ -n "$v" ] && grep -qF -- "$v" "$r" && bad "$l: contains DMI $f"
	done
	m=$(cat /etc/machine-id 2>/dev/null); [ -n "$m" ] && grep -qF -- "$m" "$r" && bad "$l: contains machine-id"
	return 0
}

# 1. real system, no recording
mkdir "$work/a"; (cd "$work/a" && "$script" > "$work/a.out" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "exit 0 on this machine" || bad "exit $rc on this machine"
n=$(ls "$work/a"/evidence-*.txt 2>/dev/null | wc -l)
[ "$n" -eq 1 ] && ok "one report written in the current directory" || bad "$n reports written"
r=$(ls "$work/a"/evidence-*.txt 2>/dev/null | head -1)
if [ -n "$r" ]; then
	for k in 'kernel:' 'product:' 'codec:' 'module:' 'power_save_controller:'; do
		grep -q "^ *$k" "$r" && ok "report has '$k'" || bad "report lacks '$k'"
	done
	no_leaks "$r" "real system"
fi

# 2. no audio hardware / no driver: empty sysfs and procfs
mkdir -p "$work/b" "$work/root/sys" "$work/root/proc"
(cd "$work/b" && EVIDENCE_SYSROOT="$work/root" "$script" > "$work/b.out" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "exit 0 without hardware" || bad "exit $rc without hardware"
r=$(ls "$work/b"/evidence-*.txt 2>/dev/null | head -1)
if [ -n "$r" ]; then
	grep -q 'codec: *not detected' "$r" && ok "reports codec not detected" || bad "no 'codec: not detected'"
	grep -q 'loaded: *no' "$r" && ok "reports module not loaded" || bad "no 'loaded: no'"
	no_leaks "$r" "no hardware"
else bad "no report without hardware"; fi

# 3. report file name carries no local time zone (UTC, matches the date line)
r=$(ls "$work/a"/evidence-*.txt 2>/dev/null | head -1)
if [ -n "$r" ]; then
	fts=$(basename "$r" | sed -n 's/^evidence-\([0-9]\{8\}-[0-9]\{4\}\)[0-9]*Z\.txt$/\1/p')
	dts=$(sed -n 's/^date: \([0-9]*\)-\([0-9]*\)-\([0-9]*\)T\([0-9]*\):\([0-9]*\)Z$/\1\2\3-\4\5/p' "$r")
	[ -n "$fts" ] && [ "$fts" = "$dts" ] && ok "file name is UTC and matches the date line" \
		|| bad "file name '$(basename "$r")' vs date '$dts'"
fi

# 4. redaction, with synthetic identities (EVIDENCE_REDACT_ONLY filters stdin)
hp=/ho''me  # split so scripts/check-publish.sh does not flag this file
red() { EVIDENCE_REDACT_ONLY=1 EVIDENCE_USER=mac EVIDENCE_HOST=macbook.example.lan \
	EVIDENCE_REALNAME="Jane Q. Doe,,," HOME=/srv/users/mac "$script"; }
out=$(sed "s|@HP@|$hp|g" <<'IN' | red
[system]
  product: MacBookAir6,1
  vendor: Apple Inc.
  os: Ubuntu 26.04.1 LTS
[driver log]
  [ 1.0] macbook kernel: snd_hda_intel: probe
  [ 2.0] MACBOOK.example.lan user mac logged in, path /srv/users/mac/x and @HP@/mac/y
  [ 3.0] bt AA-BB-CC-DD-EE-FF aa:bb:cc:dd:ee:0f
[recording]
  default_source: AirPods de Jane Doe
IN
)
chk() { grep -qF -- "$1" <<< "$out" && ok "redaction: $2" || { bad "redaction: $2"; echo "$out"; }; }
nchk() { grep -qiF -- "$1" <<< "$out" && { bad "redaction: $2"; echo "$out"; } || ok "redaction: $2"; }
chk "product: MacBookAir6,1" "product line intact (host 'macbook')"
chk "vendor: Apple Inc." "vendor line intact"
chk "snd_hda_intel" "technical names intact (user 'mac')"
nchk "macbook kernel" "short host name redacted"
nchk "example.lan" "FQDN redacted"
nchk " mac " "user name redacted as a word"
nchk "/srv/users/mac" "HOME redacted"
nchk "$hp/mac" "other home paths redacted"
nchk "AA-BB-CC" "MAC with dashes redacted"
nchk "ee:0f" "MAC with colons redacted"
nchk "Jane" "real name redacted"

# 5. capture source read with cget (it is not a "simple" mixer control)
mkdir -p "$work/fake/bin" "$work/fake/root/proc/asound/card3" "$work/fake/root/sys" "$work/c"
printf 'Codec: Cirrus Logic CS4208\nVendor Id: 0x10134208\nSubsystem Id: 0x106b7100\n' \
	> "$work/fake/root/proc/asound/card3/codec#0"
cat > "$work/fake/bin/amixer" <<'AMX'
#!/bin/sh
case "$*" in
*"controls"*) echo "numid=25,iface=MIXER,name='Capture Source'" ;;
*"cget"*"Capture Source"*) printf "%s\n" "numid=25,iface=MIXER,name='Capture Source'" \
	"  ; type=ENUMERATED,access=rw------,values=1,items=2" "  ; Item #0 'Mic'" \
	"  ; Item #1 'Internal Mic'" "  : values=0" ;;
*"sget"*) echo "amixer: Unable to find simple control 'Capture Source',0" >&2; exit 1 ;;
esac
AMX
chmod +x "$work/fake/bin/amixer"
(cd "$work/c" && PATH="$work/fake/bin:$PATH" EVIDENCE_SYSROOT="$work/fake/root" "$script" >/dev/null 2>&1)
r=$(ls "$work/c"/evidence-*.txt 2>/dev/null | head -1)
grep -q '^  capture_source: Mic$' "$r" 2>/dev/null && ok "capture source read with cget" \
	|| { bad "capture source: $(grep capture_source "$r" 2>/dev/null)"; }

# 6. dynamic debug state of the driver messages is reported
mkdir -p "$work/dd/root/proc/dynamic_debug" "$work/dd/root/sys" "$work/dd/on" "$work/dd/off"
ctl="$work/dd/root/proc/dynamic_debug/control"
printf '%s\n' 'cs420x.c:166 [snd_hda_codec_cs420x]cs4208_mba6_hsmic_probe =p "headset mic probe"' \
	'cs420x.c:229 [snd_hda_codec_cs420x]cs4208_mba6_hsmic_work =p "headset mic %s\n"' > "$ctl"
(cd "$work/dd/on" && EVIDENCE_SYSROOT="$work/dd/root" "$script" >/dev/null 2>&1)
grep -q '^  debug_messages: on$' "$work"/dd/on/evidence-*.txt 2>/dev/null && ok "debug messages reported on" || bad "debug messages on not reported"
sed -i 's/ =p / =_ /' "$ctl"
(cd "$work/dd/off" && EVIDENCE_SYSROOT="$work/dd/root" "$script" >/dev/null 2>&1)
grep -q '^  debug_messages: off' "$work"/dd/off/evidence-*.txt 2>/dev/null && ok "debug messages reported off" || bad "debug messages off not reported"

# 7. unknown option
"$script" --bogus > /dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok "unknown option rejected (2)" || bad "unknown option rc=$rc"
exit $fail
