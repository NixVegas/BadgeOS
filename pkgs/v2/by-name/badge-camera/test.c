/* Wi-Fi payload parsing and one QR fixture through the scanner's gray reduction. */
#include <assert.h>
#include <qrencode.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "convert.h"
#include "qrread.h"
#include "wifiqr.h"

static void parse_cases(void)
{
	struct wifi_qr network;
	const char *escaped = "WIFI:S:a\\;b\\:c\\\\d;P:p\\,q;H:true;T:SAE;;";
	const char *open = "WIFI:T:nopass;S:Open;P:ignored;;";
	const char *invalid[] = {
		"WIFI:T:WPA;P:x;;",
		"WIFI:S:never-ends",
		"https://example.org/",
	};

	assert(wifiqr_parse(escaped, strlen(escaped), &network));
	assert(!strcmp(network.ssid, "a;b:c\\d"));
	assert(!strcmp(network.password, "p,q"));
	assert(!strcmp(network.security, "SAE") && network.hidden);
	assert(wifiqr_parse(open, strlen(open), &network));
	assert(!strcmp(network.ssid, "Open") && !network.password[0]);
	for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++)
		assert(!wifiqr_parse(invalid[i], strlen(invalid[i]), &network));
}

static void decode_fixture(void)
{
	enum { W = 2560, H = 1440, MODULE = 12 };
	const char *payload = "WIFI:T:WPA;S:Badge Lab;P:correct horse battery;;";
	QRcode *code = QRcode_encodeString(payload, 0, QR_ECLEVEL_M, QR_MODE_8, 1);
	uint8_t *frame = malloc(W * H);
	uint8_t *gray = malloc((W / 2) * (H / 2));
	struct wifi_qr network;
	char got[256];

	assert(code && frame && gray);
	memset(frame, 150, W * H);
	int side = (code->width + 8) * MODULE;
	int x0 = (W - side) / 2;
	int y0 = (H - side) / 2;

	for (int y = 0; y < side; y++) {
		for (int x = 0; x < side; x++) {
			int mx = x / MODULE - 4;
			int my = y / MODULE - 4;
			int dark = 0;

			if (mx >= 0 && my >= 0 && mx < code->width && my < code->width)
				dark = code->data[my * code->width + mx] & 1;
			frame[(y0 + y) * W + x0 + x] = dark ? 20 : 235;
		}
	}
	nv21_luma_box(frame, W, W, H, gray, W / 2, H / 2);
	assert(qr_read(gray, W / 2, H / 2, got, sizeof(got)) > 0);
	assert(!strcmp(got, payload));
	assert(wifiqr_parse(got, strlen(got), &network));
	assert(!strcmp(network.ssid, "Badge Lab"));
	QRcode_free(code);
	free(frame);
	free(gray);
}

int main(void)
{
	parse_cases();
	decode_fixture();
	puts("camera-qr: parsing and fixture decode passed");
	return 0;
}
