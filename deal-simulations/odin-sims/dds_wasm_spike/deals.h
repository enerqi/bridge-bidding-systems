// The spike's deals, the same in C (bench_native.cpp) and JS (dds_bench.js): xorshift32, Fisher-Yates over
// 52 cards, card c = suit c/13 (spades first, DDS order) and rank c%13 + 2, dealt 13 a hand N E S W. Same
// seed, same deals, so the two builds' checksums must agree.
#pragma once
#include <stdint.h>
#include "dll.h"

static uint32_t spike_rng = 1;
static uint32_t spike_next() {
	spike_rng ^= spike_rng << 13;
	spike_rng ^= spike_rng >> 17;
	spike_rng ^= spike_rng << 5;
	return spike_rng;
}
static void spike_deal(unsigned cards[DDS_HANDS][DDS_SUITS]) {
	int deck[52];
	for (int i = 0; i < 52; i++) deck[i] = i;
	for (int i = 51; i > 0; i--) {
		int j = (int)(spike_next() % (uint32_t)(i + 1));
		int t = deck[i]; deck[i] = deck[j]; deck[j] = t;
	}
	for (int h = 0; h < 4; h++) for (int s = 0; s < 4; s++) cards[h][s] = 0;
	for (int i = 0; i < 52; i++) cards[i / 13][deck[i] / 13] |= 1u << (deck[i] % 13 + 2);
}
