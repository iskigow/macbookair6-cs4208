# macbookair6-cs4208

Linux support work for the Cirrus Logic CS4208 audio codec in the
MacBookAir6,1 / MacBookAir6,2 (Mid 2013 and Early 2014), starting with the **headset
microphone on the combo jack**, which has never worked on Linux
([Launchpad bug 1410618](https://bugs.launchpad.net/ubuntu/+source/alsa-driver/+bug/1410618)).

**Purpose:** mature this fix in public before proposing it to the Linux
kernel. Owners of these machines install it, test it, report results with
evidence and help improve it. When it is ready, the history of this
repository becomes the patch series sent to the ALSA maintainers.

## Status

Experimental. The fix works on the maintainer's MacBookAir6,1 and is
being merged here as a series of reviewed pull requests, one per future
kernel patch. Tag `v0.1.0` is the first installable release.

With the fix:

- the headset mic of a 4-pole (CTIA) headset works;
- plugging a headset selects its mic; plugging 3-pole headphones or
  unplugging switches back to the internal mic;
- jack state stays stable across codec suspend/resume.

Headset buttons (play/pause, volume) do not work yet (see the issues).

## Tested

| Machine | Kernel | Arch | Result |
|---|---|---|---|
| MacBookAir6,1 (board Mac-35C1E88140C3E6CF) | Ubuntu 7.0.0-43-generic, 7.0.0-44-generic | x86_64 | works |
| MacBookAir6,2 | — | — | untested, help wanted |

The code is architecture-independent and only changes behaviour on codecs
with subsystem ID 106b:7100 or 106b:7200 (MacBookAir6,x); every other
machine using this driver keeps the stock behaviour.

### Supported kernels

The module is built against internal ALSA HDA headers that are not a
stable kernel API, and they differ between distributions (Ubuntu's 7.0
kernels change the layout of a structure this driver allocates). So that
nobody ends up with corrupted memory or silent audio, DKMS only builds the
module for kernels that were verified to match:

- Ubuntu `7.0.0-43-generic`, `7.0.0-44-generic`.

On any other kernel DKMS skips the build and the stock driver keeps
working (without the headset mic). A header set for mainline 7.0.x is
included but not yet verified. Support for other kernels is tracked in
the issues; see [CONTRIBUTING.md](CONTRIBUTING.md#adding-a-kernel) to
help.

## Install

Requirements: `dkms`, `git` and the headers of your running kernel
(`linux-headers-$(uname -r)` on Ubuntu).

With Secure Boot enabled (`mokutil --sb-state`), the module is signed
with the DKMS key, which must be enrolled or the module will not load.
On Ubuntu, check with
`mokutil --test-key /var/lib/shim-signed/mok/MOK.der`; if it is not
enrolled, run `sudo update-secureboot-policy --enroll-key`, reboot and
complete the enrollment in the blue MokManager screen.

```sh
git clone https://github.com/iskigow/macbookair6-cs4208.git
cd macbookair6-cs4208
git archive --prefix=macbookair6-cs4208-0.1.0/ v0.1.0 | sudo tar -x -C /usr/src
sudo dkms install macbookair6-cs4208/0.1.0
sudo reboot
```

DKMS keeps a copy of the original module and rebuilds this one when a
supported kernel is installed.

### Optional: keep the HDA controller awake

By default Linux runtime-suspends the whole HDA controller when audio is
idle, and plug events are lost while it sleeps: if you plug a headset
into an idle machine, the next sound starts on the speakers and then
moves to the headset. Keeping the controller awake fixes this; the codec
itself still powers down when idle (measured: off 28.3 s out of 30 s).
The cost is a slightly higher idle power use of the controller (not
measured), and the setting also applies to the HDMI audio controller.

```sh
sudo install -m 644 modprobe.d/macbookair-audio.conf /etc/modprobe.d/
sudo reboot
```

Details in [docs/findings.md](docs/findings.md#5-keep-the-hda-controller-awake).

## Uninstall

```sh
sudo dkms remove macbookair6-cs4208/0.1.0 --all
sudo rm -r /usr/src/macbookair6-cs4208-0.1.0
sudo rm -f /etc/modprobe.d/macbookair-audio.conf   # if you installed it
sudo reboot
```

`dkms remove` restores the original module.

## Test and report

Follow [docs/testing.md](docs/testing.md), then open a *Hardware test
report* issue with the file produced by `scripts/collect-evidence.sh`.
The script collects no personal data (no user or host names, serial
numbers or network addresses). Reports from MacBookAir6,2 owners are
especially welcome, as are reports of things that do not work.

## How it works

[docs/findings.md](docs/findings.md) explains the hardware, what the
macOS driver does, what was missing on Linux and why each part of the
fix is there.

## Reverse engineering statement

The required codec settings were found by studying how the macOS 11.6
AppleHDA driver behaves on this machine (its symbols, disassembly and
layout data), for interoperability, and by experiment on the hardware.
Only behaviour is described here. This repository contains no Apple code
and no Apple files.

## AI assistance

This work was done with the help of an AI coding assistant (Claude Code,
model Claude Opus 5.5): reverse engineering, driver code, tests and
documentation. Every change is reviewed and tested on real hardware by
the maintainer, who signs off on it and is responsible for it. Each
commit message ends with a line stating the assistance, and pull
requests say what the tool did, following the kernel's
`Documentation/process/generated-content.rst` and
`coding-assistants.rst`. Details:
[docs/ai-disclosure.md](docs/ai-disclosure.md).

## Repository layout

```
src/        kernel files at their upstream paths (pristine v7.0 + fixes)
packaging/  out-of-tree build and per-kernel internal-header sets
dkms.conf   DKMS package definition
modprobe.d/ optional setting that keeps the HDA controller awake
scripts/    collect-evidence.sh (test reports), check-publish.sh
tests/      tests for the packaging and scripts
docs/       findings, testing protocol, AI disclosure
```

## License

GPL-2.0 ([LICENSE](LICENSE)). Files imported from the kernel keep their
SPDX headers; files written for this repository are GPL-2.0-only.

Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md) and
the [code of conduct](CODE_OF_CONDUCT.md).
