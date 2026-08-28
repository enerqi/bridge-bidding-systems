# Benchmarks + the scenario frequency probe, imported by the justfile. `bench.odin` / `bench_e2e.odin` are
# single-file programs at the project root, so they build with `-file` like the other drivers.

# Frequency test every scenario by default, or `-S name[,name]` to restrict the subset. With --dd the
# rate also counts each scenario's double-dummy filter (filtered scenarios run serially).
# e.g. `just freq` (1M, -all), `just freq 5000000`, `just freq 1000000 -S 1c-any,2c-opener`.
# ---
# measure each scenario's acceptance frequency over N deals (no deals emitted)
[group('bench')]
freq trials="1000000" *args: mktarget_dirs
	odin run sim.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", sim_name) }} -- --frequency {{trials}} {{args}}

# Override counts: just bench '-define:COUNT_SUIT=5000' '-define:COUNT_DEAL=500'
# ---
# benchmark the combo package (Phase 1, Phase 2 lines/optimal, annotate end-to-end)
[group('bench')]
bench *args: mktarget_dirs
	odin run bench.odin -file {{norn}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "bench.exe") }} {{args}}

# The compute behind `sim -S slam-makes-dd --count 48 --format html-cards --dd`, minus the file write.
# Links DDS like sim. Knobs via -define:
#   just bench-e2e '-define:E2E_COUNT=24' '-define:E2E_ITERS=5'
#   just bench-e2e '-define:COMBO_THREADS=false'     (time the serial combo path)
# ---
# END-TO-END benchmark of ONE scenario's full pipeline (generate + DD filter + deal_solve/combo annotate + render)
[group('bench')]
bench-e2e *args: mktarget_dirs
	odin run bench_e2e.odin -file {{norn}} {{dds}} -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "bench-e2e.exe") }} {{args}}
