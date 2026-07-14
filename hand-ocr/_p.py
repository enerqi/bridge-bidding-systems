import cv2, sys
sys.path.insert(0,"tools")
from hand_ocr.segment import find_card_cells, cluster_hands
from build_cards_atlas import _reading_order, _split_ranks, LABELLED_HANDS
bgr=cv2.imread("fixtures/intobridge-4-hand-large.png")
cl={c.seat:c for c in cluster_hands(bgr,find_card_cells(bgr))}
lab=LABELLED_HANDS["intobridge-4-hand-large"]
cells=_reading_order(cl["N"].cells); ranks=_split_ranks(lab["N"][0])
i=0
for cell,r in zip(cells,ranks):
    if r=="K":
        cv2.imwrite(f"_K_{i}.png", cell.index_image); i+=1
