/*
 * The QR reader. zxing-cpp rather than quirc: on frames from this camera, hand-held in
 * front of a screen at a 12 ms exposure, quirc located the code and then failed its
 * error correction every time, where this reads the same frames.
 */
#include <cstring>
#include <string>

#include <ZXing/ReadBarcode.h>

#include "qrread.h"

size_t qr_read(const uint8_t *gray, unsigned w, unsigned h, char *text, size_t cap)
{

	if (!cap)
		return 0;
	text[0] = 0;
	try {
		ZXing::ImageView image(gray, (int)w, (int)h, ZXing::ImageFormat::Lum);

		{
			ZXing::ReaderOptions o;

			o.setFormats(ZXing::BarcodeFormat::QRCode);
			o.setBinarizer(ZXing::Binarizer::LocalAverage);
			o.setTextMode(ZXing::TextMode::Plain);
			ZXing::Barcode r = ZXing::ReadBarcode(image, o);
			if (!r.isValid())
				return 0;
			std::string s = r.text();
			size_t n = s.size() < cap - 1 ? s.size() : cap - 1;

			if (!n)
				return 0;
			memcpy(text, s.data(), n);
			text[n] = 0;
			return n;
		}
	} catch (...) {
		/* Out of memory or a malformed symbol: no code, as far as the caller goes. */
	}
	return 0;
}
