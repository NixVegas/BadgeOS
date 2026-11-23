/*
 * The WIFI: QR payload as phones and routers print it (the ZXing format): fields
 * T (security), S (SSID), P (password) and H (hidden) in any order, each ended by
 * ';', with '\' escaping ';', ',', ':', '"' and '\' itself.
 */
#include "wifiqr.h"

#include <string.h>
#include <strings.h>

/* Copies one field value from p (up to an unescaped ';') into out; returns the
 * position after the ';', or NULL if the value does not fit or never ends. */
static const char *field(const char *p, const char *end, char *out, size_t size)
{
	size_t n = 0;

	while (p < end && *p != ';') {
		char c = *p++;

		if (c == '\\') {
			if (p == end)
				return NULL;
			c = *p++;
		}
		if (n + 1 >= size)
			return NULL;
		out[n++] = c;
	}
	if (p == end)
		return NULL;
	out[n] = 0;
	return p + 1;
}

bool wifiqr_parse(const char *payload, size_t len, struct wifi_qr *out)
{
	const char *p = payload, *end = payload + len;
	char hidden[8] = "";

	memset(out, 0, sizeof(*out));
	if (len < 5 || strncasecmp(p, "WIFI:", 5))
		return false;
	p += 5;
	while (p < end && *p != ';') {
		char key = *p;
		char scratch[sizeof(out->ssid)];

		if (p + 1 >= end || p[1] != ':')
			return false;
		p += 2;
		switch (key) {
		case 'S':
			p = field(p, end, out->ssid, sizeof(out->ssid));
			break;
		case 'P':
			p = field(p, end, out->password, sizeof(out->password));
			break;
		case 'T':
			p = field(p, end, out->security, sizeof(out->security));
			break;
		case 'H':
			p = field(p, end, hidden, sizeof(hidden));
			break;
		default:
			/* Fields this does not use (E, A, I, PH2 of WPA2-EAP codes...). */
			p = field(p, end, scratch, sizeof(scratch));
			break;
		}
		if (!p)
			return false;
	}
	out->hidden = !strcasecmp(hidden, "true");
	/* An open network carries no password, whatever P says. */
	if (!strcasecmp(out->security, "nopass"))
		out->password[0] = 0;
	return out->ssid[0] != 0;
}
