/* The QR reader, as one C function over zxing-cpp. */
#ifndef QRREAD_H
#define QRREAD_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Reads one QR code from a w by h gray picture, one byte a pixel. Writes its text to
 * `text`, NUL-terminated and cut to fit `cap`, and returns the length, or 0 when the
 * picture holds no code that reads.
 */
size_t qr_read(const uint8_t *gray, unsigned w, unsigned h, char *text, size_t cap);

#ifdef __cplusplus
}
#endif

#endif
