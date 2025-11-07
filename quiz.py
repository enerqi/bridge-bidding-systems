from copy import deepcopy
from dataclasses import dataclass
from enum import Enum
import functools
from os import environ
from os.path import join, expanduser
from pprint import pprint
import random
import re
import sys
from typing import Callable, NewType

Path = NewType("Path", str)
home = Path(expanduser("~"))
bml_tools_dir = Path(environ.get("BML_TOOLS_DIRECTORY", join(home, "dev/bml")))
sys.path.append(bml_tools_dir)

import bml  # noqa: E402

ProcessBidNodeFunc = Callable[[bml.Node, int], None]


@dataclass
class Header:
    content_type: bml.ContentType
    text: str


@dataclass
class BidTable:
    tree_root: bml.Node
    headers_context: list[Header]


def load_bid_tables(
    bml_file_path: str,
) -> list[BidTable]:
    bml.content_from_file(bml_file_path)
    # this could be other things than nodes or strings, but we only extract tables and headers
    content: list[tuple[bml.ContentType, bml.Node | str]] = deepcopy(bml.content)

    tables: list[BidTable] = []
    current_context_tree: list[Header] = []

    def pop_to_new_header_context(new_header_content_type: bml.ContentType):
        nonlocal current_context_tree
        if current_context_tree:
            last_content_type = current_context_tree[-1].content_type
            if new_header_content_type <= last_content_type:  # H1 < H2 < H3 < H4
                # either we have moved up the tree or gone to a sibling
                current_context_tree.pop()
                pop_to_new_header_context(new_header_content_type)

    for content_type, content in content:
        if content_type in (
            bml.ContentType.H1,
            bml.ContentType.H2,
            bml.ContentType.H3,
            bml.ContentType.H4,
        ):
            pop_to_new_header_context(content_type)
            assert isinstance(content, str)
            current_context_tree.append(Header(content_type=content_type, text=content))

        if content_type == bml.ContentType.BIDTABLE:
            tables.append(BidTable(tree_root=content, headers_context=deepcopy(current_context_tree)))

    return tables


def bid_table_dfs(table: BidTable, node_visit_func: ProcessBidNodeFunc, depth=0):
    node = table.tree_root
    node_dfs(node, node_visit_func)


def node_dfs(node: bml.Node, node_visit_func: ProcessBidNodeFunc, depth=0):
    node_visit_func(node, depth)
    if node.children:
        for child in node.children:
            node_dfs(child, node_visit_func, depth=depth + 1)


def show_bid_table_nodes(tables: list[BidTable], show_table_context: bool):
    def show_node(node, depth):
        if node.desc == "root":
            return
        print("    " * depth, node.bid, node.desc)

    for table in tables:
        if show_table_context:
            print(f"\n### Context: {table.headers_context}\n")
        bid_table_dfs(table, show_node)


def prettify_bid_table_nodes(tables: list[BidTable]):
    def do_prettify_bidrep(table_node: bml.Node, _depth):
        table_bidrepr = table_node.bidrepr

        # extra tidy, maybe write our own get_sequence so mess less with bidrepr
        table_bidrepr = re.sub(r"([A-Za-z])\(", r"\1 (", table_bidrepr)  # put space before letter then "("
        table_bidrepr = re.sub(r"\)(\d[A-Za-z])", r") \1", table_bidrepr)  # put space after ")" then digit letter
        table_bidrepr = re.sub(r"(\s)P(\s)", r"\1Pass\2", table_bidrepr)  # whitespace around P then P becomes Pass
        table_bidrepr = table_bidrepr.replace("(P)", "(Pass)")  # opposition pass pretty
        table_bidrepr = table_bidrepr.replace(")P", ") Pass")
        table_bidrepr = table_bidrepr.replace(")X", ") X")
        table_bidrepr = table_bidrepr.replace("--", " ")
        # table_bidrepr = table_bidrepr.replace("!c", "C")
        # table_bidrepr = table_bidrepr.replace("!d", "D")
        # table_bidrepr = table_bidrepr.replace("!h", "H")
        # table_bidrepr = table_bidrepr.replace("!s", "S")

        table_node.bidrepr = table_bidrepr

    for table in tables:
        bid_table_dfs(table, do_prettify_bidrep)


@dataclass
class BidSequenceMeaning:
    sequence: list[str]
    description: str
    _debug_headers_context: list[Header]
    _parsed_context_bids: list[str]
    _initial_sequence: list[str]


bid_regex = re.compile(r"\(?[1-7][CDHSN]\)?$")
multi_bid_regex = re.compile(r"\(?[1-7][CDHSN]+\)?$")
separator_bid_regex = re.compile(r"\-\(?[1-7][CDHSN]\)?")  # without $ we allow e.g. 1C--1HS
prefix_separator_bid_regex = re.compile(r"\(?[1-7][CDHSN]\)?\-")


def parse_bids_from_headers(header_context: list[Header], debug: bool = False) -> list[str]:
    header_bids = []

    for header in header_context:
        header_text = header.text

        # print(header_text)

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
        if debug:
            print(header_text)

        if "-" in header_text and (
            re.search(separator_bid_regex, header_text) or re.search(prefix_separator_bid_regex, header_text)
        ):
            norm = header_text.strip().upper()
            norm = norm.replace("-", " ")
            norm = norm.replace("/", " ")
            norm = norm.replace("NT", "N")
            parts = norm.split()

            if debug:
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
            if debug:
                print("not checking out")

    if debug:
        print(header_bids)
        print(header_context, header_bids)

    return header_bids


# todo? maybe the best place to turn the table into domain typed bids instead of strings
def collect_bid_table_auctions(bid_tables: list[BidTable], debug: bool = False) -> list[BidSequenceMeaning]:
    """Includes all sequences in a tree branch, not just tree leaves"""
    sequences: list[BidSequenceMeaning] = []

    unique_contexts_to_examples = {}

    def collect_auctions(node: bml.Node, depth: int, headers_context: list[Header]):
        if node.desc == "root":
            return

        # partially cleaned up but still has alternate bids e.g. "4HS"
        # may not parse opponents bidding sections, they normally have full context anyway
        # e.g. "(1H)"
        context_bids = parse_bids_from_headers(headers_context)

        # still a mess of multi bid / alternate bid strings of course
        initial_sequence = node.get_sequence()
        next_sequence = BidSequenceMeaning(
            sequence=initial_sequence,
            description=node.desc,
            _debug_headers_context=headers_context,
            _parsed_context_bids=context_bids,
            _initial_sequence=initial_sequence,
        )
        sequences.append(next_sequence)

        if debug:
            hashable_context = tuple(context_bids)
            if hashable_context not in unique_contexts_to_examples:
                unique_contexts_to_examples[hashable_context] = (
                    tuple(next_sequence.sequence),
                    next_sequence.description,
                )

        # if any("1N--2D/2H" in context[1] for context in header_context):
        #     print(context_bids)
        #     print(next_sequence)

        # ah, so header is 1n-2d/2h so OR, and actual table only has one of them
        # need to check if missing bid is actually lower than the first bid
        # next_sequence.sequence[0] string, which could be multiple, parse it and is it less...
        #
        # but what about header "1C/1D" then 1C--1S as 1D is missing, ok
        # but 1D--1S then arguably 1C is in context and lower

        # WARN: what if bid table says e.g 4HS, then hard to match against a prelude of 4H or 4S

        missing_context = []
        for bid in context_bids:
            # MVP assuming that multi_bid_regex e.g 4HS will not be in the sequence
            if not any(bid in sequence_bid for sequence_bid in next_sequence.sequence):
                # if any("1N--2D/2H" in context[1] for context in header_context):
                #     print("missing:", bid, "context bids: ", context_bids, "next seq:", next_sequence)
                missing_context.append(bid)

        if missing_context:
            # print("MISSING", missing_context)
            # but, is the missing_context actually less than the start of the next sequence
            seq_bids = parse_individual_bids(next_sequence.sequence)
            if seq_bids:
                first_bid = seq_bids[0]
                missing_context_bids = parse_individual_bids(missing_context)
                # print(seq_bids, context_bids)

                actually_missing_context = [
                    context_bid for context_bid in missing_context_bids if bid_less_than(context_bid, first_bid)
                ]

                if actually_missing_context:
                    new_next_sequence = actually_missing_context + next_sequence.sequence
                    # print("ACTUALLY, ", actually_missing_context, next_sequence)
                    if debug:
                        print(f"updating sequence, initial: {next_sequence.sequence}, new: {new_next_sequence}")
                    next_sequence.sequence = new_next_sequence
            else:
                # TODO: may want to fix to parse e.g. "4CD = ...", e.g. 1C in header, then 4CD = GF, minorwood in table
                new_next_sequence = missing_context + next_sequence.sequence
                if debug:
                    print(f"updating unparseable sequence, initial: {next_sequence.sequence}, new: {new_next_sequence}")
                next_sequence.sequence = new_next_sequence

    for table in bid_tables:
        bid_table_dfs(table, functools.partial(collect_auctions, headers_context=table.headers_context))

    if debug:
        print("Unique contexts:")
        pprint(unique_contexts_to_examples)
    return sequences


def parse_individual_bids(bid_strings: list[str]) -> list[str]:
    # list of "1h pass 2h", or just "2S" etc.
    bids = []
    for bid_str in bid_strings:
        parts = bid_str.split()
        for part in parts:
            if re.match(bid_regex, part):
                bids.append(part)

    return bids


def test_parse_individual_bids():
    simple_bids = ["2H", "(4H)", "5C"]
    parsed = parse_individual_bids(simple_bids)
    assert parsed == simple_bids

    compound = ["1H (pass) 2S", "3C"]
    parsed_compound = parse_individual_bids(compound)
    assert parsed_compound == ["1H", "2S", "3C"]


bid_level_regex = re.compile(r"(\d)")
bid_suit_regex = re.compile(r"[1-7]([CDHSN])")
ranks = {
    "C": 1,
    "D": 2,
    "H": 3,
    "S": 4,
}


def bid_less_than(b1: str, b2: str) -> bool:
    try:
        n1 = re.search(bid_level_regex, b1)[0]
        n2 = re.search(bid_level_regex, b2)[0]
        if n1 < n2:
            return True

        if n1 == n2:
            suit1 = re.search(bid_suit_regex, b1)[1]
            suit2 = re.search(bid_suit_regex, b2)[1]
            return ranks.get(suit1, 5) < ranks.get(suit2, 5)
        else:
            return False
    except Exception:
        print("logic needs fixing...")
        return False


def test_bid_less_than():
    assert bid_less_than("1H", "2H")
    assert bid_less_than("(1H)", "2H")
    assert bid_less_than("(1H)", "2C")
    assert bid_less_than("1H", "2C")
    assert not bid_less_than("1N", "1S")
    assert not bid_less_than("7C", "1S")
    assert bid_less_than("7C", "7NT")


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
    _debug_bid_sequences: list[BidSequenceMeaning]


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
    _debug_bid_sequences = []

    if choice_type == MultiChoiceType.Auctions:
        for question_index in range(multi_choice_count):  # e.g. 0-4
            # Do not want multiple identical answers
            while True:
                index = random.randint(0, len(bid_sequences) - 1)
                rand_seq = bid_sequences[index]
                auction, description = rand_seq.sequence, rand_seq.description
                pretty_description = prettify_description(description)

                # some auction sequences, some preludes do not have descriptions
                if pretty_description.strip() and pretty_description not in pretty_descriptions:
                    _debug_bid_sequences.append(rand_seq)
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
            _debug_bid_sequences=_debug_bid_sequences,
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
                if pretty_description.strip() and pretty_description not in pretty_descriptions:
                    _debug_bid_sequences.append(rand_seq)
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
            _debug_bid_sequences=_debug_bid_sequences,
        )


def show_bid_table_sequences(tables: list[BidTable], show_table_context: bool):
    def show_node(node, depth):
        if node.desc == "root":
            return
        print(node.get_sequence())

    for table in tables:
        if show_table_context:
            print(f"\n### Context: {table.headers_context}\n")
        bid_table_dfs(table, show_node)


if __name__ == "__main__":
    # bid_tables, header_contexts = load_bid_tables("squad-system.bml")
    bid_tables = load_bid_tables("bidding-system.bml")
    prettify_bid_table_nodes(bid_tables)
    # pprint(bid_tables)  just a node plus headers

    # still a mess of strings:
    # - single or multi bid strings, with a list of strings, e.g. 2H vs "2HS (P) 2N"
    # - single or alternate auction paths, e.g. 2H vs 2HS
    # show_bid_table_sequences(bid_tables, show_table_context=True)

    bid_sequences = collect_bid_table_auctions(bid_tables, debug=False)
    pprint(bid_sequences)
    # show_bid_table_nodes(bid_tables, show_table_context=True)

    print("Distinct auctions count: ", len(bid_sequences), "\n")

    question = generate_question(bid_sequences)
    # for candidate in question.candidates:
    #     print(candidate + "\n")
    # print("which candidate fits the answer...\n" + question.answer)

    # show_all_auctions(bid_sequences)
