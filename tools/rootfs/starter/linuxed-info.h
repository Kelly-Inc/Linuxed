/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * The Apple device a Linuxed guest runs on, for ztMETRO's apps in place of
 * the Galaxy S9 they were written on. ztmetro-build includes it into the
 * apps that name the phone, its chip and its GPU. linuxed-host prints the
 * device as "iPhone 13 (A15 Bionic)", from the model the app passes the
 * kernel.
 */
#ifndef LINUXED_INFO_H
#define LINUXED_INFO_H

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static inline const char *linuxed_host(void)
{
	static char host[128];
	if (!host[0]) {
		FILE *p = popen("/usr/libexec/linuxed-host 2>/dev/null", "r");
		if (p) {
			if (!fgets(host, sizeof(host), p))
				host[0] = 0;
			pclose(p);
		}
		host[strcspn(host, "\n")] = 0;
		if (!host[0])
			snprintf(host, sizeof(host), "iPhone");
	}
	return host;
}

/* "iPhone 13" from "iPhone 13 (A15 Bionic)". */
static inline const char *linuxed_model(void)
{
	static char model[128];
	snprintf(model, sizeof(model), "%s", linuxed_host());
	char *chip = strstr(model, " (");
	if (chip)
		*chip = 0;
	return model;
}

/* "Apple A15 Bionic", or "Apple silicon" when the model names no chip. */
static inline const char *linuxed_chip(void)
{
	static char chip[96];
	const char *host = linuxed_host();
	const char *open = strchr(host, '(');
	const char *close = open ? strchr(open, ')') : NULL;
	if (open && close)
		snprintf(chip, sizeof(chip), "Apple %.*s", (int)(close - open - 1), open + 1);
	else
		snprintf(chip, sizeof(chip), "Apple silicon");
	return chip;
}

static inline const char *linuxed_cpu(void)
{
	static char cpu[128];
	snprintf(cpu, sizeof(cpu), "%s (%ld cores)", linuxed_chip(),
		 sysconf(_SC_NPROCESSORS_ONLN));
	return cpu;
}

static inline const char *linuxed_gpu(void)
{
	static char gpu[128];
	snprintf(gpu, sizeof(gpu), "%s GPU", linuxed_chip());
	return gpu;
}

static inline const char *linuxed_about(void)
{
	static char about[160];
	snprintf(about, sizeof(about), "%s, ztOS Mobile", linuxed_model());
	return about;
}

#endif
