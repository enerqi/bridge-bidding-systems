from copy import deepcopy
from dataclasses import dataclass
from enum import Enum
import functools
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
HeaderBiddingContext = list[tuple[bml.ContentType, str]]


def load_bid_tables(
    bml_file_path: str,
) -> tuple[list[bml.Node], list[HeaderBiddingContext]]:
    bml.content_from_file(bml_file_path)
    content = deepcopy(bml.content)

    tables = []
    doc_hierarchy_contexts: list[HeaderBiddingContext] = []
    current_context_tree: HeaderBiddingContext = []

    def pop_header_context(new_header_content_type: bml.ContentType):
        nonlocal current_context_tree
        if current_context_tree:
            last_content_type = current_context_tree[-1][0]
            if new_header_content_type <= last_content_type:  # H1 < H2 < H3 < H4
                # either we have moved up the tree or gone to a sibling
                current_context_tree.pop()
                pop_header_context(new_header_content_type)

    for content_type, content in content:
        if content_type in (
            bml.ContentType.H4,
            bml.ContentType.H3,
            bml.ContentType.H2,
            bml.ContentType.H1,
        ):
            pop_header_context(content_type)
            current_context_tree.append((content_type, content))

        if content_type == bml.ContentType.BIDTABLE:
            tables.append(content)
            doc_hierarchy_contexts.append(deepcopy(current_context_tree))

    return tables, doc_hierarchy_contexts


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


bid_regex = re.compile(r"\(?[1-7][CDHSN]\)?$")
multi_bid_regex = re.compile(r"\(?[1-7][CDHSN]+\)?$")
separator_bid_regex = re.compile(
    r"\-\(?[1-7][CDHSN]\)?"
)  # without $ we allow e.g. 1C--1HS
prefix_separator_bid_regex = re.compile(r"\(?[1-7][CDHSN]\)?\-")


def parse_header_context_to_bid_prelude(
    header_context: HeaderBiddingContext,
) -> list[str]:
    header_bids = []

    for header in header_context:
        _type, header_text = header

        # print(header_text)

        look = False
        if "1C--1HS" in header_text:
            look = True
            look = False

        # 1) what about 4CDHS, 3CDHS etc., 2HS
        # if prelude is multiple 4CDHS, then ignore?
        #
        # 2) "opps open 2d or 2h", then prelude is wrong 2d 2h, just potentially wrong
        # maybe ignore all preludes without "-" bids, but then "2d enquiry"??? it does have sub bids
        #
        # 3) "opps open 1S" should really be (1S) not just "1S", so ignoring
        #
        # MVP: only support headers with "-"...
        # not want e.g. "Good-Bad"
        if look:
            print(header_text)
        if "-" in header_text and (
            re.search(separator_bid_regex, header_text)
            or re.search(prefix_separator_bid_regex, header_text)
        ):
            norm = header_text.strip().upper()
            norm = norm.replace("-", " ")
            norm = norm.replace("/", " ")
            norm = norm.replace("NT", "N")
            parts = norm.split()

            if look:
                print(norm)
                print(parts)

            for part in parts:
                # so what about matching 1HS?
                # diff regex to capture 1HS
                # but then need later `missing_context` to account for 1HS being 1H or 1S
                if re.match(bid_regex, part) or re.match(multi_bid_regex, part):
                    # in theory there could be bidding context information overlap been different headers
                    # e.g 1D and 1D--1S
                    if part not in header_bids:
                        header_bids.append(part)
        else:
            if look:
                print("not checking out")

    if look:
        print(header_bids)

    return header_bids


def collect_bid_table_auctions(
    tables: list[bml.Node], header_contexts: list[HeaderBiddingContext]
) -> list[BidSequenceMeaning]:
    """Includes all sequences in a tree branch, not just tree leaves"""
    sequences = []

    def collect_auctions(node, depth, header_context):
        if node.desc == "root":
            return

        context_bids = parse_header_context_to_bid_prelude(header_context)

        next_sequence = BidSequenceMeaning(
            sequence=node.get_sequence(), description=node.desc
        )
        sequences.append(next_sequence)

        # WARN: what if bid table says e.g 4HS, then hard to match against a prelude of 4H or 4S
        missing_context = []
        for bid in context_bids:
            # MVP assuming that multi_bid_regex e.g 4HS will not be in the sequence
            if not any(bid in sequence_bid for sequence_bid in next_sequence.sequence):
                missing_context.append(bid)
        if missing_context:
            # print(context_bids, next_sequence)
            new_next_sequence = missing_context + next_sequence.sequence
            # print(f"updating sequence, initial: {next_sequence.sequence}, new: {new_next_sequence}")
            next_sequence.sequence = new_next_sequence

    for table, context in zip(tables, header_contexts):
        bid_table_dfs(
            table, functools.partial(collect_auctions, header_context=context)
        )

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
    bid_sequences: list[BidSequenceMeaning],
    multi_choice_count: int = 5,
    choice_type: MultiChoiceType = MultiChoiceType.Auctions,
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
    # bid_tables, header_contexts = load_bid_tables("squad-system.bml")
    bid_tables, header_contexts = load_bid_tables("bidding-system.bml")
    prettify_bid_table_nodes(bid_tables)
    bid_sequences = collect_bid_table_auctions(bid_tables, header_contexts)

    show_bid_table_nodes(bid_tables)

    print("Distinct auctions count: ", len(bid_sequences), "\n")

    question = generate_question(bid_sequences)
    for candidate in question.candidates:
        print(candidate + "\n")
    print("which candidate fits the answer...\n" + question.answer)

    show_all_auctions(bid_sequences)
