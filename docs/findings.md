# Findings: the MacBookAir6,x headset mic

This document explains why the headset mic did not work on Linux and
what each part of the fix does. The measurements come from a
MacBookAir6,1 (board Mac-35C1E88140C3E6CF, codec CS4208 `0x10134208`,
subsystem ID `106b:7100`; the MacBookAir6,2 uses `106b:7200` and the
same fixup in the kernel) running Ubuntu with kernel 7.0.

## The layers involved

```
 headset plug ──► combo jack (4-pole CTIA)
                    │  mic contact goes through an analog switch
                    │  ("USCH DFET") controlled by codec GPIO4
                    ▼
 CS4208 codec ───── pin 0x10 headphone out    pin 0x12 speaker out
  (HDA)             pin 0x18 headset mic ─► ADC 0x07
                    pin 0x1c internal mic ─► ADC 0x09
                    vendor widget 0x24 (processing coefficients)
                    GPIO0 speaker amp, GPIO4 headset mic switch
                    │  verbs / unsolicited events over the HDA link
                    ▼
 Linux kernel ───── snd-hda-intel (HDA controller, PCI 00:1b.0)
                    snd-hda-codec-cs420x + generic parser
                    jack table → "Headphone Jack", "Mic Jack" controls
                    │  ALSA controls and jack events
                    ▼
 PipeWire / WirePlumber ─ ALSA card profile: ports become
                    available/unavailable from the jack controls
                    and the default source follows them
                    │
                    ▼
 GNOME ───────────── Settings / volume OSD show the active ports
```

A working headset mic needs every layer: the switch must route the mic
contact to the codec, the codec must bias and sample pin 0x18, the kernel
must expose the pin and report whether a mic is plugged, and PipeWire
must see that report to switch the default input.

## What was wrong on Linux

- The kernel's MacBookAir6,x fixup marks pin 0x18 as not connected, so
  only the internal mic (pin 0x1c) is exposed.
- Even with pin 0x18 enabled by hand, it only recorded the ADC noise
  floor (RMS about 11 on 16-bit samples, flat with any bias voltage):
  the mic contact was not connected to the codec.
- The codec's GPIO data had only GPIO0 (speaker amplifier) set; GPIO4 was
  off.

## What the macOS driver does

The macOS 11.6 AppleHDA driver was studied (symbols, disassembly and the
layout data for this machine, layout 113) to find out how it configures
the codec. Relevant behaviour:

- The layout data names a headset switch control, `USCHDFETControl`,
  with `DfetGPIO = 4`: GPIO4 drives the switch that connects the mic
  contact of the combo jack.
- When a US (CTIA) headset is configured, vendor coefficient `0x1a` of
  widget 0x24 is set to `0xa6`.
- A mic presence probe on vendor widget 0x24 (see below) decides whether
  the plugged accessory has a mic.
- Timings: the audio function group waits 150 ms after power-up
  (`audioFunctionGroupStartupDelay`), mic detection runs 500 ms after a
  plug (`MikeyDetectDelay`), and the presence probe waits 20 ms for the
  comparator to settle.
- The codec idles 10 s after the last use (`IdleTimeout` 10000 ms).

## The fix, part by part

### 1. Enable the headset mic path

- **GPIO4 always on, coefficient 0x1a = 0xa6.** With both set, the mic
  picked up music playing in the room: RMS about 65, against about 11
  (the ADC noise floor) with the Linux defaults or with the coefficients
  but GPIO4 off (16-bit samples, after a 150 Hz high-pass). That capture
  also set the other macOS coefficients (0x19, 0x1c) and the ADC
  amplifier by hand; later tests showed that GPIO4 and coefficient 0x1a
  are the minimum, and dropping either one makes the mic silent again. A
  voice test with the first patched driver (mic boost 2) measured
  600–1300 for speech against about 25 for silence.
- **GPIO4 has to stay high in every jack state**, so it is merged into
  the GPIO data at init and in the automute hook, which otherwise
  rewrites the GPIO data with only the speaker bit.
- **Coefficient 0x1a = 0xa6** is written at init, so it is restored on
  resume. Other coefficients the macOS driver touches (0x19, 0x1c) made
  no difference on their own.
- **Shared ADC input amp.** The ADC input amplifier of the CS4208 is
  shared by all connection indices: the generic parser keeps the unused
  inputs of ADC 0x07 muted, and whichever index is written last wins, so
  the headset mic recorded digital silence. Setting
  `codec->single_adc_amp` for this machine fixes it.
- **Pin 0x18** is exposed as an external mic.

### 2. Detect the headset mic and switch automatically

Pin 0x18 never reports presence by itself. The macOS driver asks a
comparator behind vendor widget 0x24 instead:

1. enable the comparator: set coefficient 0x1d field `0x3e` to `0x34`,
   clear bit 7 of the vendor state of widget 0x24 (read with verb
   `0xff1`, written back with verb `0x7f1`) and set bit 13 of
   coefficient 0x1c;
2. wait 20 ms;
3. read coefficient 0x1f ("on" value), turn the comparator off (clear
   field `0x3e` of coefficient 0x1d) and read coefficient 0x1f again
   ("off" value);
4. restore coefficient 0x1c, the vendor state and coefficient 0x1d.

A mic is present when bit 8 of coefficient 0x1f is set with the
comparator on and clear with it off; 3-pole headphones keep the bit set
in both states. Measured (on / off): headset with mic `0x4100` /
`0x8000`, 3-pole headphones `0x4100` / `0x0100`, nothing plugged
`0xc400` / `0x0400`.

The result is written into the kernel's jack table for pin 0x18, so the
"Mic Jack" control and the kernel's auto-mic switching work as for any
other codec. The probe runs from a callback on the headphone jack (pin
0x10), 500 ms after a plug (macOS `MikeyDetectDelay`), because PipeWire
turns off the generic parser's auto-mute mode and its automute hook then
never runs.

### 3. Debounce the mic state

Right after a codec runtime resume, the headphone pin sense reads
"unplugged" for about 45–110 ms (the stock driver does the same). Acting
on that removed the headset mic and brought it back half a second later,
so GNOME saw the input appear and disappear on every resume. The fix
schedules the probe with `mod_delayed_work()` (300 ms when the
headphone reads unplugged, 500 ms when plugged), re-reads the settled
headphone state in the work and reports the mic only when its state
actually changed. Measured: 3 resume cycles → 0 "Mic Jack" events
(before: 2 per resume). The 300 ms value is empirical; 500 ms follows
macOS.

### 4. Keep the headphone state across resume

The same brief false "unplugged" also flipped the "Headphone Jack"
control, so PipeWire moved playback to the speaker for about 100 ms and
GNOME showed a volume OSD. The fix keeps the last stable headphone state
in the jack table during init and verifies the real pin state 200 ms
later (above the 150 ms macOS waits after powering the function group);
only a real change (plug or unplug while suspended) is reported.
Measured: 3 resume cycles → 0 headphone, mic or speaker events.

Later measurement showed where the false reading comes from: with the
HDA controller kept awake (see 5) the stock driver showed 0 headphone
flaps in 4 resume cycles, against flaps of 44–110 ms when the controller
suspended too. The glitch comes from the controller/link reset on runtime
suspend, not from the codec's D3 state. The 200 ms verification stays as
a safety net for systems that let the controller suspend.

### 5. Keep the HDA controller awake

With the default `power_save` the kernel runtime-suspends the whole HDA
controller (PCI 00:1b.0) together with the codec. While it is suspended
the codec's unsolicited plug event is not received; the plug is only
seen when playback wakes everything, after PipeWire has already started
on the old route (sound begins on the speaker, then moves to the
headset).

Setting `options snd_hda_intel power_save_controller=N` keeps the
controller active while the codec still powers down. Measured over 30 s
idle: the codec was off for 28.3 s (`power_off_acct`) with the
controller active, and a plug while idle was reported immediately, so
sound started on the headset. The parameter is only used to decide
whether the controller may runtime-suspend; it also applies to the HDMI
audio controller. The repository ships it as the optional
`modprobe.d/macbookair-audio.conf` (see the README). A kernel-side fix
(not losing plug events while the controller is suspended) is tracked as
an issue.

### Note: power_save=10

macOS idles this codec after 10 s; Linux defaults to 1 s on many
distributions. `options snd_hda_intel power_save=10` would imitate macOS
and reduce suspend/resume cycles. It is not needed for the fix and is
not set by this repository.

## Not done yet

- Headset buttons: the macOS driver has button-detection code for this
  codec; how it handles play/pause and Apple-style volume buttons has not
  been analysed yet, and nothing is implemented here.
- Other CS4208 Macs (MacBookPro11,x/12,1, iMac, Mac mini) have different
  layouts; nothing here claims support for them.
