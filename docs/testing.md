# Test protocol

Use this protocol to check the fix on your machine and to produce a
report that can be compared with others. It takes about 15 minutes.

You need: a 4-pole (CTIA) headset with mic, ideally also 3-pole
headphones (no mic), and the module installed (see the README).

Run all commands as your normal user, from the repository directory.
Commands needing root ask for `sudo`.

## 0. Before you start

```sh
scripts/collect-evidence.sh
```

Check the report it writes (`evidence-<date>-<time>Z.txt`), section
`[module]`:

- `module:` is under `updates/dkms`;
- `loaded: yes`, and `loaded_srcversion` equals `file_srcversion`;
- the `dkms:` line shows `macbookair6-cs4208/<version>` as installed.

If it says `loaded: no`, shows a path under `kernel/`, or the two
srcversions differ, the stock driver is still running: check
`dkms status` and reboot.

## 1. Headset mic records voice

1. Plug the 4-pole headset.
2. Wait 2 seconds. In GNOME Settings → Sound, the input should switch to
   the headset microphone ("Microphone" / "Mic").
3. Run:

   ```sh
   scripts/collect-evidence.sh --record
   ```

   The script records 5 seconds from the default input. Stay silent for
   the first 2 seconds, then speak until it stops. The report shows the
   RMS level of the silent part and of the voice part; voice should be
   clearly higher (typically 20× or more).

## 2. 3-pole headphones

Unplug the headset and plug 3-pole headphones. Playback stays on the
headphones and the input switches back to the internal mic.

## 3. Unplug

Unplug everything. Playback moves to the speakers and the input stays
on the internal mic. Play a sound to check the speakers.

## 4. Idle and resume

1. Plug the headset and leave the machine idle for 30 seconds (no
   sound playing).
2. Play a short sound (for example press Backspace in an empty terminal).
3. Expected: the sound plays in the headset, GNOME shows no output or
   input change, and the input stays on the headset mic.

## 5. Plug while idle

This step depends on the optional setting that keeps the HDA controller
awake (README, "Optional: keep the HDA controller awake"). The evidence
report shows it as `power_save_controller: N`.

1. Unplug everything and leave the machine idle for 30 seconds.
2. Plug the headset, then play a sound.
3. Expected with the setting: the sound starts in the headset. Without
   it, the sound starts on the speakers and moves to the headset a
   moment later; that is a known limitation, report which one you saw.

## 6. Reboot with the headset plugged

Reboot with the headset plugged. After login, the input should be the
headset mic and output the headset, without switching back and forth.

## 7. Report

Run the script once more with everything still plugged:

```sh
scripts/collect-evidence.sh --record
```

Open a *Hardware test report* issue, attach the `evidence-*.txt` files
and fill in the result of each step above. Read the files first: they
should contain no personal data, and you can edit anything you do not
want to share.
