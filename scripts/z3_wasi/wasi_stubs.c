// In-module definitions of the WASI calls wasi-libc makes, so the linked z3
// module imports nothing: a vibe runner links a foreign core module only
// when it needs no host imports (docs/user/reference/cheatsheet.md,
// "Importing a wasm module"). wasm-ld resolves wasi-libc's
// `__imported_wasi_snapshot_preview1_*` references to these definitions
// instead of emitting imports.
//
// Each answer is the honest one for a module that has no host:
//   - no arguments and no environment (getenv finds nothing);
//   - no files: every descriptor is EBADF, every path ENOENT, and there are
//     no preopened directories, so reading or writing a file fails visibly;
//   - no clock: time reads 0 and never advances, so z3's `timeout` never
//     fires. The prover bounds a query with `rlimit` instead, which counts
//     work deterministically;
//   - no entropy: random_get fails (ENOSYS);
//   - proc_exit traps: an `exit()` inside z3 ends the call, never returns an
//     answer.
#include <stdint.h>

#define WASI_ESUCCESS 0
#define WASI_EBADF 8
#define WASI_ENOENT 44
#define WASI_ENOSYS 52

#define STUB(name) __attribute__((used)) int32_t __imported_wasi_snapshot_preview1_##name

STUB(args_sizes_get)(int32_t argc, int32_t argv_buf_size) {
  *(uint32_t*)(uintptr_t)argc = 0;
  *(uint32_t*)(uintptr_t)argv_buf_size = 0;
  return WASI_ESUCCESS;
}
STUB(args_get)(int32_t argv, int32_t argv_buf) { return WASI_ESUCCESS; }
STUB(environ_sizes_get)(int32_t count, int32_t buf_size) {
  *(uint32_t*)(uintptr_t)count = 0;
  *(uint32_t*)(uintptr_t)buf_size = 0;
  return WASI_ESUCCESS;
}
STUB(environ_get)(int32_t environ, int32_t environ_buf) { return WASI_ESUCCESS; }
STUB(clock_time_get)(int32_t id, int64_t precision, int32_t time) {
  *(uint64_t*)(uintptr_t)time = 0;
  return WASI_ESUCCESS;
}
STUB(clock_res_get)(int32_t id, int32_t resolution) {
  *(uint64_t*)(uintptr_t)resolution = 1;
  return WASI_ESUCCESS;
}
STUB(fd_close)(int32_t fd) { return WASI_EBADF; }
STUB(fd_fdstat_get)(int32_t fd, int32_t stat) { return WASI_EBADF; }
STUB(fd_fdstat_set_flags)(int32_t fd, int32_t flags) { return WASI_EBADF; }
STUB(fd_filestat_get)(int32_t fd, int32_t stat) { return WASI_EBADF; }
STUB(fd_prestat_get)(int32_t fd, int32_t prestat) { return WASI_EBADF; }
STUB(fd_prestat_dir_name)(int32_t fd, int32_t path, int32_t len) { return WASI_EBADF; }
STUB(fd_read)(int32_t fd, int32_t iovs, int32_t n, int32_t nread) { return WASI_EBADF; }
STUB(fd_pread)(int32_t fd, int32_t iovs, int32_t n, int64_t off, int32_t nread) { return WASI_EBADF; }
STUB(fd_write)(int32_t fd, int32_t iovs, int32_t n, int32_t nwritten) { return WASI_EBADF; }
STUB(fd_pwrite)(int32_t fd, int32_t iovs, int32_t n, int64_t off, int32_t nwritten) { return WASI_EBADF; }
STUB(fd_seek)(int32_t fd, int64_t off, int32_t whence, int32_t newoff) { return WASI_EBADF; }
STUB(fd_tell)(int32_t fd, int32_t off) { return WASI_EBADF; }
STUB(fd_sync)(int32_t fd) { return WASI_EBADF; }
STUB(fd_readdir)(int32_t fd, int32_t buf, int32_t len, int64_t cookie, int32_t used) { return WASI_EBADF; }
STUB(path_open)(int32_t fd, int32_t dirflags, int32_t path, int32_t path_len, int32_t oflags,
                int64_t rights, int64_t inheriting, int32_t fdflags, int32_t opened) {
  return WASI_ENOENT;
}
STUB(path_filestat_get)(int32_t fd, int32_t flags, int32_t path, int32_t len, int32_t stat) { return WASI_ENOENT; }
STUB(path_unlink_file)(int32_t fd, int32_t path, int32_t len) { return WASI_ENOENT; }
STUB(path_remove_directory)(int32_t fd, int32_t path, int32_t len) { return WASI_ENOENT; }
STUB(path_create_directory)(int32_t fd, int32_t path, int32_t len) { return WASI_ENOENT; }
STUB(path_rename)(int32_t fd, int32_t path, int32_t len, int32_t fd2, int32_t path2, int32_t len2) { return WASI_ENOENT; }
STUB(path_readlink)(int32_t fd, int32_t path, int32_t len, int32_t buf, int32_t buf_len, int32_t used) { return WASI_ENOENT; }
STUB(random_get)(int32_t buf, int32_t len) { return WASI_ENOSYS; }
STUB(sched_yield)(void) { return WASI_ESUCCESS; }
STUB(poll_oneoff)(int32_t in, int32_t out, int32_t n, int32_t nevents) { return WASI_ENOSYS; }
__attribute__((used, noreturn)) void __imported_wasi_snapshot_preview1_proc_exit(int32_t code) {
  __builtin_trap();
}
