# /// script
# requires-python = "==3.14.*"
# dependencies = [
#     "docopt",
# ]
# [tool.uv]
# # vision extras are heavy / platform-touchy; install separately when running
# # a real image:  uv pip install opencv-python numpy   (+ paddleocr for the OCR path)
# ///
"""hand-ocr

Bridge hand-diagram image -> PBN (canonical) or LIN (view) deal text.

Usage:
    hand-ocr <image> [--first=<seat>] [--format=<fmt>]
    hand-ocr --demo [--format=<fmt>]

Options:
    <image>            path to a raster hand diagram (screenshot or scan)
    --first=<seat>     PBN 'first' seat: N/E/S/W [default: N]
    --format=<fmt>     output format: pbn | lin [default: pbn]
    --demo             skip vision; emit a hardcoded sample deal (spine check)

Notes:
    PBN can mark unknown hands with '-' (declarer+dummy case). LIN cannot, so
    the lin format requires all four hands known and errors otherwise.
"""

from __future__ import annotations

import sys

from docopt import docopt

from hand_ocr.model import Deal, DealError, Hand


def _demo_deal(first: str) -> Deal:
    # N/S known, E/W unknown -- the declarer+dummy scenario
    north = Hand.from_rows("AKQ4", "KJ3", "AQ5", "T87")
    south = Hand.from_rows("J932", "AQ4", "K87", "AQ2")
    return Deal(hands={"N": north, "E": None, "S": south, "W": None}, first=first)


def _emit(deal: Deal, fmt: str) -> str:
    if fmt == "pbn":
        # emit Board/Dealer/Vulnerable tags too when a Mode-B diagram carried them
        return deal.to_pbn_tags()
    if fmt == "lin":
        return deal.to_lin()
    raise SystemExit(f"unknown --format {fmt!r}")


def main() -> None:
    args = docopt(__doc__)
    first = args["--first"].upper()
    fmt = args["--format"].lower()

    if args["--demo"]:
        deals = [_demo_deal(first)]
    else:
        from hand_ocr.pipeline import image_to_deals  # lazy: needs vision extras

        deals = image_to_deals(args["<image>"], first=first)  # one per board found

    exit_code = 0
    blocks = []
    for i, deal in enumerate(deals):
        try:
            deal.validate()
            blocks.append(_emit(deal, fmt))
        except DealError as e:
            label = f"deal {i + 1}" if len(deals) > 1 else "deal"
            print(f"invalid {label} (flag for manual fix): {e}", file=sys.stderr)
            exit_code = 2
    if blocks:
        # blank line between PBN tag blocks; LIN lines just stack
        sep = "\n\n" if fmt == "pbn" else "\n"
        print(sep.join(blocks))
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()
