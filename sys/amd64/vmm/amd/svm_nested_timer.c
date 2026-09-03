/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Project Contributors.
 * All rights reserved.
 *
 * L0 timer fast-path for nested SVM.
 *
 * A nested L2 guest measures short delays with DELAY(), which reads the
 * i8254 (PIT) counter in a tight loop, and later with the ACPI power
 * management timer. Each of those port reads is an L2 #VMEXIT that would
 * otherwise be reflected to L1 (bhyve's vatpit / vpmtmr) -- a full
 * L2->L0->L1->L0->L2 round trip per read. FreeBSD's slow LAPIC-timer
 * calibration alone spins DELAY() for a full simulated second, so that
 * reflection cost stretched an L2 boot to tens of minutes.
 *
 * Instead L0 answers these reads directly from the host TSC. The i8254
 * is programmable, so L0 snoops the counter programming (which is still
 * reflected to L1 so L1's vatpit stays authoritative for anything else)
 * and then services the latch+read sequence itself: L2 only ever reads
 * the counter through this path, so the value it sees need only advance
 * at the correct rate, which a TSC-derived count does. The ACPI PM timer
 * is a read-only free-running counter, even simpler.
 */

#include <sys/param.h>
#include <sys/systm.h>

#include <machine/cpufunc.h>
#include <x86/clock.h>		/* tsc_freq */

#include <machine/vmm.h>

#include "vmcb.h"
#include "svm.h"
#include "svm_softc.h"
#include "svm_nested.h"

#define	PIT_FREQ	1193182u
#define	PIT_CTRL	0x43
#define	ACPI_PM_PORT	0x408		/* freedev006 acpi_timer0 */
#define	ACPI_PM_FREQ	3579545u

/* SVM IOIO EXITINFO1 bits (APM Vol 2 15.10.2). */
#define	IOIO_IN		(1u << 0)
#define	IOIO_STR	(1u << 2)
#define	IOIO_REP	(1u << 3)
#define	IOIO_SZ8	(1u << 4)
#define	IOIO_SZ16	(1u << 5)
#define	IOIO_SZ32	(1u << 6)

/*
 * Current value of a down-counter that was loaded with max_count at
 * tsc_base and runs continuously at PIT_FREQ (mode 2/3, as the timer
 * counter used by DELAY() does). Returns a value in [1, max_count].
 */
static uint16_t
pit_current(const struct svm_nested_pit *c)
{
	uint64_t elapsed, max, freq;

	max = c->max_count ? c->max_count : 0x10000;
	freq = tsc_freq ? tsc_freq : 1;
	elapsed = rdtsc() - c->tsc_base;
	elapsed = (elapsed * PIT_FREQ) / freq;	/* host ticks -> PIT ticks */
	elapsed %= max;
	return ((uint16_t)(max - elapsed));
}

/*
 * Try to service an L2 I/O port access to a timer from L0. Returns true
 * if handled (RAX and RIP updated, resume L2 without reflecting), false
 * to let the normal path reflect it to L1. Writes that program the i8254
 * are snooped here and still returned as unhandled so L1 sees them too.
 */
bool
svm_nested_timer_fastpath(struct svm_vcpu *vcpu, uint64_t info1, uint64_t info2)
{
	struct svm_nested *ns;
	struct vmcb_state *state;
	struct svm_nested_pit *c;
	unsigned port, sz;
	bool in;
	uint8_t val;
	int cnum;

	ns = &vcpu->nested;
	if (!ns->nested_in_l2)
		return (false);
	if ((info1 & (IOIO_STR | IOIO_REP)) != 0)	/* only simple accesses */
		return (false);

	port = (info1 >> 16) & 0xffff;
	in = (info1 & IOIO_IN) != 0;
	sz = (info1 & IOIO_SZ8) ? 1 : (info1 & IOIO_SZ16) ? 2 :
	    (info1 & IOIO_SZ32) ? 4 : 0;
	state = svm_get_vmcb_state(vcpu);

	/* ACPI PM timer: 32-bit read-only free-running counter. */
	if (port == ACPI_PM_PORT && in && sz == 4) {
		uint64_t t;

		if (!ns->acpi_known) {
			ns->acpi_tsc_base = rdtsc();
			ns->acpi_known = true;
		}
		t = ((rdtsc() - ns->acpi_tsc_base) * ACPI_PM_FREQ) /
		    (tsc_freq ? tsc_freq : 1);
		state->rax = (state->rax & ~0xffffffffULL) | (uint32_t)t;
		state->rip = info2;
		return (true);
	}

	/* i8254: only single-byte accesses to 0x40-0x43. */
	if (port < 0x40 || port > PIT_CTRL || sz != 1)
		return (false);
	val = (uint8_t)state->rax;

	if (port == PIT_CTRL) {
		if (in)				/* reading 0x43 is undefined */
			return (false);
		cnum = (val >> 6) & 3;
		if (cnum == 3)			/* read-back command: to L1 */
			return (false);
		c = &ns->pit[cnum];
		if (((val >> 4) & 3) == 0) {	/* LATCH command */
			if (!c->known)
				return (false);
			c->latch = pit_current(c);
			c->latched = true;
			c->rd_phase = 0;
			state->rip = info2;	/* L1 need not see a latch */
			return (true);
		}
		/* Programming: record access mode, let L1 program its vatpit. */
		c->access = (val >> 4) & 3;
		c->wr_phase = 0;
		c->known = false;		/* known again once count written */
		return (false);
	}

	/* Counter data ports 0x40/0x41/0x42. */
	cnum = port - 0x40;
	c = &ns->pit[cnum];

	if (!in) {				/* writing the reload count */
		switch (c->access) {
		case 1:				/* lo only */
			c->max_count = val;
			c->tsc_base = rdtsc();
			c->known = true;
			break;
		case 2:				/* hi only */
			c->max_count = (uint16_t)val << 8;
			c->tsc_base = rdtsc();
			c->known = true;
			break;
		case 3:				/* lo then hi */
			if (c->wr_phase == 0) {
				c->max_count = val;
				c->wr_phase = 1;
			} else {
				c->max_count |= (uint16_t)val << 8;
				c->wr_phase = 0;
				c->tsc_base = rdtsc();
				c->known = true;
			}
			break;
		default:
			break;
		}
		return (false);			/* reflect the write to L1 */
	}

	/* Reading the counter. */
	if (!c->known)				/* we cannot answer -> L1 */
		return (false);
	if (c->latched) {
		if (c->rd_phase == 0) {
			val = c->latch & 0xff;
			c->rd_phase = 1;
		} else {
			val = (c->latch >> 8) & 0xff;
			c->latched = false;
		}
	} else {
		val = pit_current(c) & 0xff;	/* live low-byte read */
	}
	state->rax = (state->rax & ~0xffULL) | val;
	state->rip = info2;
	return (true);
}
