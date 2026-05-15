#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/types.h>

#define VIBE_MAX_PARALLEL_CHILDREN 256

static volatile sig_atomic_t g_signal_handlers_installed = 0;
static volatile sig_atomic_t g_signal_handler_entered = 0;
static volatile sig_atomic_t g_child_count = 0;
static int g_child_pids[VIBE_MAX_PARALLEL_CHILDREN];
static volatile sig_atomic_t g_worker_watchdog_running = 0;
static volatile sig_atomic_t g_worker_watchdog_parent_pid = 0;
static pthread_t g_worker_watchdog_thread;

static int vibe_pid_exists(int pid) {
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

static void vibe_kill_pid_or_group(int pid, int sig) {
  if (pid <= 0) {
    return;
  }
  if (kill(-pid, sig) != 0) {
    if (errno != ESRCH && errno != EPERM) {
      kill(pid, sig);
      return;
    }
  }
  kill(pid, sig);
}

static void vibe_parallel_cleanup_kill_all(int sig) {
  sig_atomic_t count = g_child_count;
  if (count > VIBE_MAX_PARALLEL_CHILDREN) {
    count = VIBE_MAX_PARALLEL_CHILDREN;
  }
  for (sig_atomic_t i = 0; i < count; i++) {
    int pid = g_child_pids[i];
    if (pid > 0) {
      vibe_kill_pid_or_group(pid, sig);
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

void vibe_parallel_cleanup_assign_child_process_group(int pid) {
  if (pid <= 0) {
    return;
  }
  if (setpgid(pid, pid) == 0) {
    return;
  }
  if (errno == EACCES || errno == EPERM || errno == ESRCH) {
    return;
  }
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

static void* vibe_worker_parent_watchdog_main(void* arg) {
  (void)arg;
  int worker_pid = getpid();
  pid_t worker_pgid = getpgrp();
  while (g_worker_watchdog_running) {
    sig_atomic_t parent_pid = g_worker_watchdog_parent_pid;
    if (!vibe_pid_exists(parent_pid)) {
      if (worker_pgid == worker_pid) {
        kill(-worker_pgid, SIGTERM);
      }
      kill(worker_pid, SIGTERM);
      usleep(100 * 1000);
      if (worker_pgid == worker_pid) {
        kill(-worker_pgid, SIGKILL);
      }
      kill(worker_pid, SIGKILL);
      break;
    }
    usleep(100 * 1000);
  }
  return NULL;
}

void vibe_worker_process_group_init(void) {
  pid_t pid = getpid();
  if (pid <= 1) {
    return;
  }
  if (getpgrp() == pid) {
    return;
  }
  if (setpgid(0, 0) == 0) {
    return;
  }
  if (errno == EACCES || errno == EPERM) {
    return;
  }
}

void vibe_worker_parent_watchdog_start(int parent_pid) {
  if (parent_pid <= 1) {
    return;
  }
  if (g_worker_watchdog_running) {
    return;
  }
  g_worker_watchdog_parent_pid = parent_pid;
  g_worker_watchdog_running = 1;
  if (pthread_create(&g_worker_watchdog_thread, NULL, vibe_worker_parent_watchdog_main, NULL) != 0) {
    g_worker_watchdog_parent_pid = 0;
    g_worker_watchdog_running = 0;
    return;
  }
}

void vibe_worker_parent_watchdog_stop(void) {
  if (!g_worker_watchdog_running) {
    return;
  }
  g_worker_watchdog_running = 0;
  pthread_join(g_worker_watchdog_thread, NULL);
  g_worker_watchdog_parent_pid = 0;
}

int vibe_process_exists(int pid) {
  return vibe_pid_exists(pid);
}

/*
 * Session-http worker idle monitor.
 *
 * The session-http worker runs an HTTP server forever. To avoid
 * accumulating long-lived orphaned workers (PPID=1 after the spawning
 * vibe process exits — see issue write-up), the worker arms an idle
 * monitor: a background pthread polls `time(NULL) - g_session_last_active`
 * once per second and `_exit(0)`s the process when the idle window
 * exceeds the configured threshold.
 *
 * The MoonBit-side HTTP handler must call vibe_session_idle_monitor_touch()
 * on every request to reset the idle clock.
 */
static volatile sig_atomic_t g_session_idle_running = 0;
static volatile int g_session_idle_seconds = 0;
static volatile time_t g_session_last_active = 0;
static pthread_t g_session_idle_thread;

static void* vibe_session_idle_monitor_main(void* arg) {
  (void)arg;
  while (g_session_idle_running) {
    int idle = g_session_idle_seconds;
    time_t last = g_session_last_active;
    if (idle > 0 && last > 0) {
      time_t now = time(NULL);
      if (now - last >= idle) {
        _exit(0);
      }
    }
    sleep(1);
  }
  return NULL;
}

void vibe_session_idle_monitor_start(int idle_seconds) {
  if (idle_seconds <= 0) {
    return;
  }
  if (g_session_idle_running) {
    return;
  }
  g_session_idle_seconds = idle_seconds;
  g_session_last_active = time(NULL);
  g_session_idle_running = 1;
  if (pthread_create(&g_session_idle_thread, NULL,
                     vibe_session_idle_monitor_main, NULL) != 0) {
    g_session_idle_running = 0;
  }
}

void vibe_session_idle_monitor_touch(void) {
  g_session_last_active = time(NULL);
}
