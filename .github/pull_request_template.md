<!-- One logical change per pull request; it should make sense as one kernel patch. -->

## What and why

<!-- Problem, cause, fix. The commit message should say the same, in kernel style. -->

## Testing

<!-- Machine, kernel, what you did and what you saw. Attach evidence-*.txt. -->

## Checklist

- [ ] Commit message in kernel style (`ALSA: hda/cirrus: cs420x: ...`), wrapped at 72 columns
- [ ] `scripts/checkpatch.pl --strict` (from a kernel tree) on `git format-patch -1`: no errors or warnings
- [ ] `make -C packaging` builds without warnings; scripts in `tests/` pass
- [ ] Tested on a MacBookAir6,x; `scripts/collect-evidence.sh` output attached
- [ ] AI use disclosed (`Assisted-by:` tag and a note here), or no AI used
- [ ] `Signed-off-by:` added by me (DCO); commit signed (GPG/SSH)
- [ ] `scripts/check-publish.sh` passes
