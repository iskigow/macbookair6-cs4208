# AI assistance disclosure

This repository follows the kernel's guidance on tool-generated content
(`Documentation/process/generated-content.rst`) and on AI coding
assistants (`Documentation/process/coding-assistants.rst`).

## Tool

- Claude Code (Anthropic's command-line coding assistant), model
  Claude Opus 5.5 (`claude-opus-5-5`).
- Commit trailer: `Assisted-by: Claude:claude-opus-5-5`.

## What the assistant did

The work was done in interactive sessions in which the maintainer set
the goals, made the decisions and ran every hardware test (plugging
headsets, listening to recordings, rebooting). Within those sessions the
assistant:

- **Reverse engineering:** listed and disassembled the relevant functions
  of the macOS 11.6 AppleHDA driver and decoded the layout data for this
  machine, to find the GPIO, coefficient and timing values described in
  [findings.md](findings.md). Only behaviour was carried over; no Apple
  code was copied.
- **Experiments:** proposed and ran codec experiments through ALSA and
  `hda-verb` (GPIO, coefficients, pin configuration), recorded test
  captures and computed RMS levels and spectra.
- **Driver code:** wrote the driver changes in `src/` (each commit says
  so) and their commit messages.
- **Packaging, scripts and tests:** wrote the DKMS packaging, the header
  selection, `scripts/` and `tests/`.
- **Documentation:** drafted this documentation in English from the
  maintainer's decisions (the maintainer works in Brazilian Portuguese).

## How it was checked

- Every driver change was built, loaded and tested on the maintainer's
  MacBookAir6,1 before merge; the evidence is attached to the
  corresponding pull request.
- The unmodified import is verified to build to the same machine code as
  the distribution's module (`tests/test-stock-equivalence.sh`).
- `scripts/checkpatch.pl --strict` from the kernel tree is run on each
  patch.
- The maintainer reviews each change, signs the commit and adds the
  `Signed-off-by:` line. The assistant never adds `Signed-off-by:`.

## Responsibility

The maintainer has reviewed, understands and takes responsibility for
every change in this repository, as required by the Developer
Certificate of Origin.

Contributors using AI tools: see
[CONTRIBUTING.md](../CONTRIBUTING.md#ai-assisted-contributions).
