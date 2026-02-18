#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

// Synchronous shell execution via popen.
// Returns stdout on success, or negative exit code on failure.
// Caller provides buffer; actual length written to *out_len.
int vibe_popen_exec(const char *cmd_ptr, int cmd_len,
                    char *buf, int buf_cap, int *out_len) {
    // Null-terminate the command
    char *cmd = (char *)malloc(cmd_len + 1);
    if (!cmd) return -1;
    memcpy(cmd, cmd_ptr, cmd_len);
    cmd[cmd_len] = '\0';

    FILE *fp = popen(cmd, "r");
    free(cmd);
    if (!fp) return -1;

    int length = 0;
    size_t n;
    while ((n = fread(buf + length, 1, buf_cap - length, fp)) > 0) {
        length += (int)n;
        if (length >= buf_cap) break;
    }

    int status = pclose(fp);
    int exit_code = WEXITSTATUS(status);
    *out_len = length;
    return exit_code;
}
