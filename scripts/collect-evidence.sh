#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Collects the facts needed to compare hardware test reports and writes
# them to evidence-<date>-<time>.txt in the current directory.
#
#   scripts/collect-evidence.sh            facts only
#   scripts/collect-evidence.sh --record   also records 5 s from the default
#                                          input (2 s silence, then speech)
#   scripts/collect-evidence.sh --debug-on   log the driver's headset mic
#   scripts/collect-evidence.sh --debug-off  messages (needs sudo; off again
#                                            after a reboot)
#
# The driver's "headset mic present/absent" messages are debug messages:
# they are only logged while enabled with --debug-on, so enable them
# before the test steps and disable them with --debug-off afterwards.
#
# No personal data is collected on purpose: no serial numbers, machine
# IDs or network addresses are read. As a safety net, the free-text parts
# (kernel log, recording, modprobe options) have the user name, real name
# and host name replaced, and the whole report has home paths and MAC
# addresses replaced. Read the report before attaching it. Run it as your
# normal user (recording goes through your desktop audio session). It
# always exits 0 unless the command line is wrong, also on machines
# without the hardware or driver.
set -u
VERSION=1
record=0
for a in "$@"; do
	case "$a" in
	--record) record=1 ;;
	--debug-on|--debug-off)
		[ "$a" = --debug-on ] && flag=+p || flag=-p
		echo "running: echo 'module snd_hda_codec_cs420x $flag' | sudo tee /proc/dynamic_debug/control"
		echo "module snd_hda_codec_cs420x $flag" | sudo tee /proc/dynamic_debug/control >/dev/null ||
			{ echo "failed (is the module loaded?)" >&2; exit 1; }
		echo "driver debug messages: ${a#--debug-}"
		exit 0 ;;
	-h|--help) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown option: $a (see --help)" >&2; exit 2 ;;
	esac
done

# EVIDENCE_SYSROOT: read sysfs/procfs from another root (used by the tests)
R=${EVIDENCE_SYSROOT:-}
SYS=$R/sys
PROC=$R/proc
MOD=snd_hda_codec_cs420x

rd() { # <file> -> first line, or "unknown"
	local v
	v=$(head -n1 "$1" 2>/dev/null) && [ -n "$v" ] && echo "$v" || echo unknown
}
have() { command -v "$1" >/dev/null 2>&1; }

report() {
	echo "# macbookair6-cs4208 evidence report (format $VERSION)"
	echo "date: $(date -u -d "@$NOW" +%Y-%m-%dT%H:%MZ)"
	echo

	echo "[system]"
	echo "  product: $(rd "$SYS/class/dmi/id/product_name")"
	echo "  board_id: $(rd "$SYS/class/dmi/id/board_name")"
	echo "  vendor: $(rd "$SYS/class/dmi/id/sys_vendor")"
	echo "  firmware: $(rd "$SYS/class/dmi/id/bios_version")"
	echo "  kernel: $(uname -r)"
	echo "  arch: $(uname -m)"
	echo "  os: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
	if have mokutil; then
		echo "  secure_boot: $(mokutil --sb-state 2>&1 | head -n1)"
	else
		echo "  secure_boot: unknown (mokutil not installed)"
	fi
	echo

	echo "[codec]"
	local cfile="" card="" addr=""
	for f in "$PROC"/asound/card*/codec#*; do
		[ -f "$f" ] && grep -q 'CS4208' "$f" 2>/dev/null && { cfile=$f; break; }
	done
	if [ -z "$cfile" ]; then
		echo "  codec: not detected"
	else
		card=${cfile#"$PROC"/asound/card}; card=${card%%/*}
		addr=${cfile##*#}
		echo "  codec: $(sed -n 's/^Codec: //p' "$cfile")"
		echo "  card: $card"
		echo "  vendor_id: $(sed -n 's/^Vendor Id: //p' "$cfile")"
		echo "  subsystem_id: $(sed -n 's/^Subsystem Id: //p' "$cfile")"
		echo "  revision_id: $(sed -n 's/^Revision Id: //p' "$cfile")"
	fi
	echo

	echo "[module]"
	if [ -d "$SYS/module/$MOD" ]; then
		echo "  loaded: yes"
		echo "  loaded_srcversion: $(rd "$SYS/module/$MOD/srcversion")"
	else
		echo "  loaded: no"
	fi
	if have modinfo && p=$(modinfo -n snd-hda-codec-cs420x 2>/dev/null); then
		echo "  module: $p"
		echo "  file_srcversion: $(modinfo -F srcversion snd-hda-codec-cs420x 2>/dev/null)"
	else
		echo "  module: not found"
	fi
	if have dkms; then
		local d
		d=$(dkms status 2>/dev/null | grep -E 'macbookair6-cs4208|cs420x' | sed 's/^/    /')
		echo "  dkms:"; echo "${d:-    (no package installed)}"
	else
		echo "  dkms: not installed"
	fi
	echo

	echo "[jacks]"
	if [ -n "$card" ] && have amixer; then
		amixer -c "$card" controls 2>/dev/null | grep -E "name='[^']* Jack'" |
		while IFS= read -r c; do
			local id name val
			id=${c%%,*}
			name=$(sed -n "s/.*name='\([^']*\)'.*/\1/p" <<< "$c")
			val=$(amixer -c "$card" cget "$id" 2>/dev/null | sed -n 's/.*: values=//p')
			echo "  $name: ${val:-unknown}"
		done
		local src=""
		# enumerated control, not exposed as a "simple" mixer control: use cget
		local raw idx
		raw=$(amixer -c "$card" cget iface=MIXER,name='Capture Source' 2>/dev/null)
		idx=$(sed -n 's/^ *: values=\([0-9]*\).*/\1/p' <<< "$raw")
		[ -n "$idx" ] && src=$(sed -n "s/^ *; Item #$idx '\(.*\)'\$/\1/p" <<< "$raw")
		echo "  capture_source: ${src:-automatic (no Capture Source control: kernel auto-mic)}"
	else
		echo "  jacks: not available"
	fi
	echo

	echo "[power]"
	echo "  power_save: $(rd "$SYS/module/snd_hda_intel/parameters/power_save")"
	echo "  power_save_controller: $(rd "$SYS/module/snd_hda_intel/parameters/power_save_controller")"
	if [ -n "$card" ]; then
		local cd="$SYS/bus/hdaudio/devices/hdaudioC${card}D${addr}"
		echo "  codec_runtime_status: $(rd "$cd/power/runtime_status")"
		echo "  codec_power_on_ms: $(rd "$SYS/class/sound/card$card/hwC${card}D${addr}/power_on_acct")"
		echo "  codec_power_off_ms: $(rd "$SYS/class/sound/card$card/hwC${card}D${addr}/power_off_acct")"
		echo "  controller_runtime_status: $(rd "$SYS/class/sound/card$card/device/power/runtime_status")"
	fi
	local mp
	mp=$(grep -hs '^[[:space:]]*options[[:space:]]\+snd_hda_intel' /etc/modprobe.d/*.conf | sed 's/^/    /')
	echo "  modprobe_options:"; echo "${mp:-    (none)}"
	echo

	echo "[driver log]"
	local dd n_on n_all
	dd=$(grep "\[$MOD\]" "$PROC/dynamic_debug/control" 2>/dev/null)
	n_all=$(grep -c . <<< "$dd"); n_on=$(grep -c ' =[a-z]*p[a-z]* ' <<< "$dd")
	if [ -z "$dd" ]; then echo "  debug_messages: unknown (module not loaded or no dynamic debug)"
	elif [ "$n_on" -eq "$n_all" ]; then echo "  debug_messages: on"
	elif [ "$n_on" -eq 0 ]; then echo "  debug_messages: off (headset mic messages not logged; see --debug-on)"
	else echo "  debug_messages: partial ($n_on of $n_all)"; fi
	local log=""
	if log=$(dmesg 2>/dev/null) && [ -n "$log" ]; then :
	elif have journalctl && log=$(journalctl -q -k -b -o short-monotonic --no-pager 2>/dev/null |
		grep '^\[' | sed 's/^\(\[[ 0-9.]*\]\) [^ ]* kernel: /\1 /') && [ -n "$log" ]; then :
	else log=""; fi
	if [ -z "$log" ]; then
		echo "  kernel log: not readable (run 'sudo dmesg | grep -i headset' and paste the lines)"
	else
		local l
		l=$(grep -iE 'headset mic|hsmic|cs420x|CS4208' <<< "$log" | tail -n 60 | sed 's/^/  /')
		echo "${l:-  (no matching lines)}"
	fi
	echo

	echo "[recording]"
	if [ $record -eq 0 ]; then
		echo "  recording: not requested (use --record)"
	else
		do_record
	fi
	echo

	echo "[codec dump]"
	if [ -n "$cfile" ]; then sed 's/^/  /' "$cfile"; else echo "  not detected"; fi
}

do_record() {
	if ! have arecord || ! have python3; then
		echo "  recording: skipped (needs arecord and python3)"; return
	fi
	local raw
	raw=$(mktemp) || return
	{
		echo
		echo ">>> Recording 5 s from the default input."
		echo ">>> Stay SILENT for 2 seconds, then SPEAK until it stops."
		sleep 1
		echo ">>> Now (silence)..."
	} >&2
	( sleep 2; echo ">>> Speak now!" >&2 ) &
	if arecord -q -D default -f S16_LE -r 48000 -c 1 -d 5 -t raw "$raw" 2>/dev/null; then
		python3 -I - "$raw" <<'PY'
import sys, struct, math
data = open(sys.argv[1], 'rb').read()
n = len(data) // 2
s = struct.unpack('<%dh' % n, data[:2 * n])
rate = 48000
def rms(x):
    if not x: return 0.0
    m = sum(x) / len(x)
    return math.sqrt(sum((v - m) ** 2 for v in x) / len(x))
# Skip the first second: the mic path powers up with a pop when the codec
# leaves runtime suspend. Speech starts late (capture start-up latency
# plus reaction time after the prompt), so take the voice from 3 s on.
sil = s[int(1.0 * rate):int(2.0 * rate)]
voice = s[int(3.0 * rate):]
print("  samples: %d (S16_LE, 48 kHz, mono, default input)" % n)
print("  rms_silence: %.1f" % rms(sil))
print("  rms_voice: %.1f" % rms(voice))
print("  peak: %d" % max((abs(v) for v in s), default=0))
r = rms(voice) / max(rms(sil), 1e-9)
print("  voice_to_silence_ratio: %.1f" % r)
prof = [rms(s[i:i + rate // 2]) for i in range(0, n - rate // 2 + 1, rate // 2)]
print("  rms_profile_0.5s: " + " ".join("%.0f" % v for v in prof))
PY
	else
		echo "  recording: failed (arecord could not open the default input)"
	fi
	wait
	rm -f "$raw"
	if have wpctl; then
		local node
		node=$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/.*node.name = "\(.*\)"/\1/p' | head -n1)
		case "$node" in
		bluez_*) node="bluetooth device (name not shown)" ;;
		alsa_input.*) ;;
		*) node="other (${node%%.*})" ;;
		esac
		echo "  default_source: ${node:-unknown}"
		echo "  default_source_volume: $(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed 's/^Volume: //')"
		echo "  (all zeros usually means the input volume is 0 or muted)"
	fi
}

# Safety net, see the header. Names are replaced as whole words only, and
# only in free-text sections, so that e.g. a host called "macbook" cannot
# turn "MacBookAir6,1" into garbage.
redact() {
	local user host real
	user=${EVIDENCE_USER:-$(id -un 2>/dev/null)}
	host=${EVIDENCE_HOST:-$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)}
	real=${EVIDENCE_REALNAME-$(getent passwd "$user" 2>/dev/null | cut -d: -f5)}
	RU="$user" RH="$host" RR="${real%%,*}" RHM="${HOME:-}" awk '
	function word(s, w, to,   out, i, b, a, ls, lw) {
		if (length(w) < 3) return s
		out = ""; lw = tolower(w)
		while ((i = index(tolower(s), lw)) > 0) {
			b = (i > 1) ? substr(s, i - 1, 1) : ""
			a = substr(s, i + length(w), 1)
			if (b ~ /[A-Za-z0-9_]/ || a ~ /[A-Za-z0-9_]/) {
				out = out substr(s, 1, i + length(w) - 1)
			} else {
				out = out substr(s, 1, i - 1) to
			}
			s = substr(s, i + length(w))
		}
		return out s
	}
	function lit(s, w, to,   i) {
		if (length(w) < 2) return s
		while ((i = index(s, w)) > 0) s = substr(s, 1, i - 1) to substr(s, i + length(w))
		return s
	}
	BEGIN {
		n = 0
		if (ENVIRON["RH"] != "") { t[++n] = ENVIRON["RH"]; tt[n] = "<host>"
			sh = ENVIRON["RH"]; sub(/\..*/, "", sh)
			if (sh != ENVIRON["RH"]) { t[++n] = sh; tt[n] = "<host>" } }
		if (ENVIRON["RR"] != "") { t[++n] = ENVIRON["RR"]; tt[n] = "<name>"
			m = split(ENVIRON["RR"], p, /[ \t]+/)
			for (k = 1; k <= m; k++) { w = p[k]; gsub(/[^A-Za-z0-9_-]/, "", w)
				if (length(w) >= 3) { t[++n] = w; tt[n] = "<name>" } } }
		if (ENVIRON["RU"] != "") { t[++n] = ENVIRON["RU"]; tt[n] = "<user>" }
		free = "^(driver log|recording|power)$"
	}
	/^\[[a-z ]+\]$/ { sec = substr($0, 2, length($0) - 2) }
	{
		$0 = lit($0, ENVIRON["RHM"], "<home>")
		gsub(/\/home\/[^\/ ]+/, "<home>")
		gsub(/([0-9A-Fa-f][0-9A-Fa-f][:-]){5}[0-9A-Fa-f][0-9A-Fa-f]/, "<mac>")
		if (sec ~ free)
			for (k = 1; k <= n; k++) $0 = word($0, t[k], tt[k])
		print
	}'
}

if [ -n "${EVIDENCE_REDACT_ONLY:-}" ]; then redact; exit 0; fi

NOW=$(date -u +%s)
out="evidence-$(date -u -d "@$NOW" +%Y%m%d-%H%M%SZ).txt"
report | redact > "$out"
echo "Report written to $out — please read it before attaching it to an issue."
exit 0
