package deal_solve

/*
	play_cost — what each card of a recorded play cost, double dummy.

	A record's play (`norn.Play`, read from LIN `pc|` or PBN `[Play]`) says what was played; this says what
	it was WORTH. Before every card the position is solved for every legal card, so for each card played we
	know the declaring side's double-dummy total from there on, whether the card dropped a trick against the
	best card available, and which cards were best. That is what makes a replay instructive rather than a
	slideshow: "trick 3, East's ♦6 cost a trick — the ♦K kept it".

	One position per card, all solved in ONE batched call (`SolveAllBoardsBin`, which spreads them over DDS's
	threads) — a whole board is at most 52 positions, under the batch's 200. Mode `.Auto`, not the
	`.Auto_Skip_Single` used elsewhere: skipping leaves a forced card's score unset (-2), and a forced card
	is still a position whose value the trajectory needs.

	Numbers are always the DECLARING side's total tricks for the board (tricks already won + what double
	dummy gives from here), so the trajectory reads the same whichever side is on play: a declarer card that
	costs lowers it, a defender card that costs raises it.
*/

import dds "dds:."
import "norn:norn"
import "../replay"

Play_Cost :: replay.Play_Cost

// Solve every position of `play`. ok=false when DDS refuses the batch (it never should for a valid play).
// The positions and the reading of DDS's answers are `replay`'s, shared with the shared-deals player, which
// asks DDS in wasm the same questions one position at a time.
play_cost :: proc(deal: norn.Deal, contract: norn.Contract, play: norn.Play) -> (cost: Play_Cost, ok: bool) {
	positions := new(replay.Positions)
	defer free(positions)
	positions^ = replay.positions(deal, contract, play)
	boards := new(dds.Boards)
	defer free(boards)
	solved := new(dds.Solved_Boards)
	defer free(solved)
	#assert(size_of(dds.Deal) == size_of(replay.Dds_Deal))
	#assert(size_of(dds.Future_Tricks) == size_of(replay.Dds_Future))
	for p in 0 ..< positions.count {
		boards.deals[p] = transmute(dds.Deal)positions.deals[p]
		boards.target[p] = replay.DDS_TARGET
		boards.solutions[p] = dds.Solutions(replay.DDS_SOLUTIONS)
		boards.mode[p] = dds.Solve_Mode(replay.DDS_MODE)
	}
	boards.noOfBoards = i32(positions.count)
	if dds.SolveAllBoardsBin(boards, solved) != .NO_FAULT {
		return {}, false
	}
	futures := ([^]replay.Dds_Future)(&solved.solvedBoard[0])[:positions.count]
	return replay.costs(positions, futures, play)
}

// The `data-play` JSON (see `replay.write_play_json`).
write_play_json :: replay.write_play_json

// norn's contract strain as DDS's (the two enums order their variants differently).
strain_to_dds :: proc(strain: norn.Contract_Strain) -> dds.Strain {
	return dds.Strain(replay.dds_strain(strain))
}

contract_strain_word :: replay.contract_strain_word
