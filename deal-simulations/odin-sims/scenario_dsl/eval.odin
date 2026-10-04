package scenario_dsl

/*
	eval.odin — walking a parsed `Program` against a deal.

	THIS IS THE PROC THAT NEEDED `userdata`. Odin procs do not capture, so `evaluate` cannot be a
	`norn.Predicate`: it has to be told WHICH program to walk. That is exactly what
	`norn.Interpreted_Predicate` carries — the walker plus its tree — and why `norn.Condition` is a union
	rather than a proc pointer (see `cli/scenario.odin`).

	COST. A seat rule is a handful of nodes and the arena is contiguous, so a walk is a switch over a few
	array elements — nanoseconds against a deal shuffle plus a summarise. The plan predicted this would be
	a non-issue and said to measure rather than assume; `--frequency` on an interpreted scenario is the
	measurement, and it is the same number a compiled one reports.

	NO ALLOCATION and NO CONTEXT USE in the hot path: `evaluate` reads the tree and the summary and
	nothing else, which is what makes it safe to hand the same program to every worker thread.
*/

import "norn:norn"

/*
The `norn.Contextual_Predicate` for a program. Pair it with the program itself:

	condition := norn.Interpreted_Predicate{scenario_dsl.evaluate, program}

Seat rules AND together — the compiled registry's `&&` between "North opens" and "South responds", said
in the grammar instead of in Odin.
*/
evaluate :: proc(summary: norn.Deal_Summary, userdata: rawptr) -> bool {
	program := (^Program)(userdata)
	if program == nil {
		return false
	}
	for rule in program.rules {
		// A partnership line reads its two hands as one — see `combined` for why that is exact.
		hand := summary[rule.seat]
		if rule.pair {
			hand = combined(hand, summary[partner_of(rule.seat)])
		}
		if !eval_node(program, rule.root, hand) {
			return false
		}
	}
	return true
}

/*
One node against one hand.

An out-of-range index is FALSE rather than a crash. Only a malformed tree produces one and the parser
does not emit malformed trees — but this runs a million times inside a generate loop on a worker thread,
and "reject the deal" is a better answer there than taking the process down.
*/
@(private)
eval_node :: proc(program: ^Program, index: int, hand: norn.Hand_Summary) -> bool {
	if index < 0 || index >= len(program.nodes) {
		return false
	}
	switch node in program.nodes[index] {
	case Compare_Node:
		return compare(node, quantity_value(node.quantity, hand))

	case Named_Node:
		// Resolved at parse time, but the table could in principle have been swapped since; a name that
		// no longer resolves rejects rather than indexing out of bounds.
		vocabulary := g_vocabulary
		if node.index < 0 || node.index >= len(vocabulary) {
			return false
		}
		entry := vocabulary[node.index]
		return entry.call != nil && entry.call(hand)

	case Holds_Node:
		return norn.holds(hand, node.suit, node.rank)

	case Balanced_Node:
		return norn.is_balanced(hand)

	case Not_Node:
		return !eval_node(program, node.child, hand)

	case And_Node:
		return eval_node(program, node.left, hand) && eval_node(program, node.right, hand)

	case Or_Node:
		return eval_node(program, node.left, hand) || eval_node(program, node.right, hand)
	}
	return false
}

@(private)
quantity_value :: proc(quantity: Quantity, hand: norn.Hand_Summary) -> int {
	switch quantity {
	case .Hcp:
		return norn.hcp(hand)
	case .Controls:
		return norn.controls(hand)
	case .Spades:
		return norn.suit_length(hand, .Spades)
	case .Hearts:
		return norn.suit_length(hand, .Hearts)
	case .Diamonds:
		return norn.suit_length(hand, .Diamonds)
	case .Clubs:
		return norn.suit_length(hand, .Clubs)
	case .Longest:
		longest := 0
		for suit in norn.Suit {
			longest = max(longest, norn.suit_length(hand, suit))
		}
		return longest
	}
	return 0
}

@(private)
compare :: proc(node: Compare_Node, value: int) -> bool {
	if node.is_range {
		return value >= node.value && value <= node.high
	}
	switch node.op {
	case .Less:
		return value < node.value
	case .Less_Equal:
		return value <= node.value
	case .Equal:
		return value == node.value
	case .Not_Equal:
		return value != node.value
	case .Greater_Equal:
		return value >= node.value
	case .Greater:
		return value > node.value
	}
	return false
}
