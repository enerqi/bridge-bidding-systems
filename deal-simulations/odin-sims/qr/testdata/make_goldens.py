# /// script
# requires-python = ">=3.12"
# dependencies = ["qrcodegen==1.8.0", "zxing-cpp==3.1.1", "pillow==12.3.0"]
# ///
"""Record reference QR matrices for `qr/qr_test.odin` -> goldens.txt.

    uv run --script qr/testdata/make_goldens.py

The reference is Nayuki's `qrcodegen` (the standard's construction, canonical padding). Every matrix is also
SCANNED back with zxing-cpp before it is written, so a golden is a code a real reader opens, not just one
encoder agreeing with another.

Not segno: it appends a whole 0x00 byte after the terminator when the bit stream already ends on a byte
boundary (its `write_padding_bits` pads `8 - length % 8` bits, 8 for 0) - which in byte mode is EVERY time,
since 4 + 8|16 + 8n + 4 is a multiple of 8. Its codes still scan, but every padded one differs from the
standard's.

Each case is a header line, then the symbol's rows as 0/1 (no quiet zone):

    case <ecc> <version|auto> <mask|auto> <text>

`auto` means the reference chose (the smallest version that fits / the lowest penalty mask), and the test asks
the Odin encoder to choose too; the case then records what was chosen on the next line:

    chose <version> <mask>

The texts are ASCII, encoded as bytes (byte mode), with no ECC boost, so a level means exactly what it says.
"""

import pathlib

import zxingcpp
from PIL import Image
from qrcodegen import QrCode, QrSegment

LINK = (
    "https://example.github.io/bridge/player.html#v1.AAxCcmlkZ2UgZGVhbHPQbVF7BqJ-Lt2TGVbCK0ki7gTUsl6BmfkL"
    "ttxQ8Wb0E8ohCnXYmUqzOcZGt8WXR2lZlBUDCgAD-MW7n8Wu3Ufp_kKazVAKTqlq7dQ9t5wz1Ldtx1Er42BdCNMH4iF9a2xcbN_0"
)

ECC = {"L": QrCode.Ecc.LOW, "M": QrCode.Ecc.MEDIUM, "Q": QrCode.Ecc.QUARTILE, "H": QrCode.Ecc.HIGH}

# (text, ecc, version or None, mask or None). A pinned version is a MINIMUM: the smallest that fits from there.
CASES = [
    ("HELLO WORLD", "L", 1, 0),
    ("HELLO WORLD", "M", 1, 3),
    ("HELLO WORLD", "Q", 1, 5),  # fills version 1 at Q exactly: no padding at all
    ("HELLO WORLD", "H", 2, 7),
    ("v1.AAxCcmlkZ2UgZGVhbHM", "M", 2, 1),
    ("v1.AAxCcmlkZ2UgZGVhbHM", "H", 3, 2),
    ("https://example.org/player.html#v1.abc", "Q", 6, 4),
    ("https://example.org/player.html#v1.abc", "M", 7, 6),  # version information from 7
    (LINK, "L", 9, 0),
    (LINK, "M", 10, 5),  # 16-bit character count from 10
    (LINK, "H", 14, 3),
    (LINK * 4, "L", 24, 2),
    (LINK * 4, "M", 27, 7),
    (LINK * 14, "L", 40, 1),
    (LINK * 6, "H", 40, 4),
    # chosen by the encoder: version and mask
    ("HELLO WORLD", "M", None, None),
    ("v1.AAxCcmlkZ2UgZGVhbHM", "L", None, None),
    ("https://example.org/player.html#v1.abc", "Q", None, None),
    (LINK, "M", None, None),
    (LINK * 3, "L", None, None),
    (LINK * 5, "M", None, None),
    (LINK * 9, "L", None, None),
]


def scan(qr: QrCode) -> str:
    """The text zxing-cpp reads from the symbol, drawn 4px a module with the standard's quiet zone."""
    border, px = 4, 4
    side = (qr.get_size() + 2 * border) * px
    img = Image.new("L", (side, side), 255)
    for y in range(qr.get_size()):
        for x in range(qr.get_size()):
            if qr.get_module(x, y):
                img.paste(0, ((x + border) * px, (y + border) * px, (x + border + 1) * px, (y + border + 1) * px))
    found = zxingcpp.read_barcodes(img, formats=zxingcpp.BarcodeFormat.QRCode)
    assert len(found) == 1, f"zxing-cpp found {len(found)} codes"
    return found[0].text


def main() -> None:
    out = [
        "# QR reference matrices, recorded from qrcodegen 1.8.0 (each scanned back by zxing-cpp) by make_goldens.py.",
        "# Never edit by hand; re-record only when adding cases.",
    ]
    for text, ecc, version, mask in CASES:
        seg = [QrSegment.make_bytes(text.encode("ascii"))]
        qr = QrCode.encode_segments(seg, ECC[ecc], version or 1, 40, -1 if mask is None else mask, False)
        assert scan(qr) == text, f"{ecc} v{qr.get_version()}: the reference's code does not scan back"
        out.append(f"case {ecc} {qr.get_version() if version else 'auto'} {'auto' if mask is None else mask} {text}")
        if version is None or mask is None:
            out.append(f"chose {qr.get_version()} {qr.get_mask()}")
        for y in range(qr.get_size()):
            out.append("".join("1" if qr.get_module(x, y) else "0" for x in range(qr.get_size())))
    path = pathlib.Path(__file__).with_name("goldens.txt")
    path.write_text("\n".join(out) + "\n", newline="\n")
    print(f"{path}: {len(CASES)} cases, every one scanned")


if __name__ == "__main__":
    main()
