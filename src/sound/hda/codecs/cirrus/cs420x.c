// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Cirrus Logic CS420x HD-audio codec
 *
 * Copyright (c) 2009 Takashi Iwai <tiwai@suse.de>
 */

#include <linux/delay.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <sound/core.h>
#include <linux/pci.h>
#include <sound/tlv.h>
#include <sound/hda_codec.h>
#include "hda_local.h"
#include "hda_auto_parser.h"
#include "hda_jack.h"
#include "../generic.h"

struct cs_spec {
	struct hda_gen_spec gen;

	unsigned int gpio_mask;
	unsigned int gpio_dir;
	unsigned int gpio_data;
	unsigned int gpio_eapd_hp; /* EAPD GPIO bit for headphones */
	unsigned int gpio_eapd_speaker; /* EAPD GPIO bit for speakers */
	unsigned int gpio_always_on; /* GPIO bits kept high in any jack state */

	bool mba6_hsmic; /* MacBookAir6,x combo-jack headset mic */
	bool hsmic_present; /* last headset mic probe result */
	int hsmic_hp_last; /* HP jack state at the last probe, -1: unknown */
	struct delayed_work hsmic_work;
	int hp_cached; /* last settled HP jack state, -1: unknown */
	struct delayed_work hp_verify_work;
	struct hda_codec *codec;

	hda_nid_t vendor_nid;

	/* for MBP SPDIF control */
	int (*spdif_sw_put)(struct snd_kcontrol *kcontrol,
			    struct snd_ctl_elem_value *ucontrol);
};

/* available models with CS420x */
enum {
	CS420X_MBP53,
	CS420X_MBP55,
	CS420X_IMAC27,
	CS420X_GPIO_13,
	CS420X_GPIO_23,
	CS420X_MBP101,
	CS420X_MBP81,
	CS420X_MBA42,
	CS420X_AUTO,
	/* aliases */
	CS420X_IMAC27_122 = CS420X_GPIO_23,
	CS420X_APPLE = CS420X_GPIO_13,
};

/* Vendor-specific processing widget */
#define CS420X_VENDOR_NID	0x11
#define CS_DIG_OUT1_PIN_NID	0x10
#define CS_DIG_OUT2_PIN_NID	0x15
#define CS_DMIC1_PIN_NID	0x0e
#define CS_DMIC2_PIN_NID	0x12

/* coef indices */
#define IDX_SPDIF_STAT		0x0000
#define IDX_SPDIF_CTL		0x0001
#define IDX_ADC_CFG		0x0002
/* SZC bitmask, 4 modes below:
 * 0 = immediate,
 * 1 = digital immediate, analog zero-cross
 * 2 = digtail & analog soft-ramp
 * 3 = digital soft-ramp, analog zero-cross
 */
#define   CS_COEF_ADC_SZC_MASK		(3 << 0)
#define   CS_COEF_ADC_MIC_SZC_MODE	(3 << 0) /* SZC setup for mic */
#define   CS_COEF_ADC_LI_SZC_MODE	(3 << 0) /* SZC setup for line-in */
/* PGA mode: 0 = differential, 1 = signle-ended */
#define   CS_COEF_ADC_MIC_PGA_MODE	(1 << 5) /* PGA setup for mic */
#define   CS_COEF_ADC_LI_PGA_MODE	(1 << 6) /* PGA setup for line-in */
#define IDX_DAC_CFG		0x0003
/* SZC bitmask, 4 modes below:
 * 0 = Immediate
 * 1 = zero-cross
 * 2 = soft-ramp
 * 3 = soft-ramp on zero-cross
 */
#define   CS_COEF_DAC_HP_SZC_MODE	(3 << 0) /* nid 0x02 */
#define   CS_COEF_DAC_LO_SZC_MODE	(3 << 2) /* nid 0x03 */
#define   CS_COEF_DAC_SPK_SZC_MODE	(3 << 4) /* nid 0x04 */

#define IDX_BEEP_CFG		0x0004
/* 0x0008 - test reg key */
/* 0x0009 - 0x0014 -> 12 test regs */
/* 0x0015 - visibility reg */

/* Cirrus Logic CS4208 */
#define CS4208_VENDOR_NID	0x24

static inline int cs_vendor_coef_get(struct hda_codec *codec, unsigned int idx)
{
	struct cs_spec *spec = codec->spec;

	snd_hda_codec_write(codec, spec->vendor_nid, 0,
			    AC_VERB_SET_COEF_INDEX, idx);
	return snd_hda_codec_read(codec, spec->vendor_nid, 0,
				  AC_VERB_GET_PROC_COEF, 0);
}

static inline void cs_vendor_coef_set(struct hda_codec *codec, unsigned int idx,
				      unsigned int coef)
{
	struct cs_spec *spec = codec->spec;

	snd_hda_codec_write(codec, spec->vendor_nid, 0,
			    AC_VERB_SET_COEF_INDEX, idx);
	snd_hda_codec_write(codec, spec->vendor_nid, 0,
			    AC_VERB_SET_PROC_COEF, coef);
}

/*
 * auto-mute and auto-mic switching
 * CS421x auto-output redirecting
 * HP/SPK/SPDIF
 */

/*
 * MacBookAir6,x headset mic presence detection
 *
 * Pin 0x18 never reports presence. The macOS driver instead probes the
 * mic line with a comparator of the vendor widget: with the comparator
 * enabled, bit 8 of coefficient 0x1f reads back set if a mic is
 * connected, and it must read clear again once the comparator is off
 * (3-pole headphones keep the bit set in both states). The mic bias of
 * pin 0x18 has to be on for the probe.
 */
#define CS4208_HSMIC_PIN	0x18

static bool cs4208_mba6_hsmic_probe(struct hda_codec *codec)
{
	unsigned int coef_1c, coef_1d, vstate, on, off;

	coef_1d = cs_vendor_coef_get(codec, 0x1d);
	cs_vendor_coef_set(codec, 0x1d, (coef_1d & ~0x3e) | 0x34);
	vstate = snd_hda_codec_read(codec, CS4208_VENDOR_NID, 0, 0xff1, 0);
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0, 0x7f1,
			    vstate & 0xff7f);
	coef_1c = cs_vendor_coef_get(codec, 0x1c);
	cs_vendor_coef_set(codec, 0x1c, coef_1c | 0x2000);
	msleep(20);
	on = cs_vendor_coef_get(codec, 0x1f);
	cs_vendor_coef_set(codec, 0x1d,
			   cs_vendor_coef_get(codec, 0x1d) & ~0x3e);
	off = cs_vendor_coef_get(codec, 0x1f);

	cs_vendor_coef_set(codec, 0x1c, coef_1c);
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0, 0x7f1,
			    vstate & 0xffff);
	cs_vendor_coef_set(codec, 0x1d, coef_1d);

	codec_dbg(codec, "headset mic probe: 0x1f on=0x%x off=0x%x\n",
		  on, off);
	return (on & 0x100) && !(off & 0x100);
}

/*
 * Feed the probe result into the jack table in place of the empty pin
 * sense, so that both the "Mic Jack" control and the generic auto-mic
 * switch follow it.
 */
static void cs4208_mba6_hsmic_apply(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;
	struct hda_jack_tbl *jack;

	jack = snd_hda_jack_tbl_get(codec, CS4208_HSMIC_PIN);
	if (!jack)
		return;
	jack->pin_sense = spec->hsmic_present ? AC_PINSENSE_PRESENCE : 0;
	jack->jack_dirty = 0;
}

static void cs4208_mba6_hsmic_set(struct hda_codec *codec, bool present)
{
	struct cs_spec *spec = codec->spec;
	struct hda_jack_callback *cb;
	struct hda_jack_tbl *jack;

	spec->hsmic_present = present;
	cs4208_mba6_hsmic_apply(codec);
	jack = snd_hda_jack_tbl_get(codec, CS4208_HSMIC_PIN);
	if (jack) {
		/*
		 * Run the pin's callbacks (path power, auto-mic) like an
		 * unsolicited event would, but without marking the jack
		 * dirty, which would re-read the hardware pin sense.
		 */
		for (cb = jack->callback; cb; cb = cb->next) {
			cb->jack = jack;
			cb->unsol_res = 0;
			cb->func(codec, cb);
		}
	}
	snd_hda_jack_report_sync(codec);
}

static void cs4208_mba6_hsmic_work(struct work_struct *work)
{
	struct cs_spec *spec = container_of(to_delayed_work(work),
					    struct cs_spec, hsmic_work);
	struct hda_codec *codec = spec->codec;
	hda_nid_t hp_pin = spec->gen.autocfg.hp_pins[0];
	bool present = false;

	snd_hda_power_up(codec);
	/* act on the settled HP state, not on the one that scheduled us */
	if (hp_pin && snd_hda_jack_detect(codec, hp_pin)) {
		snd_hda_codec_write(codec, CS4208_HSMIC_PIN, 0,
				    AC_VERB_SET_POWER_STATE, AC_PWRST_D0);
		msleep(20);
		present = cs4208_mba6_hsmic_probe(codec);
	}
	if (present != spec->hsmic_present) {
		codec_dbg(codec, "headset mic %s\n",
			  present ? "present" : "absent");
		cs4208_mba6_hsmic_set(codec, present);
	}
	snd_hda_power_down(codec);
}

static void cs4208_mba6_hsmic_update(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;
	hda_nid_t hp_pin = spec->gen.autocfg.hp_pins[0];
	int hp;

	if (!hp_pin)
		return;
	hp = snd_hda_jack_detect(codec, hp_pin);
	if (hp == spec->hsmic_hp_last)
		return;
	spec->hsmic_hp_last = hp;
	/*
	 * Debounce: when the codec resumes, the HP pin sense reads
	 * "unplugged" for about 50-100 ms. Re-check once the state has
	 * settled (the macOS driver also waits 500 ms before probing) and
	 * only report a change of the mic state.
	 */
	mod_delayed_work(system_wq, &spec->hsmic_work,
			 msecs_to_jiffies(hp ? 500 : 300));
}

/*
 * Own HP jack callback: the automute hook is not called when
 * userspace disables "Auto-Mute Mode".
 */
static void cs4208_mba6_hp_jack_cb(struct hda_codec *codec,
				   struct hda_jack_callback *cb)
{
	struct cs_spec *spec = codec->spec;

	spec->hp_cached = snd_hda_jack_detect(codec,
					      spec->gen.autocfg.hp_pins[0]);
	cs4208_mba6_hsmic_update(codec);
}

/*
 * The HP pin sense reads "unplugged" for about 50-100 ms right after the
 * codec resumes, which made userspace switch the output to the speaker
 * and back at every resume. Keep the last settled HP state over resume
 * (see cs_init()) and verify it once the sense has settled.
 */
static void cs4208_mba6_hp_verify_work(struct work_struct *work)
{
	struct cs_spec *spec = container_of(to_delayed_work(work),
					    struct cs_spec, hp_verify_work);
	struct hda_codec *codec = spec->codec;
	hda_nid_t hp_pin = spec->gen.autocfg.hp_pins[0];
	struct hda_jack_callback *cb;
	struct hda_jack_tbl *jack;
	int hp;

	jack = snd_hda_jack_tbl_get(codec, hp_pin);
	if (!jack)
		return;
	snd_hda_power_up(codec);
	jack->jack_dirty = 1;
	hp = snd_hda_jack_detect(codec, hp_pin);
	if (hp != spec->hp_cached) {
		/* a real plug change while the codec was suspended */
		for (cb = jack->callback; cb; cb = cb->next) {
			cb->jack = jack;
			cb->unsol_res = 0;
			cb->func(codec, cb);
		}
		snd_hda_jack_report_sync(codec);
	}
	snd_hda_power_down(codec);
}

static void cs4208_mba6_hp_resume_hold(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;
	hda_nid_t hp_pin = spec->gen.autocfg.hp_pins[0];
	struct hda_jack_tbl *jack;

	if (!hp_pin || spec->hp_cached < 0)
		return;
	jack = snd_hda_jack_tbl_get(codec, hp_pin);
	if (!jack)
		return;
	jack->pin_sense = spec->hp_cached ? AC_PINSENSE_PRESENCE : 0;
	jack->jack_dirty = 0;
	mod_delayed_work(system_wq, &spec->hp_verify_work,
			 msecs_to_jiffies(200));
}

static void cs_automute(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;

	snd_hda_gen_update_outputs(codec);

	if (spec->gpio_eapd_hp || spec->gpio_eapd_speaker) {
		if (spec->gen.automute_speaker)
			spec->gpio_data = spec->gen.hp_jack_present ?
				spec->gpio_eapd_hp : spec->gpio_eapd_speaker;
		else
			spec->gpio_data =
				spec->gpio_eapd_hp | spec->gpio_eapd_speaker;
		spec->gpio_data |= spec->gpio_always_on;
		snd_hda_codec_write(codec, 0x01, 0,
				    AC_VERB_SET_GPIO_DATA, spec->gpio_data);
	}
}

static bool is_active_pin(struct hda_codec *codec, hda_nid_t nid)
{
	unsigned int val;

	val = snd_hda_codec_get_pincfg(codec, nid);
	return (get_defcfg_connect(val) != AC_JACK_PORT_NONE);
}

static void init_input_coef(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;
	unsigned int coef;

	/* CS420x has multiple ADC, CS421x has single ADC */
	if (spec->vendor_nid == CS420X_VENDOR_NID) {
		coef = cs_vendor_coef_get(codec, IDX_BEEP_CFG);
		if (is_active_pin(codec, CS_DMIC2_PIN_NID))
			coef |= 1 << 4; /* DMIC2 2 chan on, GPIO1 off */
		if (is_active_pin(codec, CS_DMIC1_PIN_NID))
			coef |= 1 << 3; /* DMIC1 2 chan on, GPIO0 off
					 * No effect if SPDIF_OUT2 is
					 * selected in IDX_SPDIF_CTL.
					 */

		cs_vendor_coef_set(codec, IDX_BEEP_CFG, coef);
	}
}

static const struct hda_verb cs_coef_init_verbs[] = {
	{0x11, AC_VERB_SET_PROC_STATE, 1},
	{0x11, AC_VERB_SET_COEF_INDEX, IDX_DAC_CFG},
	{0x11, AC_VERB_SET_PROC_COEF,
	 (0x002a /* DAC1/2/3 SZCMode Soft Ramp */
	  | 0x0040 /* Mute DACs on FIFO error */
	  | 0x1000 /* Enable DACs High Pass Filter */
	  | 0x0400 /* Disable Coefficient Auto increment */
	  )},
	/* ADC1/2 - Digital and Analog Soft Ramp */
	{0x11, AC_VERB_SET_COEF_INDEX, IDX_ADC_CFG},
	{0x11, AC_VERB_SET_PROC_COEF, 0x000a},
	/* Beep */
	{0x11, AC_VERB_SET_COEF_INDEX, IDX_BEEP_CFG},
	{0x11, AC_VERB_SET_PROC_COEF, 0x0007}, /* Enable Beep thru DAC1/2/3 */

	{} /* terminator */
};

static const struct hda_verb cs4208_coef_init_verbs[] = {
	{0x01, AC_VERB_SET_POWER_STATE, 0x00}, /* AFG: D0 */
	{0x24, AC_VERB_SET_PROC_STATE, 0x01},  /* VPW: processing on */
	{0x24, AC_VERB_SET_COEF_INDEX, 0x0033},
	{0x24, AC_VERB_SET_PROC_COEF, 0x0001}, /* A1 ICS */
	{0x24, AC_VERB_SET_COEF_INDEX, 0x0034},
	{0x24, AC_VERB_SET_PROC_COEF, 0x1C01}, /* A1 Enable, A Thresh = 300mV */
	{} /* terminator */
};

/* Errata: CS4207 rev C0/C1/C2 Silicon
 *
 * http://www.cirrus.com/en/pubs/errata/ER880C3.pdf
 *
 * 6. At high temperature (TA > +85°C), the digital supply current (IVD)
 * may be excessive (up to an additional 200 μA), which is most easily
 * observed while the part is being held in reset (RESET# active low).
 *
 * Root Cause: At initial powerup of the device, the logic that drives
 * the clock and write enable to the S/PDIF SRC RAMs is not properly
 * initialized.
 * Certain random patterns will cause a steady leakage current in those
 * RAM cells. The issue will resolve once the SRCs are used (turned on).
 *
 * Workaround: The following verb sequence briefly turns on the S/PDIF SRC
 * blocks, which will alleviate the issue.
 */

static const struct hda_verb cs_errata_init_verbs[] = {
	{0x01, AC_VERB_SET_POWER_STATE, 0x00}, /* AFG: D0 */
	{0x11, AC_VERB_SET_PROC_STATE, 0x01},  /* VPW: processing on */

	{0x11, AC_VERB_SET_COEF_INDEX, 0x0008},
	{0x11, AC_VERB_SET_PROC_COEF, 0x9999},
	{0x11, AC_VERB_SET_COEF_INDEX, 0x0017},
	{0x11, AC_VERB_SET_PROC_COEF, 0xa412},
	{0x11, AC_VERB_SET_COEF_INDEX, 0x0001},
	{0x11, AC_VERB_SET_PROC_COEF, 0x0009},

	{0x07, AC_VERB_SET_POWER_STATE, 0x00}, /* S/PDIF Rx: D0 */
	{0x08, AC_VERB_SET_POWER_STATE, 0x00}, /* S/PDIF Tx: D0 */

	{0x11, AC_VERB_SET_COEF_INDEX, 0x0017},
	{0x11, AC_VERB_SET_PROC_COEF, 0x2412},
	{0x11, AC_VERB_SET_COEF_INDEX, 0x0008},
	{0x11, AC_VERB_SET_PROC_COEF, 0x0000},
	{0x11, AC_VERB_SET_COEF_INDEX, 0x0001},
	{0x11, AC_VERB_SET_PROC_COEF, 0x0008},
	{0x11, AC_VERB_SET_PROC_STATE, 0x00},
	{} /* terminator */
};

/* SPDIF setup */
static void init_digital_coef(struct hda_codec *codec)
{
	unsigned int coef;

	coef = 0x0002; /* SRC_MUTE soft-mute on SPDIF (if no lock) */
	coef |= 0x0008; /* Replace with mute on error */
	if (is_active_pin(codec, CS_DIG_OUT2_PIN_NID))
		coef |= 0x4000; /* RX to TX1 or TX2 Loopthru / SPDIF2
				 * SPDIF_OUT2 is shared with GPIO1 and
				 * DMIC_SDA2.
				 */
	cs_vendor_coef_set(codec, IDX_SPDIF_CTL, coef);
}

static int cs_init(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;

	if (spec->vendor_nid == CS420X_VENDOR_NID) {
		/* init_verb sequence for C0/C1/C2 errata*/
		snd_hda_sequence_write(codec, cs_errata_init_verbs);
		snd_hda_sequence_write(codec, cs_coef_init_verbs);
	} else if (spec->vendor_nid == CS4208_VENDOR_NID) {
		snd_hda_sequence_write(codec, cs4208_coef_init_verbs);
		/* enable the headset mic path of the combo jack */
		if (spec->mba6_hsmic) {
			cs_vendor_coef_set(codec, 0x1a, 0xa6);
			/*
			 * Keep the last probed state across resume and
			 * re-probe once the HP jack state is known.
			 */
			cs4208_mba6_hsmic_apply(codec);
			cs4208_mba6_hp_resume_hold(codec);
			spec->hsmic_hp_last = -1;
		}
	}

	snd_hda_gen_init(codec);

	if (spec->mba6_hsmic) {
		hda_nid_t hp_pin = spec->gen.autocfg.hp_pins[0];

		if (spec->hp_cached < 0 && hp_pin)
			spec->hp_cached = snd_hda_jack_detect(codec, hp_pin);
		cs4208_mba6_hsmic_update(codec);
	}

	if (spec->gpio_mask) {
		spec->gpio_data |= spec->gpio_always_on;
		snd_hda_codec_write(codec, 0x01, 0, AC_VERB_SET_GPIO_MASK,
				    spec->gpio_mask);
		snd_hda_codec_write(codec, 0x01, 0, AC_VERB_SET_GPIO_DIRECTION,
				    spec->gpio_dir);
		snd_hda_codec_write(codec, 0x01, 0, AC_VERB_SET_GPIO_DATA,
				    spec->gpio_data);
	}

	if (spec->vendor_nid == CS420X_VENDOR_NID) {
		init_input_coef(codec);
		init_digital_coef(codec);
	}

	return 0;
}

static int cs_build_controls(struct hda_codec *codec)
{
	int err;

	err = snd_hda_gen_build_controls(codec);
	if (err < 0)
		return err;
	snd_hda_apply_fixup(codec, HDA_FIXUP_ACT_BUILD);
	return 0;
}

static int cs_parse_auto_config(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;
	int err;
	int i;

	err = snd_hda_parse_pin_defcfg(codec, &spec->gen.autocfg, NULL, 0);
	if (err < 0)
		return err;

	err = snd_hda_gen_parse_auto_config(codec, &spec->gen.autocfg);
	if (err < 0)
		return err;

	/* keep the ADCs powered up when it's dynamically switchable */
	if (spec->gen.dyn_adc_switch) {
		unsigned int done = 0;

		for (i = 0; i < spec->gen.input_mux.num_items; i++) {
			int idx = spec->gen.dyn_adc_idx[i];

			if (done & (1 << idx))
				continue;
			snd_hda_gen_fix_pin_power(codec,
						  spec->gen.adc_nids[idx]);
			done |= 1 << idx;
		}
	}

	return 0;
}

static const struct hda_model_fixup cs420x_models[] = {
	{ .id = CS420X_MBP53, .name = "mbp53" },
	{ .id = CS420X_MBP55, .name = "mbp55" },
	{ .id = CS420X_IMAC27, .name = "imac27" },
	{ .id = CS420X_IMAC27_122, .name = "imac27_122" },
	{ .id = CS420X_APPLE, .name = "apple" },
	{ .id = CS420X_MBP101, .name = "mbp101" },
	{ .id = CS420X_MBP81, .name = "mbp81" },
	{ .id = CS420X_MBA42, .name = "mba42" },
	{}
};

static const struct hda_quirk cs420x_fixup_tbl[] = {
	SND_PCI_QUIRK(0x10de, 0x0ac0, "MacBookPro 5,3", CS420X_MBP53),
	SND_PCI_QUIRK(0x10de, 0x0d94, "MacBookAir 3,1(2)", CS420X_MBP55),
	SND_PCI_QUIRK(0x10de, 0xcb79, "MacBookPro 5,5", CS420X_MBP55),
	SND_PCI_QUIRK(0x10de, 0xcb89, "MacBookPro 7,1", CS420X_MBP55),
	/* this conflicts with too many other models */
	/*SND_PCI_QUIRK(0x8086, 0x7270, "IMac 27 Inch", CS420X_IMAC27),*/

	/* codec SSID */
	SND_PCI_QUIRK(0x106b, 0x0600, "iMac 14,1", CS420X_IMAC27_122),
	SND_PCI_QUIRK(0x106b, 0x0900, "iMac 12,1", CS420X_IMAC27_122),
	SND_PCI_QUIRK(0x106b, 0x1c00, "MacBookPro 8,1", CS420X_MBP81),
	SND_PCI_QUIRK(0x106b, 0x2000, "iMac 12,2", CS420X_IMAC27_122),
	SND_PCI_QUIRK(0x106b, 0x2800, "MacBookPro 10,1", CS420X_MBP101),
	SND_PCI_QUIRK(0x106b, 0x5600, "MacBookAir 5,2", CS420X_MBP81),
	SND_PCI_QUIRK(0x106b, 0x5b00, "MacBookAir 4,2", CS420X_MBA42),
	SND_PCI_QUIRK_VENDOR(0x106b, "Apple", CS420X_APPLE),
	{} /* terminator */
};

static const struct hda_pintbl mbp53_pincfgs[] = {
	{ 0x09, 0x012b4050 },
	{ 0x0a, 0x90100141 },
	{ 0x0b, 0x90100140 },
	{ 0x0c, 0x018b3020 },
	{ 0x0d, 0x90a00110 },
	{ 0x0e, 0x400000f0 },
	{ 0x0f, 0x01cbe030 },
	{ 0x10, 0x014be060 },
	{ 0x12, 0x400000f0 },
	{ 0x15, 0x400000f0 },
	{} /* terminator */
};

static const struct hda_pintbl mbp55_pincfgs[] = {
	{ 0x09, 0x012b4030 },
	{ 0x0a, 0x90100121 },
	{ 0x0b, 0x90100120 },
	{ 0x0c, 0x400000f0 },
	{ 0x0d, 0x90a00110 },
	{ 0x0e, 0x400000f0 },
	{ 0x0f, 0x400000f0 },
	{ 0x10, 0x014be040 },
	{ 0x12, 0x400000f0 },
	{ 0x15, 0x400000f0 },
	{} /* terminator */
};

static const struct hda_pintbl imac27_pincfgs[] = {
	{ 0x09, 0x012b4050 },
	{ 0x0a, 0x90100140 },
	{ 0x0b, 0x90100142 },
	{ 0x0c, 0x018b3020 },
	{ 0x0d, 0x90a00110 },
	{ 0x0e, 0x400000f0 },
	{ 0x0f, 0x01cbe030 },
	{ 0x10, 0x014be060 },
	{ 0x12, 0x01ab9070 },
	{ 0x15, 0x400000f0 },
	{} /* terminator */
};

static const struct hda_pintbl mbp101_pincfgs[] = {
	{ 0x0d, 0x40ab90f0 },
	{ 0x0e, 0x90a600f0 },
	{ 0x12, 0x50a600f0 },
	{} /* terminator */
};

static const struct hda_pintbl mba42_pincfgs[] = {
	{ 0x09, 0x012b4030 }, /* HP */
	{ 0x0a, 0x400000f0 },
	{ 0x0b, 0x90100120 }, /* speaker */
	{ 0x0c, 0x400000f0 },
	{ 0x0d, 0x90a00110 }, /* mic */
	{ 0x0e, 0x400000f0 },
	{ 0x0f, 0x400000f0 },
	{ 0x10, 0x400000f0 },
	{ 0x12, 0x400000f0 },
	{ 0x15, 0x400000f0 },
	{} /* terminator */
};

static const struct hda_pintbl mba6_pincfgs[] = {
	{ 0x10, 0x032120f0 }, /* HP */
	{ 0x11, 0x500000f0 },
	{ 0x12, 0x90100010 }, /* Speaker */
	{ 0x13, 0x500000f0 },
	{ 0x14, 0x500000f0 },
	{ 0x15, 0x770000f0 },
	{ 0x16, 0x770000f0 },
	{ 0x17, 0x430000f0 },
	{ 0x18, 0x43ab9030 }, /* Mic */
	{ 0x19, 0x770000f0 },
	{ 0x1a, 0x770000f0 },
	{ 0x1b, 0x770000f0 },
	{ 0x1c, 0x90a00090 },
	{ 0x1d, 0x500000f0 },
	{ 0x1e, 0x500000f0 },
	{ 0x1f, 0x500000f0 },
	{ 0x20, 0x500000f0 },
	{ 0x21, 0x430000f0 },
	{ 0x22, 0x430000f0 },
	{} /* terminator */
};

static void cs420x_fixup_gpio_13(struct hda_codec *codec,
				 const struct hda_fixup *fix, int action)
{
	if (action == HDA_FIXUP_ACT_PRE_PROBE) {
		struct cs_spec *spec = codec->spec;

		spec->gpio_eapd_hp = 2; /* GPIO1 = headphones */
		spec->gpio_eapd_speaker = 8; /* GPIO3 = speakers */
		spec->gpio_mask = spec->gpio_dir =
			spec->gpio_eapd_hp | spec->gpio_eapd_speaker;
	}
}

static void cs420x_fixup_gpio_23(struct hda_codec *codec,
				 const struct hda_fixup *fix, int action)
{
	if (action == HDA_FIXUP_ACT_PRE_PROBE) {
		struct cs_spec *spec = codec->spec;

		spec->gpio_eapd_hp = 4; /* GPIO2 = headphones */
		spec->gpio_eapd_speaker = 8; /* GPIO3 = speakers */
		spec->gpio_mask = spec->gpio_dir =
			spec->gpio_eapd_hp | spec->gpio_eapd_speaker;
	}
}

static const struct hda_fixup cs420x_fixups[] = {
	[CS420X_MBP53] = {
		.type = HDA_FIXUP_PINS,
		.v.pins = mbp53_pincfgs,
		.chained = true,
		.chain_id = CS420X_APPLE,
	},
	[CS420X_MBP55] = {
		.type = HDA_FIXUP_PINS,
		.v.pins = mbp55_pincfgs,
		.chained = true,
		.chain_id = CS420X_GPIO_13,
	},
	[CS420X_IMAC27] = {
		.type = HDA_FIXUP_PINS,
		.v.pins = imac27_pincfgs,
		.chained = true,
		.chain_id = CS420X_GPIO_13,
	},
	[CS420X_GPIO_13] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = cs420x_fixup_gpio_13,
	},
	[CS420X_GPIO_23] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = cs420x_fixup_gpio_23,
	},
	[CS420X_MBP101] = {
		.type = HDA_FIXUP_PINS,
		.v.pins = mbp101_pincfgs,
		.chained = true,
		.chain_id = CS420X_GPIO_13,
	},
	[CS420X_MBP81] = {
		.type = HDA_FIXUP_VERBS,
		.v.verbs = (const struct hda_verb[]) {
			/* internal mic ADC2: right only, single ended */
			{0x11, AC_VERB_SET_COEF_INDEX, IDX_ADC_CFG},
			{0x11, AC_VERB_SET_PROC_COEF, 0x102a},
			{}
		},
		.chained = true,
		.chain_id = CS420X_GPIO_13,
	},
	[CS420X_MBA42] = {
		.type = HDA_FIXUP_PINS,
		.v.pins = mba42_pincfgs,
		.chained = true,
		.chain_id = CS420X_GPIO_13,
	},
};

static struct cs_spec *cs_alloc_spec(struct hda_codec *codec, int vendor_nid)
{
	struct cs_spec *spec;

	spec = kzalloc_obj(*spec);
	if (!spec)
		return NULL;
	codec->spec = spec;
	spec->vendor_nid = vendor_nid;
	codec->power_save_node = 1;
	snd_hda_gen_spec_init(&spec->gen);

	return spec;
}

static int cs420x_probe(struct hda_codec *codec)
{
	int err;

	codec->single_adc_amp = 1;

	snd_hda_pick_fixup(codec, cs420x_models, cs420x_fixup_tbl,
			   cs420x_fixups);
	snd_hda_apply_fixup(codec, HDA_FIXUP_ACT_PRE_PROBE);

	err = cs_parse_auto_config(codec);
	if (err < 0)
		return err;

	snd_hda_apply_fixup(codec, HDA_FIXUP_ACT_PROBE);

	return 0;
}

/*
 * CS4208 support:
 * Its layout is no longer compatible with CS4206/CS4207
 */
enum {
	CS4208_MAC_AUTO,
	CS4208_MBA6,
	CS4208_MBP11,
	CS4208_MACMINI,
	CS4208_GPIO0,
	CS4208_MBA6_HSMIC,
};

static const struct hda_model_fixup cs4208_models[] = {
	{ .id = CS4208_GPIO0, .name = "gpio0" },
	{ .id = CS4208_MBA6, .name = "mba6" },
	{ .id = CS4208_MBP11, .name = "mbp11" },
	{ .id = CS4208_MACMINI, .name = "macmini" },
	{}
};

static const struct hda_quirk cs4208_fixup_tbl[] = {
	SND_PCI_QUIRK_VENDOR(0x106b, "Apple", CS4208_MAC_AUTO),
	{} /* terminator */
};

/* codec SSID matching */
static const struct hda_quirk cs4208_mac_fixup_tbl[] = {
	SND_PCI_QUIRK(0x106b, 0x5e00, "MacBookPro 11,2", CS4208_MBP11),
	SND_PCI_QUIRK(0x106b, 0x6c00, "MacMini 7,1", CS4208_MACMINI),
	SND_PCI_QUIRK(0x106b, 0x7100, "MacBookAir 6,1", CS4208_MBA6),
	SND_PCI_QUIRK(0x106b, 0x7200, "MacBookAir 6,2", CS4208_MBA6),
	SND_PCI_QUIRK(0x106b, 0x7800, "MacPro 6,1", CS4208_MACMINI),
	SND_PCI_QUIRK(0x106b, 0x7b00, "MacBookPro 12,1", CS4208_MBP11),
	{} /* terminator */
};

static void cs4208_fixup_gpio0(struct hda_codec *codec,
			       const struct hda_fixup *fix, int action)
{
	if (action == HDA_FIXUP_ACT_PRE_PROBE) {
		struct cs_spec *spec = codec->spec;

		spec->gpio_eapd_hp = 0;
		spec->gpio_eapd_speaker = 1;
		spec->gpio_mask = spec->gpio_dir =
			spec->gpio_eapd_hp | spec->gpio_eapd_speaker;
	}
}

/*
 * MacBookAir6,1/6,2: headset mic on the combo jack (pin 0x18).
 *
 * The mic line is only connected when GPIO4 is driven high and vendor
 * coefficient 0x1a is set to 0xa6, as the macOS driver does for a CTIA
 * headset; without both, pin 0x18 records nothing but the ADC noise floor.
 * The pin does not report presence; it is probed when the HP jack is
 * plugged, see cs4208_mba6_hsmic_probe().
 */
static void cs4208_fixup_mba6_hsmic(struct hda_codec *codec,
				    const struct hda_fixup *fix, int action)
{
	static const struct hda_pintbl pincfgs[] = {
		{ 0x18, 0x03ab9030 }, /* headset mic jack */
		{ }
	};
	struct cs_spec *spec = codec->spec;
	hda_nid_t hp_pin;

	if (action == HDA_FIXUP_ACT_PROBE) {
		hp_pin = spec->gen.autocfg.hp_pins[0];
		if (!hp_pin)
			return;
		snd_hda_jack_detect_enable_callback(codec, hp_pin,
						    cs4208_mba6_hp_jack_cb);
		return;
	}
	if (action != HDA_FIXUP_ACT_PRE_PROBE)
		return;

	snd_hda_apply_pincfgs(codec, pincfgs);
	spec->gpio_always_on = 0x10; /* GPIO4: headset mic switch */
	spec->gpio_mask |= spec->gpio_always_on;
	spec->gpio_dir |= spec->gpio_always_on;
	spec->gpio_data |= spec->gpio_always_on;
	spec->mba6_hsmic = true;
	spec->codec = codec;
	spec->hsmic_hp_last = -1;
	INIT_DELAYED_WORK(&spec->hsmic_work, cs4208_mba6_hsmic_work);
	spec->hp_cached = -1;
	INIT_DELAYED_WORK(&spec->hp_verify_work, cs4208_mba6_hp_verify_work);
	/*
	 * The ADC input amp is shared by all connection indices: writing the
	 * (muted) amp of an unused input mutes the selected one as well.
	 */
	codec->single_adc_amp = 1;
}

static const struct hda_fixup cs4208_fixups[];

/* remap the fixup from codec SSID and apply it */
static void cs4208_fixup_mac(struct hda_codec *codec,
			     const struct hda_fixup *fix, int action)
{
	if (action != HDA_FIXUP_ACT_PRE_PROBE)
		return;

	codec->fixup_id = HDA_FIXUP_ID_NOT_SET;
	snd_hda_pick_fixup(codec, NULL, cs4208_mac_fixup_tbl, cs4208_fixups);
	if (codec->fixup_id == HDA_FIXUP_ID_NOT_SET)
		codec->fixup_id = CS4208_GPIO0; /* default fixup */
	snd_hda_apply_fixup(codec, action);
}

/* MacMini 7,1 has the inverted jack detection */
static void cs4208_fixup_macmini(struct hda_codec *codec,
				 const struct hda_fixup *fix, int action)
{
	static const struct hda_pintbl pincfgs[] = {
		{ 0x18, 0x00ab9150 }, /* mic (audio-in) jack: disable detect */
		{ 0x21, 0x004be140 }, /* SPDIF: disable detect */
		{ }
	};

	if (action == HDA_FIXUP_ACT_PRE_PROBE) {
		/* HP pin (0x10) has an inverted detection */
		codec->inv_jack_detect = 1;
		/* disable the bogus Mic and SPDIF jack detections */
		snd_hda_apply_pincfgs(codec, pincfgs);
	}
}

static int cs4208_spdif_sw_put(struct snd_kcontrol *kcontrol,
			       struct snd_ctl_elem_value *ucontrol)
{
	struct hda_codec *codec = snd_kcontrol_chip(kcontrol);
	struct cs_spec *spec = codec->spec;
	hda_nid_t pin = spec->gen.autocfg.dig_out_pins[0];
	int pinctl = ucontrol->value.integer.value[0] ? PIN_OUT : 0;

	snd_hda_set_pin_ctl_cache(codec, pin, pinctl);
	return spec->spdif_sw_put(kcontrol, ucontrol);
}

/* hook the SPDIF switch */
static void cs4208_fixup_spdif_switch(struct hda_codec *codec,
				      const struct hda_fixup *fix, int action)
{
	if (action == HDA_FIXUP_ACT_BUILD) {
		struct cs_spec *spec = codec->spec;
		struct snd_kcontrol *kctl;

		if (!spec->gen.autocfg.dig_out_pins[0])
			return;
		kctl = snd_hda_find_mixer_ctl(codec, "IEC958 Playback Switch");
		if (!kctl)
			return;
		spec->spdif_sw_put = kctl->put;
		kctl->put = cs4208_spdif_sw_put;
	}
}

static const struct hda_fixup cs4208_fixups[] = {
	[CS4208_MBA6] = {
		.type = HDA_FIXUP_PINS,
		.v.pins = mba6_pincfgs,
		.chained = true,
		.chain_id = CS4208_MBA6_HSMIC,
	},
	[CS4208_MBA6_HSMIC] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = cs4208_fixup_mba6_hsmic,
		/* cs4208_fixup_gpio0() sets the GPIO masks; run it first */
		.chained = true,
		.chained_before = true,
		.chain_id = CS4208_GPIO0,
	},
	[CS4208_MBP11] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = cs4208_fixup_spdif_switch,
		.chained = true,
		.chain_id = CS4208_GPIO0,
	},
	[CS4208_MACMINI] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = cs4208_fixup_macmini,
		.chained = true,
		.chain_id = CS4208_GPIO0,
	},
	[CS4208_GPIO0] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = cs4208_fixup_gpio0,
	},
	[CS4208_MAC_AUTO] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = cs4208_fixup_mac,
	},
};

/* correct the 0dB offset of input pins */
static void cs4208_fix_amp_caps(struct hda_codec *codec, hda_nid_t adc)
{
	unsigned int caps;

	caps = query_amp_caps(codec, adc, HDA_INPUT);
	caps &= ~(AC_AMPCAP_OFFSET);
	caps |= 0x02;
	snd_hda_override_amp_caps(codec, adc, HDA_INPUT, caps);
}

static int cs4208_probe(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;
	int err;

	/* exclude NID 0x10 (HP) from output volumes due to different steps */
	spec->gen.out_vol_mask = 1ULL << 0x10;

	snd_hda_pick_fixup(codec, cs4208_models, cs4208_fixup_tbl,
			   cs4208_fixups);
	snd_hda_apply_fixup(codec, HDA_FIXUP_ACT_PRE_PROBE);

	snd_hda_override_wcaps(codec, 0x18,
			       get_wcaps(codec, 0x18) | AC_WCAP_STEREO);
	cs4208_fix_amp_caps(codec, 0x18);
	cs4208_fix_amp_caps(codec, 0x1b);
	cs4208_fix_amp_caps(codec, 0x1c);

	err = cs_parse_auto_config(codec);
	if (err < 0)
		return err;

	snd_hda_apply_fixup(codec, HDA_FIXUP_ACT_PROBE);

	return 0;
}

static int cs_codec_probe(struct hda_codec *codec,
			  const struct hda_device_id *id)
{
	struct cs_spec *spec;
	int err;

	spec = cs_alloc_spec(codec, id->driver_data);
	if (!spec)
		return -ENOMEM;
	spec->gen.automute_hook = cs_automute;

	if (spec->vendor_nid == CS4208_VENDOR_NID)
		err = cs4208_probe(codec);
	else
		err = cs420x_probe(codec);
	if (err < 0)
		snd_hda_gen_remove(codec);
	return err;
}

static void cs_remove(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;

	if (spec->mba6_hsmic) {
		/*
		 * Unsolicited events are still delivered while the codec is
		 * removed, and the HP jack callback queues hsmic_work:
		 * disable the works rather than cancel them, so that nothing
		 * can queue them again before spec is freed.
		 */
		disable_delayed_work_sync(&spec->hp_verify_work);
		disable_delayed_work_sync(&spec->hsmic_work);
	}
	snd_hda_gen_remove(codec);
}

static int cs_suspend(struct hda_codec *codec)
{
	struct cs_spec *spec = codec->spec;

	/* not _sync: the work takes a power reference by itself */
	if (spec->mba6_hsmic) {
		cancel_delayed_work(&spec->hp_verify_work);
		cancel_delayed_work(&spec->hsmic_work);
	}
	return 0;
}

static const struct hda_codec_ops cs_codec_ops = {
	.probe = cs_codec_probe,
	.remove = cs_remove,
	.suspend = cs_suspend,
	.build_controls = cs_build_controls,
	.build_pcms = snd_hda_gen_build_pcms,
	.init = cs_init,
	.unsol_event = snd_hda_jack_unsol_event,
	.stream_pm = snd_hda_gen_stream_pm,
};

/*
 * driver entries
 */
static const struct hda_device_id snd_hda_id_cs420x[] = {
	HDA_CODEC_ID_MODEL(0x10134206, "CS4206", CS420X_VENDOR_NID),
	HDA_CODEC_ID_MODEL(0x10134207, "CS4207", CS420X_VENDOR_NID),
	HDA_CODEC_ID_MODEL(0x10134208, "CS4208", CS4208_VENDOR_NID),
	{} /* terminator */
};
MODULE_DEVICE_TABLE(hdaudio, snd_hda_id_cs420x);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Cirrus Logic CS420x HD-audio codec");

static struct hda_codec_driver cs420x_driver = {
	.id = snd_hda_id_cs420x,
	.ops = &cs_codec_ops,
};

module_hda_codec_driver(cs420x_driver);
