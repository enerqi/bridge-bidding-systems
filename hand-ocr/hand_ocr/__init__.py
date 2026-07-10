"""hand_ocr: bridge hand-diagram image -> PBN/LIN deal text.

Public surface is the model layer (always importable) plus the pipeline entry
point (needs the vision extras). See README.md.
"""

from __future__ import annotations

from .model import Deal, DealError, Hand

__all__ = ["Deal", "DealError", "Hand"]
