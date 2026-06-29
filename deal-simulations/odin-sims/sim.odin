package main

/*
	sim — the bidding-system deal generator (consumer program).

	A single-file (`-file`) program: the thin `main` that wires THIS bidding system's scenario
	registry into norn's reusable CLI driver. The hand-generation engine (`norn:norn`) and the
	scenario framework / argument parsing (`norn:cli`) come from the norn library via
	`-collection:norn=...`; everything system-specific — the predicates and the scenario registry —
	lives in the local `bidding` package.

	Build/run (from the odin-sims dir): see the justfile, e.g. `just run --scenario 1c-any -n 12`.
	The raw form is:
	  odin run sim.odin -file -collection:norn=C:/Users/Enerqi/dev/norn -- --scenario 1c-any -n 12
*/

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:sync"
import "core:time"

import "bidding"
import "norn:cli"

main :: proc() { 	// Operational setup before calling `main_program`

	// Exit code, set from main_program's return. Registered FIRST so this defer runs LAST — after
	// all the cleanup defers below — then terminates the process. (Odin evaluates a deferred call's
	// arguments at scope exit, so `exit_code` carries main_program's final value.) main_program
	// itself never calls os.exit, so that operational teardown is never skipped.
	exit_code := cli.EXIT_OK
	defer os.exit(exit_code)

	// (1) program duration tracking
	when TIME_PROGRAM_DURATION_ENABLE {
		start_time := time.now()
	}
	// (2) Global allocator change
	when MIMALLOC_ENABLE {
		context.allocator = mi.global_allocator()
	}
	// (3) Profiler setup
	when SPALL_ENABLE {
		spall_profiler_setup()
		defer spall_profiler_destroy()
	}
	SPALL_SCOPED_EVENT(name = #procedure)
	// (4) Back trace improvements
	when BACKTRACE_ENABLE {
		context.assertion_failure_proc = back.assertion_failure_proc
		back.register_segfault_handler()
	}
	// (5) Memory tracking allocator to debug leaks and bad frees (double frees)
	when TRACKING_ALLOCATOR_ENABLE {
		alloc_interface, tracking_allocator := make_tracking_allocator_context()
		context.allocator = alloc_interface
		defer tracking_allocator_finalise(tracking_allocator)
	}
	// (6) Logger setup to stdout
	context.logger = make_logging_context()
	defer destroy_logging_context()
	// (7) Time program duration on shutdown
	when TIME_PROGRAM_DURATION_ENABLE {
		defer log_program_duration(start_time)
	}

	exit_code = cli.main_program(bidding.registry)
}

/*
___________________________________________________________________________________________________________________
	Operational Setup - profiling, logging, telemetry etc. (not program semantics related)

	- Build with `-define:SPALL_ENABLE=true` option to emit a spall profiling `trace.spall` file (adds 2+ seconds)
		* https://github.com/colrdavidson/spall-web
	- Build with `-define:MIMALLOC_ENABLE=true` and provide a `mi` mimalloc import to override the global allocator
		* https://github.com/jakubtomsu/odin-mimalloc
	- Build with `-define:BACKTRACE_ENABLE=true` and provide a back import path to improve backtraces
		* https://github.com/laytan/back
	- Build with `-define:TIME_PROGRAM_DURATION_ENABLE=true` to turn on the program duration logging
	- Build with `-define:TRACKING_ALLOCATOR_ENABLE=false` to turn off the memory tracking and reporting
___________________________________________________________________________________________________________________
*/
TIME_PROGRAM_DURATION_ENABLE :: #config(TIME_PROGRAM_DURATION_ENABLE, false)
MIMALLOC_ENABLE :: #config(MIMALLOC_ENABLE, false)
SPALL_ENABLE :: #config(SPALL_ENABLE, false)
BACKTRACE_ENABLE :: #config(BACKTRACE_ENABLE, false)
TRACKING_ALLOCATOR_ENABLE :: #config(TRACKING_ALLOCATOR_ENABLE, true)

import spall "core:prof/spall"
// import mi "../odin-mimalloc/mimalloc"
// import back "../back"


// Profiling global / thread local data
global_spall_ctx: spall.Context
@(thread_local)
thread_local_spall_buffer: spall.Buffer

// setup the spall profiler and prepare the main thread with a telemetry recording buffer. Other threads need additional
// setup for the telemetry buffer
@(cold)
spall_profiler_setup :: proc() {
	global_spall_ctx = spall.context_create("trace.spall") // global
	buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE) // memset to pre touch? already done by odin?
	thread_local_spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
}

// telemetry buffer setup for an extra thread. Must be run from the extra thread due to the thread local spall buffer
//
// the "spall_recording_buffer" is available as a package level thread local `thread_local_spall_buffer`
//
// cleanup: spall.buffer_destroy(&global_spall_ctx, &thread_local_spall_buffer) and then delete(spall_backing_buffer)
@(cold)
@(require_results)
spall_thread_local_setup :: proc(allocator := context.allocator) -> (spall_backing_buffer: []u8) {
	spall_backing_buffer = make([]u8, spall.BUFFER_DEFAULT_SIZE)
	thread_local_spall_buffer = spall.buffer_create(
		spall_backing_buffer,
		u32(sync.current_thread_id()),
	)
	return
}

@(cold)
spall_profiler_destroy :: proc() {
	spall.buffer_destroy(&global_spall_ctx, &thread_local_spall_buffer)
	spall.context_destroy(&global_spall_ctx)
}

@(no_instrumentation)
spall_event_start :: #force_inline proc "contextless" (
	name: string,
	args: string = "",
	location := #caller_location,
) {
	when SPALL_ENABLE {
		spall._buffer_begin(&global_spall_ctx, &thread_local_spall_buffer, name, args, location)
	}
}

@(no_instrumentation)
spall_event_end :: #force_inline proc "contextless" () {
	when SPALL_ENABLE {
		spall._buffer_end(&global_spall_ctx, &thread_local_spall_buffer)
	}
}

@(deferred_none = _spall_scoped_event_end)
@(no_instrumentation)
SPALL_SCOPED_EVENT :: #force_inline proc "contextless" (
	name: string,
	args: string = "",
	location := #caller_location,
) {
	when SPALL_ENABLE {
		spall._buffer_begin(&global_spall_ctx, &thread_local_spall_buffer, name, args, location)
	}
}

@(private)
@(no_instrumentation)
_spall_scoped_event_end :: #force_inline proc "contextless" () {
	when SPALL_ENABLE {
		spall._buffer_end(&global_spall_ctx, &thread_local_spall_buffer)
	}
}

when TRACKING_ALLOCATOR_ENABLE {
	when !BACKTRACE_ENABLE {
		@(cold)
		@(require_results)
		make_tracking_allocator_context :: proc(
			allocator := context.allocator,
			loc := #caller_location,
		) -> (
			mem.Allocator,
			^mem.Tracking_Allocator,
		) {
			SPALL_SCOPED_EVENT(name = #procedure)
			tracking_allocator := new(mem.Tracking_Allocator, allocator = allocator, loc = loc)
			mem.tracking_allocator_init(tracking_allocator, context.allocator)
			return mem.tracking_allocator(tracking_allocator), tracking_allocator
		}

		@(cold)
		tracking_allocator_finalise :: proc(tracking_allocator: ^mem.Tracking_Allocator) {
			SPALL_SCOPED_EVENT(name = #procedure)

			if len(tracking_allocator.allocation_map) > 0 ||
			   len(tracking_allocator.bad_free_array) > 0 {
				for _, v in tracking_allocator.allocation_map {
					log.errorf("Memory Leak:\t%v", v)
				}
				for bad_free in tracking_allocator.bad_free_array {
					log.errorf(
						"%v allocation %p was freed badly\n",
						bad_free.location,
						bad_free.memory,
					)
				}
			}

			mem.tracking_allocator_destroy(tracking_allocator)
		}
	} else {
		@(cold)
		@(require_results)
		make_tracking_allocator_context :: proc(
			allocator := context.allocator,
			loc := #caller_location,
		) -> (
			mem.Allocator,
			^back.Tracking_Allocator,
		) {
			SPALL_SCOPED_EVENT(name = #procedure)
			tracking_allocator := new(back.Tracking_Allocator, allocator = allocator, loc = loc)
			back.tracking_allocator_init(tracking_allocator, context.allocator)
			return back.tracking_allocator(tracking_allocator), tracking_allocator
		}

		@(cold)
		tracking_allocator_finalise :: proc(tracking_allocator: ^back.Tracking_Allocator) {
			SPALL_SCOPED_EVENT(name = #procedure)
			back.tracking_allocator_print_results(tracking_allocator)
			back.tracking_allocator_destroy(tracking_allocator)
		}
	}
}

@(cold)
@(require_results)
make_logging_context :: proc() -> log.Logger {
	SPALL_SCOPED_EVENT(name = #procedure)
	LOG_LEVEL_ENV_KEY :: "LOG_LEVEL"
	log_level := log.Level.Info
	env_value_buf := [32]u8{}
	if log_level_env_var, err := os.lookup_env(env_value_buf[:], LOG_LEVEL_ENV_KEY); err == nil {
		normalized_env_var := strings.to_pascal_case(
			log_level_env_var,
			allocator = context.temp_allocator,
		)
		if level, level_ok := reflect.enum_from_name(log.Level, normalized_env_var); level_ok {
			log_level = level
		} else {
			fmt.eprintfln(
				"%v env var value \"%v\" is not a valid log.Level value, defaulting to \"Info\"",
				LOG_LEVEL_ENV_KEY,
				normalized_env_var,
			)
		}
	}
	return log.create_console_logger(log_level)
}

@(cold)
destroy_logging_context :: proc() {
	SPALL_SCOPED_EVENT(name = #procedure)
	log.destroy_console_logger(context.logger)
}

@(cold)
log_program_duration :: proc(start_time: time.Time) {
	SPALL_SCOPED_EVENT(name = #procedure)
	run_time := time.since(start_time)
	log.info("Program duration before any profiler or memory tracking shutdown:", run_time)
}
