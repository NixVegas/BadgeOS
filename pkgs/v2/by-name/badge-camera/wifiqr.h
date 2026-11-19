/* Wi-Fi network QR codes: WIFI:T:WPA;S:name;P:secret;H:false;; */
#ifndef BADGE_CAMERA_WIFIQR_H
#define BADGE_CAMERA_WIFIQR_H

#include <stdbool.h>
#include <stddef.h>

struct wifi_qr {
	char ssid[33 * 4];  /* SSIDs are up to 32 bytes; room for escapes undone */
	char password[64 * 2];
	char security[16];  /* "WPA", "WEP", "SAE", "nopass" or empty */
	bool hidden;
};

/* Parses a WIFI: payload. Returns true for a usable network (non-empty SSID). */
bool wifiqr_parse(const char *payload, size_t len, struct wifi_qr *out);

#endif
