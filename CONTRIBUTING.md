# Contributing

Thanks for helping. This repository is meant to become a Linux kernel
patch series, so it follows the kernel's development process.

## Ways to help

- **Test on your hardware** and open a hardware test report (see
  [docs/testing.md](docs/testing.md)). MacBookAir6,2 reports are needed.
- **Pick an issue labelled `help wanted`**: other kernel versions, other
  CS4208 Macs, headset buttons.
- **Review pull requests**: kernel-style review comments are welcome.

## Pull requests

- **One logical change per pull request**, one commit each. Every commit
  should make sense as a kernel patch on its own.
- **Kernel commit style.** Subject `ALSA: hda/cirrus: cs420x: <imperative
  summary>`; the body explains the problem, the cause, the fix and how it
  was tested, wrapped at 72 columns. See the kernel's
  `Documentation/process/submitting-patches.rst`.
- **checkpatch:** run `scripts/checkpatch.pl --strict` from a kernel tree
  on the output of `git format-patch -1`: no errors or warnings.
- **Build:** `make -C packaging` must build for your kernel without
  warnings.
- **Hardware evidence:** driver changes need a test on a MacBookAir6,x;
  attach the output of `scripts/collect-evidence.sh` to the pull request.
- **Signed commits:** `main` only accepts commits with a verified GitHub
  signature (GPG, SSH or S/MIME). Pull requests are merged by
  fast-forward, so your signed commit lands unchanged.
- Before pushing, run `scripts/check-publish.sh` and the scripts in
  `tests/`.

## Developer Certificate of Origin

Add `Signed-off-by: Your Name <email>` to each commit (`git commit -s`),
certifying the [Developer Certificate of Origin](https://developercertificate.org/)
as described in `submitting-patches.rst`. Use a name and e-mail address
you are willing to have in the kernel history.

Authorship carries over to the upstream submission: whoever submits the
series to the kernel keeps you as the author (`From:`) and appends their
own `Signed-off-by:`. If several people wrote a change, each co-author
adds `Co-developed-by:` followed by their own `Signed-off-by:`.

## AI-assisted contributions

AI assistance is welcome but must be disclosed, following the kernel's
`Documentation/process/coding-assistants.rst` and `generated-content.rst`:

- add `Assisted-by: AGENT_NAME:MODEL_VERSION [TOOLS]` to the commit;
- say in the pull request what the tool did;
- an AI tool must never add `Signed-off-by`: only you can certify the
  DCO, and you must understand and be able to defend every line.

## Adding a kernel

The module includes internal ALSA HDA headers, which must match the
target kernel exactly. To add a kernel:

1. Get the kernel's source (for a distribution kernel, its source
   package or git tag) and compare `sound/hda/codecs/cirrus/cs420x.c`,
   `sound/hda/codecs/generic.h` and `sound/hda/common/{hda_local.h,
   hda_jack.h,hda_auto_parser.h}` with `src/` at the import commit.
2. Reuse a header set in `packaging/headers/` that matches, or add one
   containing only the headers that differ from `src/`.
3. Map the kernel release in `packaging/select-headers.sh` and add it to
   `tests/test-select-headers.sh`.
4. On that kernel, run `tests/test-stock-equivalence.sh`: the unmodified
   import must build to the same machine code as the stock module.
5. Test the fix on the hardware, then add the kernel to
   `BUILD_EXCLUSIVE_KERNEL` in `dkms.conf` and to the README.

Kernels before 6.17 keep this driver in `sound/pci/hda/patch_cirrus.c`
and need a separate port (see the issue).

## Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
