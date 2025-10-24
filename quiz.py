from dataclasses import dataclass
from enum import Enum
from os import environ
from os.path import join, expanduser
import random
import re
import sys
from typing import Callable, Iterator, List, NewType, Optional

from panel.widgets import MultiChoice

Path = NewType("Path", str)
home = Path(expanduser("~"))
bml_tools_dir = Path(environ.get("BML_TOOLS_DIRECTORY", join(home, "dev/bml")))
sys.path.append(bml_tools_dir)

import bml

ProcessBidNodeFunc = Callable[[bml.Node, int], None]


def load_bid_tables(bml_file_path: str) -> list[bml.Node]:
    bml.content_from_file(bml_file_path)

    # also keep stack of tree position? H1, H2, H3, H4
    # include file dumps into same translation unit
    # H1 then H2 implies nested
    # H1 then H2 then H1 implies exited scope of other H1 or lower headings
    #
    # parsing the header data is an extra step, e.g. if in an H2 then does the title
    # have any relevance?
    # 1C opening, 1C--1D, is any of 1c 1d in the bidtable

    bid_tables = [
        content
        for (content_type, content) in bml.content
        if content_type == bml.ContentType.BIDTABLE
    ]
    return bid_tables


def bid_table_dfs(node: bml.Node, node_visit_func: ProcessBidNodeFunc, depth=0):
    node_visit_func(node, depth)
    if node.children:
        for child in node.children:
            bid_table_dfs(child, node_visit_func, depth=depth + 1)


def show_bid_table_nodes(tables: list[bml.Node]):
    def show_node(node, depth):
        if node.desc == "root":
            return
        print("    " * depth, node.bid, node.desc)

    for table in tables:
        bid_table_dfs(table, show_node)


def prettify_bid_table_nodes(tables: list[bml.Node]):
    def do_prettify_bidrep(bml_node, _depth):
        # extra tidy, maybe write our own get_sequence so mess less with bidrepr
        bml_node.bidrepr = re.sub(r"([A-Za-z])\(", r"\1 (", bml_node.bidrepr)
        bml_node.bidrepr = re.sub(r"\)(\d[A-Za-z])", r") \1", bml_node.bidrepr)
        bml_node.bidrepr = re.sub(r"(\s)P(\s)", r"\1Pass\2", bml_node.bidrepr)
        bml_node.bidrepr = bml_node.bidrepr.replace("(P)", "(Pass)")
        bml_node.bidrepr = bml_node.bidrepr.replace(")P", ") Pass")
        bml_node.bidrepr = bml_node.bidrepr.replace(")X", ") X")
        bml_node.bidrepr = bml_node.bidrepr.replace("--", " ")
        # bml_node.bidrepr = bml_node.bidrepr.replace("!c", "C")
        # bml_node.bidrepr = bml_node.bidrepr.replace("!d", "D")
        # bml_node.bidrepr = bml_node.bidrepr.replace("!h", "H")
        # bml_node.bidrepr = bml_node.bidrepr.replace("!s", "S")

    for table in tables:
        bid_table_dfs(table, do_prettify_bidrep)


@dataclass
class BidSequenceMeaning:
    sequence: list[str]
    description: str


def collect_bid_table_auctions(tables: list[bml.Node]) -> list[BidSequenceMeaning]:
    """Includes all sequences in a tree branch, not just tree leaves"""
    sequences = []

    def collect_auctions(node, depth):
        if node.desc == "root":
            return
        sequences.append(
            BidSequenceMeaning(sequence=node.get_sequence(), description=node.desc)
        )

    for table in tables:
        bid_table_dfs(table, collect_auctions)

    return sequences


# maybe remove, easier for end users to manipulate
def prettify_description(bml_text: str):
    bml_text = bml_text.strip()
    bml_text = bml_text.replace("!c", "C")
    bml_text = bml_text.replace("!d", "D")
    bml_text = bml_text.replace("!h", "H")
    bml_text = bml_text.replace("!s", "S")
    return bml_text


def show_all_auctions(bid_seqs: list[BidSequenceMeaning]):
    for seq in bid_seqs:
        print(" --> ".join(seq.sequence), seq.description)


class MultiChoiceType(Enum):
    Auctions = "Auctions"
    Descriptions = "Descriptions"


@dataclass
class Question:
    candidates: list[str]
    answer: str
    answer_candidate: str
    choice_type: MultiChoiceType


def random_multi_choice_type() -> MultiChoiceType:
    if bool(random.getrandbits(1)):
        return MultiChoiceType.Auctions
    else:
        return MultiChoiceType.Descriptions

def generate_question(
    bid_sequences: list[BidSequenceMeaning], multi_choice_count: int = 5,
    choice_type: MultiChoiceType = MultiChoiceType.Auctions
) -> Question:

    answer_index = random.randint(0, multi_choice_count - 1)  # e.g. 0-4
    answer = ""
    answer_candidate = ""
    pretty_descriptions = set()
    candidates = []

    if choice_type == MultiChoiceType.Auctions:
        for question_index in range(multi_choice_count):  # e.g. 0-4
            # Do not want multiple identical answers
            while True:
                index = random.randint(0, len(bid_sequences) - 1)
                rand_seq = bid_sequences[index]
                auction, description = rand_seq.sequence, rand_seq.description
                pretty_description = prettify_description(description)

                # some auction sequences, some preludes do not have descriptions
                if (
                    pretty_description.strip()
                    and pretty_description not in pretty_descriptions
                ):
                    break

            pretty_descriptions.add(pretty_description)

            question_auction = " --> ".join(auction)

            if question_index == answer_index:
                answer = pretty_description
                answer_candidate = question_auction

            candidates.append(question_auction)

        return Question(
            candidates=candidates,
            answer=answer,
            answer_candidate=answer_candidate,
            choice_type=choice_type,
        )
    else:
        for question_index in range(multi_choice_count):
            # Do not want multiple identical answers
            while True:
                index = random.randint(0, len(bid_sequences) - 1)
                rand_seq = bid_sequences[index]
                auction, description = rand_seq.sequence, rand_seq.description
                pretty_description = prettify_description(description)

                # some auction sequences, some preludes do not have descriptions
                if (
                    pretty_description.strip()
                    and pretty_description not in pretty_descriptions
                ):
                    break  # unique description

            pretty_descriptions.add(pretty_description)

            question_auction = " --> ".join(auction)

            if question_index == answer_index:
                answer_candidate = pretty_description  # the explanation text
                answer = question_auction

            candidates.append(pretty_description)

        return Question(
            candidates=candidates,
            answer=answer,
            answer_candidate=answer_candidate,
            choice_type=choice_type,
        )


if __name__ == "__main__":
    bid_tables = load_bid_tables("squad-system.bml")
    prettify_bid_table_nodes(bid_tables)
    bid_sequences = collect_bid_table_auctions(bid_tables)
    show_bid_table_nodes(bid_tables)

    print("Distinct auctions count: ", len(bid_sequences), "\n")

    question = generate_question(bid_sequences)
    for auction in question.candidates:
        print(auction + "\n")
    print("which matches the description:\n" + question.answer)

    show_all_auctions(bid_sequences)
