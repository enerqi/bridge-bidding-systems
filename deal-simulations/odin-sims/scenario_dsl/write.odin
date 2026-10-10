package scenario_dsl

/*
	write.odin — a `Program` back to its own source text.

	WHY A PARSER NEEDS AN UNPARSER HERE. Two callers, and neither is a nicety:

	  * THE EDITOR'S CHECK PANEL. Pressing `check` has to say what the parse actually understood, and
	    the honest answer to that is the canonical text of the tree — `hcp in 8..11` where the file said
	    `hcp >= 8 and hcp <= 11`, and the parentheses where the precedence put them rather than where
	    they were typed. A summary in prose would be a second description of the language, drifting.
	  * THE ROUND TRIP, which is a test that no other test can be. `parse -> write -> parse` must reach
	    the same tree, and that fails loudly for a whole class of parser bug a hand-written case would
	    have to be lucky to catch (precedence read one way and printed another, a range whose bounds
	    swap, an operator spelled differently on the two sides).

	MINIMAL PARENTHESES, and they are computed rather than remembered: the tree does not record where
	the author put brackets, so this prints the ones the SHAPE needs — `or` under `and`, and either
	under `not`. What comes back is therefore not the file byte for byte, and it is not meant to be. It
	is what the file MEANT, spelled one way.
*/

import "core:strings"
import "norn:norn"

/*
The canonical source of one scenario: its header, its tags and one line per seat.

Indented two spaces, the spelling the parser's own examples use and the one a file written by this
editor will have. Seats come out in the order the file declared them, because that order is an
author's ordering ("opener, then responder") and re-sorting it would be this code having an opinion.
*/
write_program :: proc(program: ^Program, allocator := context.allocator) -> string {
	b := strings.builder_make(0, 256, allocator)
	write_program_into(&b, program)
	return strings.to_string(b)
}

write_program_into :: proc(b: ^strings.Builder, program: ^Program) {
	strings.write_string(b, "scenario ")
	strings.write_string(b, program.name)
	if program.description != "" {
		strings.write_string(b, ` "`)
		strings.write_string(b, program.description)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, '\n')

	if len(program.tags) > 0 {
		strings.write_string(b, "  tags: ")
		for tag, i in program.tags {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, tag)
		}
		strings.write_byte(b, '\n')
	}

	if dd, has := program.double_dummy.?; has {
		strings.write_string(b, "  double-dummy: ")
		strings.write_string(b, "north-south" if dd.side == .North_South else "east-west")
		strings.write_string(b, " make ")
		switch dd.goal {
		case .Game:
			strings.write_string(b, "game")
		case .Slam:
			strings.write_string(b, "slam")
		case .Grand:
			strings.write_string(b, "grand")
		}
		strings.write_byte(b, '\n')
	}

	for rule in program.rules {
		strings.write_string(b, "  ")
		strings.write_string(b, pair_word(rule.seat) if rule.pair else seat_word(rule.seat))
		strings.write_string(b, ": ")
		write_node(b, program, rule.root, .Top)
		strings.write_byte(b, '\n')
	}
}

// Where a node is being printed, which is all "does this need brackets" depends on. `Top` and `Or` are
// separate because an `or` directly under an `or` needs none while one under an `and` does.
@(private)
Level :: enum {
	Top,
	Or,
	And,
	Not,
}

@(private)
write_node :: proc(b: ^strings.Builder, program: ^Program, index: int, level: Level) {
	if index < 0 || index >= len(program.nodes) {
		// Only a malformed tree reaches here and the parser does not build one; printing the word is
		// better than printing nothing, which would read as an empty condition that matches everything.
		strings.write_string(b, "<broken>")
		return
	}
	switch node in program.nodes[index] {
	case Compare_Node:
		write_compare(b, node)

	case Named_Node:
		strings.write_string(b, node.name)

	case Holds_Node:
		strings.write_string(b, "holds(")
		strings.write_string(b, suit_word(node.suit))
		strings.write_string(b, ", ")
		strings.write_string(b, rank_word(node.rank))
		strings.write_byte(b, ')')

	case Balanced_Node:
		strings.write_string(b, "balanced")

	case Not_Node:
		strings.write_string(b, "not ")
		write_node(b, program, node.child, .Not)

	case And_Node:
		bracket := level == .Not
		if bracket {
			strings.write_byte(b, '(')
		}
		write_node(b, program, node.left, .And)
		strings.write_string(b, " and ")
		write_node(b, program, node.right, .And)
		if bracket {
			strings.write_byte(b, ')')
		}

	case Or_Node:
		bracket := level == .And || level == .Not
		if bracket {
			strings.write_byte(b, '(')
		}
		write_node(b, program, node.left, .Or)
		strings.write_string(b, " or ")
		write_node(b, program, node.right, .Or)
		if bracket {
			strings.write_byte(b, ')')
		}
	}
}

@(private)
write_compare :: proc(b: ^strings.Builder, node: Compare_Node) {
	strings.write_string(b, quantity_word(node.quantity))
	if node.is_range {
		strings.write_string(b, " in ")
		strings.write_int(b, node.value)
		strings.write_string(b, "..")
		strings.write_int(b, node.high)
		return
	}
	strings.write_byte(b, ' ')
	strings.write_string(b, comparison_word(node.op))
	strings.write_byte(b, ' ')
	strings.write_int(b, node.value)
}

// ---------------------------------------------------------------------------------------------------
// The words, the other way round
//
// The reading direction lives in `dsl.odin` (`quantity_of`, `seat_of`, `suit_of`, `rank_of`). These are
// their inverses, and they are exhaustive switches on purpose: a member added to any of those enums
// stops this compiling rather than printing an empty string into somebody's scenario file.

@(private)
quantity_word :: proc(quantity: Quantity) -> string {
	switch quantity {
	case .Hcp:
		return "hcp"
	case .Controls:
		return "controls"
	case .Spades:
		return "spades"
	case .Hearts:
		return "hearts"
	case .Diamonds:
		return "diamonds"
	case .Clubs:
		return "clubs"
	case .Longest:
		return "longest"
	}
	return "hcp"
}

@(private)
comparison_word :: proc(op: Comparison) -> string {
	switch op {
	case .Less:
		return "<"
	case .Less_Equal:
		return "<="
	case .Equal:
		return "="
	case .Not_Equal:
		return "!="
	case .Greater_Equal:
		return ">="
	case .Greater:
		return ">"
	}
	return "="
}

seat_word :: proc(seat: norn.Seat) -> string {
	switch seat {
	case .North:
		return "north"
	case .East:
		return "east"
	case .South:
		return "south"
	case .West:
		return "west"
	}
	return "north"
}

// The inverse of `pair_of`: a side is named from the seat that starts it, and either seat names it.
pair_word :: proc(seat: norn.Seat) -> string {
	switch seat {
	case .North, .South:
		return "north-south"
	case .East, .West:
		return "east-west"
	}
	return "north-south"
}

@(private)
suit_word :: proc(suit: norn.Suit) -> string {
	switch suit {
	case .Clubs:
		return "clubs"
	case .Diamonds:
		return "diamonds"
	case .Hearts:
		return "hearts"
	case .Spades:
		return "spades"
	}
	return "spades"
}

@(private)
rank_word :: proc(rank: norn.Rank) -> string {
	switch rank {
	case .Two:
		return "two"
	case .Three:
		return "three"
	case .Four:
		return "four"
	case .Five:
		return "five"
	case .Six:
		return "six"
	case .Seven:
		return "seven"
	case .Eight:
		return "eight"
	case .Nine:
		return "nine"
	case .Ten:
		return "ten"
	case .Jack:
		return "jack"
	case .Queen:
		return "queen"
	case .King:
		return "king"
	case .Ace:
		return "ace"
	}
	return "ace"
}
