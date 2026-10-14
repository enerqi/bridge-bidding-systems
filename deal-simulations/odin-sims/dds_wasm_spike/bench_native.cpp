// The spike's native yardstick: the same DDS sources, the same deals as dds_bench.js, timed here.
// Usage: bench_native <tables> <solves> [threads]
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include "deals.h"

static double now_ms() {
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

int main(int argc, char **argv) {
	int tables = argc > 1 ? atoi(argv[1]) : 50, solves = argc > 2 ? atoi(argv[2]) : 200, threads = argc > 3 ? atoi(argv[3]) : 1;
	SetResources(200, threads);
	spike_rng = 12345;
	long long sum = 0;
	double t0 = now_ms();
	for (int k = 0; k < tables; k++) {
		ddTableDeal d;
		ddTableResults r;
		spike_deal(d.cards);
		if (CalcDDtable(d, &r) != RETURN_NO_FAULT) { printf("CalcDDtable failed\n"); return 1; }
		for (int s = 0; s < 5; s++) for (int h = 0; h < 4; h++) sum += r.resTable[s][h] * (s * 4 + h + 1);
	}
	double t1 = now_ms();
	spike_rng = 777;
	long long sum2 = 0;
	for (int k = 0; k < solves; k++) {
		deal dl = {};
		dl.trump = 4; // notrump
		dl.first = 3; // West leads: North-South declare
		spike_deal(dl.remainCards);
		futureTricks f;
		if (SolveBoard(dl, -1, 1, 1, &f, 0) != RETURN_NO_FAULT) { printf("SolveBoard failed\n"); return 1; }
		sum2 += f.score[0];
	}
	double t2 = now_ms();
	printf("native, %d thread(s): CalcDDtable %.2f ms each (%d, checksum %lld); SolveBoard %.3f ms each (%d, checksum %lld)\n",
		threads, (t1 - t0) / tables, tables, sum, (t2 - t1) / solves, solves, sum2);
}
