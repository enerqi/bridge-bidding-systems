"""Find the server process a profiler should be pointed at.

Not as simple as "the process listening on the port". Under granian the listener is the MASTER
(`granian.exe`), which accepts connections and hands them to a worker; the app -- every template
render, every filter match, the asyncio loop -- runs in a child `python.exe` whose command line says
only `-c "from multiprocessing..."` and mentions neither the port nor the app. Profiling the master
gives an idle Rust process with no python stacks to sample.

So: find the master by its command line, then take its heaviest descendant. Heaviest by RSS is the
right tiebreak rather than a guess -- the worker holds the parsed corpus (~7,600 auctions), which is
tens of megabytes nothing else in the tree carries.

Under uvicorn/litestar (`just dsquiz serve-uvicorn`) there is no master, and the single process is
both the listener and the app; that case falls out of the same search.
"""

from __future__ import annotations

import psutil


def _cmdline(process: psutil.Process) -> str:
    try:
        return " ".join(process.cmdline() or [])
    except psutil.AccessDenied, psutil.NoSuchProcess:
        return ""


def find_server_process(port: int) -> psutil.Process:
    """The process actually running the app, for a server started on `port`.

    Raises `LookupError` with something actionable rather than returning None -- a profile pointed at
    the wrong pid produces an empty flamegraph, which reads as "the server did nothing".
    """
    port_flags = (f"--port {port}", f"--port={port}", f":{port}")
    masters = [
        process
        for process in psutil.process_iter()
        if (line := _cmdline(process))
        and any(flag in line for flag in port_flags)
        and ("granian" in line or "litestar" in line or "uvicorn" in line or "app:app" in line)
        # the `uv run ...` wrappers carry the same command line as the server they spawned; keep the
        # deepest one by preferring processes whose own parent is not also a match
        and "uv.exe" not in process.name().lower()
        and process.name().lower() != "uv"
    ]
    if not masters:
        message = (
            f"no server found on port {port} -- start one with `just dsquiz serve-prod` "
            f"(DSQUIZ_PORT={port}), or pass an explicit pid"
        )
        raise LookupError(message)

    master = masters[0]
    workers = []
    for child in master.children(recursive=True):
        try:
            if not child.is_running() or not child.name().lower().startswith("python"):
                continue
            workers.append((_worker_rank(child), child.memory_info().rss, child))
        except psutil.AccessDenied, psutil.NoSuchProcess:
            continue
    if not workers:
        return master  # single-process server (uvicorn), which is its own worker

    workers.sort(key=lambda entry: (entry[0], entry[1]))
    return workers[-1][2]


def _worker_rank(process: psutil.Process) -> int:
    """1 for the process that IS granian's worker, 0 for anything else in the tree.

    Ranked rather than filtered, so a server started some other way still profiles something.

    Heaviest-by-RSS alone was wrong, and wrong in the way that wastes an afternoon: run in the
    seconds after a server starts, it picks one of the transient `uv` / bootstrap processes in the
    tree -- heavier at that instant than a worker which has not yet parsed the corpus -- and that
    process then exits. py-spy is handed a pid that no longer exists and says
    `The parameter is incorrect. (os error 87)`, which reads like a py-spy bug or a permissions
    problem and is neither.

    Granian spawns its worker through multiprocessing, so the worker's command line says so and
    nothing else in the tree does. Cross-check it against the server's own log line, which names the
    pid: `Spawning worker-1 with PID: N`.
    """
    try:
        return 1 if "multiprocessing" in " ".join(process.cmdline() or []) else 0
    except psutil.AccessDenied, psutil.NoSuchProcess:
        return 0
