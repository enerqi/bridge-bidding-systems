// Forced in front of DDS's System.cpp only, which is compiled as Linux for the wasm spike. System.cpp asks the
// OS for its cores and memory, and on a platform it does not know it gets 0 MB - so SetResources gives itself
// no threads and nothing solves. As Linux it calls sysconf, which wasi-libc does not have; this one says ONE
// core and 1 GB free (DDS takes half the physical memory it is told of), so SetResources' own budget is what
// bounds the transposition tables.
#pragma once
enum { _SC_PHYS_PAGES = 1, _SC_PAGESIZE, _SC_NPROCESSORS_ONLN };
static long sysconf(int name) {
	switch (name) {
	case _SC_PHYS_PAGES: return 32768;
	case _SC_PAGESIZE: return 65536;
	case _SC_NPROCESSORS_ONLN: return 1;
	}
	return -1;
}
