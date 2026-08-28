package perf

/*
Process memory, for attributing it rather than guessing at it.

Two programs need the same numbers: `mem_check` (windowless, so it can walk the whole curve without a
display) and the workbench's own `--mem-report` (a real window, which is the only place the GPU backend's
commit shows up). The difference between the two totals IS the graphics layer, so the two have to measure
the same way — hence one package rather than a copy in each program.

`GetProcessMemoryInfo` is bound here rather than in the odin-sciter bindings because it is diagnostics, not
part of what any application does: `core:sys/windows` binds `GetProcessWorkingSetSizeEx`, which is the QUOTA
rather than the usage, and nothing for the counter Task Manager's "Memory" column shows.
*/

import "core:fmt"
import win "core:sys/windows"

foreign import psapi "system:psapi.lib"

@(private)
Process_Memory_Counters :: struct {
	cb:                       u32,
	page_fault_count:         u32,
	peak_working_set_size:    uint,
	working_set_size:         uint,
	quota_peak_paged_pool:    uint,
	quota_paged_pool:         uint,
	quota_peak_nonpaged_pool: uint,
	quota_nonpaged_pool:      uint,
	pagefile_usage:           uint,
	peak_pagefile_usage:      uint,
}

@(private)
foreign psapi {
	GetProcessMemoryInfo :: proc(process: win.HANDLE, counters: ^Process_Memory_Counters, cb: u32) -> win.BOOL ---
}

/*
Working set and private commit, in MB.

Both, because they answer different questions. The working set is what a person sees in Task Manager and it
can fall without anything being freed (the OS trimming pages); the private commit is what the process has
actually asked for and is the honest number for "how much does this cost".
*/
memory_mb :: proc() -> (working_set: f64, committed: f64) {
	counters: Process_Memory_Counters
	counters.cb = size_of(counters)
	if GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, counters.cb) == win.FALSE {
		return -1, -1
	}
	MB :: 1024 * 1024
	return f64(counters.working_set_size) / MB, f64(counters.pagefile_usage) / MB
}

// A running report: each row is where we are, what it costs now, and what the step added.
Report :: struct {
	last: f64,
}

report_begin :: proc(r: ^Report, title: string) {
	fmt.printfln("%-42s %8s %8s", title, "working set", "delta")
	r.last, _ = memory_mb()
	fmt.printfln("%-42s %5v MB", "start", int(r.last))
}

mark :: proc(r: ^Report, stage: string) -> (working_set: f64, delta: f64) {
	now, committed := memory_mb()
	working_set = now
	delta = now - r.last
	r.last = now
	fmt.printfln("%-42s %5v MB  %+6v MB  (commit %v MB)", stage, int(working_set), int(delta), int(committed))
	return working_set, delta
}

report_end :: proc(r: ^Report) {
	working_set, committed := memory_mb()
	fmt.printfln("\ntotal: %v MB working set, %v MB committed", int(working_set), int(committed))
}
