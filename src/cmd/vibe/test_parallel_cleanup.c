#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#define VIBE_MAX_PARALLEL_CHILDREN 256

static volatile sig_atomic_t g_signal_handlers_installed = 0;
static volatile sig_atomic_t g_signal_handler_entered = 0;
static volatile sig_atomic_t g_child_count = 0;
static int g_child_pids[VIBE_MAX_PARALLEL_CHILDREN];

static void vibe_parallel_cleanup_kill_all(int sig) {
  sig_atomic_t count = g_child_count;
  if (count > VIBE_MAX_PARALLEL_CHILDREN) {
    count = VIBE_MAX_PARALLEL_CHILDREN;
  }
  for (sig_atomic_t i = 0; i < count; i++) {
    int pid = g_child_pids[i];
    if (pid > 0) {
      kill(pid, sig);
    }
  }
}

static void vibe_parallel_cleanup_signal_handler(int sig) {
  if (g_signal_handler_entered) {
    _exit(128 + sig);
  }
  g_signal_handler_entered = 1;
  vibe_parallel_cleanup_kill_all(SIGTERM);
  vibe_parallel_cleanup_kill_all(SIGKILL);
  _exit(128 + sig);
}

void vibe_parallel_cleanup_install_signal_handlers(void) {
  if (g_signal_handlers_installed) {
    return;
  }
  g_signal_handlers_installed = 1;

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = vibe_parallel_cleanup_signal_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);
}

void vibe_parallel_cleanup_clear(void) {
  g_child_count = 0;
  memset(g_child_pids, 0, sizeof(g_child_pids));
}

void vibe_parallel_cleanup_register_child_pid(int pid) {
  if (pid <= 0) {
    return;
  }
  sig_atomic_t count = g_child_count;
  if (count < 0 || count > VIBE_MAX_PARALLEL_CHILDREN) {
    return;
  }
  for (sig_atomic_t i = 0; i < count; i++) {
    if (g_child_pids[i] == pid) {
      return;
    }
  }
  if (count == VIBE_MAX_PARALLEL_CHILDREN) {
    return;
  }
  g_child_pids[count] = pid;
  g_child_count = count + 1;
}

void vibe_parallel_cleanup_unregister_child_pid(int pid) {
  if (pid <= 0) {
    return;
  }
  sig_atomic_t count = g_child_count;
  if (count <= 0 || count > VIBE_MAX_PARALLEL_CHILDREN) {
    return;
  }
  for (sig_atomic_t i = 0; i < count; i++) {
    if (g_child_pids[i] == pid) {
      for (sig_atomic_t j = i; j + 1 < count; j++) {
        g_child_pids[j] = g_child_pids[j + 1];
      }
      g_child_pids[count - 1] = 0;
      g_child_count = count - 1;
      return;
    }
  }
}

int vibe_process_exists(int pid) {
  if (pid <= 0) {
    return 0;
  }
  if (kill(pid, 0) == 0) {
    return 1;
  }
  if (errno == EPERM) {
    return 1;
  }
  return 0;
}
