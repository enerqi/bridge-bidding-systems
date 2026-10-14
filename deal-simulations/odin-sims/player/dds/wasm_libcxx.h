// Forced in front of every DDS source (-include) for the wasm spike. zig's wasm32-wasi libc++ is built without
// file streams, so `std::ofstream` is declared and never defined - and DDS names it for its debug dumps
// (trace and statistics files), none of which a solve writes. This gives it a stream that drops what it is told.
#pragma once
#include <ios>
#include <ostream>
#include <streambuf>
#include <string>

namespace std {
template <> class basic_ofstream<char> : public basic_ostream<char> {
	struct Null_Buf : basic_streambuf<char> {
		int_type overflow(int_type c) override { return traits_type::not_eof(c); }
	} sink;
public:
	basic_ofstream() : basic_ostream<char>(nullptr) { this->init(&sink); }
	explicit basic_ofstream(const char *, ios_base::openmode = ios_base::out) : basic_ofstream() {}
	void open(const char *, ios_base::openmode = ios_base::out) {}
	void open(const string &, ios_base::openmode = ios_base::out) {}
	void close() {}
	bool is_open() const { return false; }
};
}

// And no threads: libc++ for wasm32-wasi leaves out `std::mutex` and `std::this_thread`, which ThreadMgr names
// whatever threading backend is chosen. With none chosen DDS runs one thread, so a lock that does nothing is
// enough, and the wait for a free thread never waits.
#include <chrono>
namespace std {
struct mutex {
	void lock() {}
	void unlock() {}
	bool try_lock() { return true; }
};
namespace this_thread {
template <class Rep, class Period> void sleep_for(const chrono::duration<Rep, Period> &) {}
}
}
