#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

int vibe_tcp_connect(const char *host_ptr, int host_len, int port) {
    char host[256];
    if (host_len >= (int)sizeof(host)) return -1;
    memcpy(host, host_ptr, host_len);
    host[host_len] = '\0';

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -errno;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(fd);
        return -1;
    }

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int err = errno;
        close(fd);
        return -err;
    }
    return fd;
}

int vibe_tcp_read(int fd, char *buf, int buf_len) {
    ssize_t n = recv(fd, buf, buf_len, 0);
    if (n < 0) return -errno;
    return (int)n;
}

int vibe_tcp_write(int fd, const char *buf, int buf_len) {
    ssize_t n = send(fd, buf, buf_len, 0);
    if (n < 0) return -errno;
    return (int)n;
}

int vibe_tcp_close(int fd) {
    if (close(fd) < 0) return -errno;
    return 0;
}
