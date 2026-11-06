// Force-included into every z3 translation unit of the single-threaded WASI
// build. This libc++ is configured without threads, so <thread>, <mutex> and
// <condition_variable> declare nothing (and <thread> is an #error); it is
// also configured without a filesystem, so <fstream> declares nothing. With one
// thread, a mutex is correctly a no-op. Anything that would need a SECOND
// thread -- starting one, or blocking on a condition only another thread could
// satisfy -- aborts (a wasm trap) instead of pretending to have run.
#pragma once
#ifdef __cplusplus
#define _LIBCPP_THREAD
#define _LIBCPP_MUTEX
#define _LIBCPP_CONDITION_VARIABLE
#define _LIBCPP_FSTREAM
#include <chrono>
#include <cstdlib>
#include <functional>
#include <istream>
#include <string>
#include <ostream>
#include <system_error>
#include <tuple>
namespace std {
[[noreturn]] inline void __z3_wasi_no_threads() { abort(); }
struct mutex { void lock() {} bool try_lock() { return true; } void unlock() {} };
struct recursive_mutex : mutex {};
struct timed_mutex : mutex {
  template <class C, class D> bool try_lock_until(const chrono::time_point<C, D>&) { return true; }
  template <class R, class P> bool try_lock_for(const chrono::duration<R, P>&) { return true; }
};
struct defer_lock_t { explicit defer_lock_t() = default; };
inline constexpr defer_lock_t defer_lock{};
template <class M> struct lock_guard {
  M& m;
  explicit lock_guard(M& mm) : m(mm) { m.lock(); }
  ~lock_guard() { m.unlock(); }
  lock_guard(const lock_guard&) = delete;
};
template <class... M> struct scoped_lock {
  explicit scoped_lock(M&...) {}
  scoped_lock(const scoped_lock&) = delete;
};
template <class M> struct unique_lock {
  M* m; bool owns;
  explicit unique_lock(M& mm) : m(&mm), owns(true) { m->lock(); }
  unique_lock(M& mm, defer_lock_t) : m(&mm), owns(false) {}
  ~unique_lock() { if (owns) m->unlock(); }
  void lock() { m->lock(); owns = true; }
  void unlock() { m->unlock(); owns = false; }
  bool owns_lock() const { return owns; }
  M* mutex() const { return m; }
};
struct condition_variable_any {
  void notify_one() {} void notify_all() {}
  template <class L> void wait(L&) { __z3_wasi_no_threads(); }
  template <class L, class P> void wait(L&, P p) { if (!p()) __z3_wasi_no_threads(); }
};
struct condition_variable : condition_variable_any {};
class thread {
 public:
  class id {
   public:
    bool operator==(const id&) const { return true; }
    bool operator!=(const id&) const { return false; }
    friend ostream& operator<<(ostream& o, const id&) { return o << 1; }
  };
  thread() noexcept {}
  template <class F, class... A> explicit thread(F&&, A&&...) { __z3_wasi_no_threads(); }
  thread(thread&&) noexcept {}
  thread& operator=(thread&&) noexcept { return *this; }
  bool joinable() const { return false; }
  void join() {}
  void detach() {}
  id get_id() const { return id(); }
  static unsigned hardware_concurrency() { return 1; }
};
namespace this_thread {
inline thread::id get_id() { return thread::id(); }
inline void yield() {}
}
}
// <iosfwd> declares these templates (with their defaults) and the
// ifstream / ofstream / fstream typedefs in libc++'s ABI namespace.
_LIBCPP_BEGIN_NAMESPACE_STD
// The module has no imports, so it has no files: a file stream never opens.
// It is born in the fail state, so a read finds nothing and z3 reports the
// file as unreadable, and a write (a trace or log file) is discarded.
template <class C, class T> class basic_filebuf : public basic_streambuf<C, T> {
 public:
  bool is_open() const { return false; }
  basic_filebuf* open(const char*, ios_base::openmode) { return nullptr; }
  basic_filebuf* open(const string&, ios_base::openmode) { return nullptr; }
  basic_filebuf* close() { return nullptr; }
};
#define Z3_WASI_FILE_STREAM(NAME, BASE, MODE)                                         \
  template <class C, class T> class NAME : public BASE<C, T> {       \
    basic_filebuf<C, T> m_buf;                                                        \
   public:                                                                            \
    NAME() : BASE<C, T>(&m_buf) { this->setstate(ios_base::failbit); }                \
    explicit NAME(const char*, ios_base::openmode = MODE) : NAME() {}                 \
    explicit NAME(const string&, ios_base::openmode = MODE) : NAME() {}               \
    bool is_open() const { return false; }                                            \
    void open(const char*, ios_base::openmode = MODE) { this->setstate(ios_base::failbit); }   \
    void open(const string&, ios_base::openmode = MODE) { this->setstate(ios_base::failbit); } \
    void close() { this->setstate(ios_base::failbit); }                               \
    basic_filebuf<C, T>* rdbuf() const { return const_cast<basic_filebuf<C, T>*>(&m_buf); } \
  };
Z3_WASI_FILE_STREAM(basic_ifstream, basic_istream, ios_base::in)
Z3_WASI_FILE_STREAM(basic_ofstream, basic_ostream, ios_base::out)
Z3_WASI_FILE_STREAM(basic_fstream, basic_iostream, ios_base::in | ios_base::out)
#undef Z3_WASI_FILE_STREAM
_LIBCPP_END_NAMESPACE_STD
#endif
