#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

// Synchronous shell execution via popen with an unbounded, growable capture
// buffer. The full stdout of the subprocess is read into an internally-owned
// buffer (no fixed 1 MB cap, so large `vibe check --human` output is never
// silently truncated). The caller first invokes `vibe_popen_exec` to run the
// command and learn the captured length, then `vibe_popen_drain` to copy the
// bytes out and release the internal buffer.

// Holds the most recent capture between `vibe_popen_exec` and
// `vibe_popen_drain`. The exec CLI is single-threaded, so a static buffer is
// sufficient and avoids passing raw pointers across the FFI boundary.
static char *g_capture_buf = NULL;
static int g_capture_len = 0;

// Runs `cmd` and captures its entire stdout into the internal buffer.
// Writes the captured byte count to *out_len and returns the subprocess exit
// code, or -1 on spawn/allocation failure. Call `vibe_popen_drain` afterwards
// (even for empty output) to copy the bytes out and free the internal buffer.
int vibe_popen_exec(const char *cmd_ptr, int cmd_len, int *out_len) {
    // Discard any buffer left over from a previous (undrained) call.
    if (g_capture_buf) {
        free(g_capture_buf);
        g_capture_buf = NULL;
        g_capture_len = 0;
    }
    *out_len = 0;

    // Null-terminate the command.
    char *cmd = (char *)malloc(cmd_len + 1);
    if (!cmd) return -1;
    memcpy(cmd, cmd_ptr, cmd_len);
    cmd[cmd_len] = '\0';

    FILE *fp = popen(cmd, "r");
    free(cmd);
    if (!fp) return -1;

    size_t cap = 1 << 16; // 64 KB initial, doubled as needed
    char *buf = (char *)malloc(cap);
    if (!buf) {
        pclose(fp);
        return -1;
    }

    size_t length = 0;
    char chunk[8192];
    size_t n;
    while ((n = fread(chunk, 1, sizeof(chunk), fp)) > 0) {
        if (length + n > cap) {
            while (length + n > cap) cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (!nb) {
                free(buf);
                pclose(fp);
                return -1;
            }
            buf = nb;
        }
        memcpy(buf + length, chunk, n);
        length += n;
    }

    int status = pclose(fp);
    int exit_code = WEXITSTATUS(status);

    g_capture_buf = buf;
    g_capture_len = (int)length;
    *out_len = (int)length;
    return exit_code;
}

// Copies up to `cap` bytes of the most recent capture into `buf` and frees the
// internal buffer. Returns the number of bytes copied. Safe to call once after
// each `vibe_popen_exec`; a second call is a no-op.
int vibe_popen_drain(char *buf, int cap) {
    int n = g_capture_len < cap ? g_capture_len : cap;
    if (g_capture_buf && n > 0) {
        memcpy(buf, g_capture_buf, n);
    }
    if (g_capture_buf) {
        free(g_capture_buf);
        g_capture_buf = NULL;
        g_capture_len = 0;
    }
    return n;
}
