#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#define MAX_HTTP_HANDLES 64
#define MAX_HEADER_SIZE  8192
#define MAX_BODY_SIZE    (1024 * 1024)

#define HANDLE_FREE     0
#define HANDLE_RESPONSE 1
#define HANDLE_SERVER   2
#define HANDLE_REQUEST  3

struct http_handle {
    int type;
    int fd;
    int status;
    char method[16];
    char url[4096];
    char headers[MAX_HEADER_SIZE];
    int headers_len;
    char body[MAX_BODY_SIZE];
    int body_len;
};

static struct http_handle handles[MAX_HTTP_HANDLES];

static int alloc_handle(void) {
    for (int i = 0; i < MAX_HTTP_HANDLES; i++) {
        if (handles[i].type == HANDLE_FREE) {
            memset(&handles[i], 0, sizeof(struct http_handle));
            return i;
        }
    }
    return -1;
}

/* Parse URL: http://host:port/path */
static int parse_url(const char *url, int url_len,
                     char *host, int host_sz,
                     int *port, char *path, int path_sz) {
    const char *p = url;
    const char *end = url + url_len;

    /* skip http:// */
    if (url_len > 7 && memcmp(p, "http://", 7) == 0) {
        p += 7;
    }

    /* extract host:port */
    const char *host_start = p;
    const char *colon = NULL;
    const char *slash = NULL;
    while (p < end) {
        if (*p == ':') colon = p;
        if (*p == '/') { slash = p; break; }
        p++;
    }

    if (colon && (!slash || colon < slash)) {
        int hlen = (int)(colon - host_start);
        if (hlen >= host_sz) return -1;
        memcpy(host, host_start, hlen);
        host[hlen] = '\0';
        *port = atoi(colon + 1);
    } else {
        int hlen = slash ? (int)(slash - host_start) : (int)(end - host_start);
        if (hlen >= host_sz) return -1;
        memcpy(host, host_start, hlen);
        host[hlen] = '\0';
        *port = 80;
    }

    if (slash) {
        int plen = (int)(end - slash);
        if (plen >= path_sz) plen = path_sz - 1;
        memcpy(path, slash, plen);
        path[plen] = '\0';
    } else {
        path[0] = '/';
        path[1] = '\0';
    }

    return 0;
}

/* Read all available data from fd into buf, up to max_len.
   Reads until connection closes or Content-Length reached. */
static int read_all(int fd, char *buf, int max_len) {
    int total = 0;
    while (total < max_len) {
        ssize_t n = recv(fd, buf + total, max_len - total, 0);
        if (n <= 0) break;
        total += (int)n;
    }
    return total;
}

/* Find header value in raw headers string (newline-separated).
   Case-insensitive name match. */
static int find_header_value(const char *headers, int headers_len,
                             const char *name, int name_len,
                             char *out, int out_len) {
    const char *p = headers;
    const char *end = headers + headers_len;
    while (p < end) {
        const char *line_end = memchr(p, '\n', end - p);
        if (!line_end) line_end = end;
        /* find colon */
        const char *colon = memchr(p, ':', line_end - p);
        if (colon) {
            int klen = (int)(colon - p);
            if (klen == name_len) {
                int match = 1;
                for (int i = 0; i < klen; i++) {
                    char a = p[i];
                    char b = name[i];
                    if (a >= 'A' && a <= 'Z') a += 32;
                    if (b >= 'A' && b <= 'Z') b += 32;
                    if (a != b) { match = 0; break; }
                }
                if (match) {
                    const char *val = colon + 1;
                    while (val < line_end && *val == ' ') val++;
                    int vlen = (int)(line_end - val);
                    /* trim trailing \r */
                    while (vlen > 0 && val[vlen - 1] == '\r') vlen--;
                    if (vlen >= out_len) vlen = out_len - 1;
                    memcpy(out, val, vlen);
                    return vlen;
                }
            }
        }
        p = line_end + 1;
    }
    return 0; /* not found, return empty */
}

/* Parse HTTP response from raw data into handle */
static int parse_http_response(struct http_handle *h, const char *data, int data_len) {
    /* Find status line: HTTP/1.x NNN ... */
    const char *p = data;
    const char *end = data + data_len;

    /* Skip HTTP/1.x */
    while (p < end && *p != ' ') p++;
    if (p >= end) return -1;
    p++; /* skip space */
    h->status = atoi(p);

    /* Find end of headers (blank line) */
    const char *hdr_end = NULL;
    for (const char *s = data; s < end - 3; s++) {
        if (s[0] == '\r' && s[1] == '\n' && s[2] == '\r' && s[3] == '\n') {
            hdr_end = s;
            break;
        }
    }
    if (!hdr_end) {
        /* No blank line - try \n\n */
        for (const char *s = data; s < end - 1; s++) {
            if (s[0] == '\n' && s[1] == '\n') {
                hdr_end = s;
                break;
            }
        }
    }
    if (!hdr_end) return -1;

    /* Extract headers (skip status line) */
    const char *first_nl = memchr(data, '\n', end - data);
    if (first_nl) {
        const char *hdr_start = first_nl + 1;
        int hlen = (int)(hdr_end - hdr_start);
        if (hlen > MAX_HEADER_SIZE - 1) hlen = MAX_HEADER_SIZE - 1;
        memcpy(h->headers, hdr_start, hlen);
        h->headers_len = hlen;
    }

    /* Body starts after blank line */
    const char *body_start = hdr_end;
    if (body_start[0] == '\r') body_start += 4; /* \r\n\r\n */
    else body_start += 2; /* \n\n */

    int blen = (int)(end - body_start);
    if (blen > MAX_BODY_SIZE - 1) blen = MAX_BODY_SIZE - 1;
    if (blen > 0) {
        memcpy(h->body, body_start, blen);
    }
    h->body_len = blen;

    return 0;
}

int vibe_http_request(const char *method_ptr, int method_len,
                      const char *url_ptr, int url_len,
                      const char *headers_ptr, int headers_len,
                      const char *body_ptr, int body_len) {
    char host[256];
    int port = 80;
    char path[4096];

    if (parse_url(url_ptr, url_len, host, sizeof(host), &port, path, sizeof(path)) < 0) {
        return -1;
    }

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

    /* Build HTTP/1.1 request */
    char req_buf[MAX_HEADER_SIZE + MAX_BODY_SIZE];
    int req_len = 0;

    /* Request line */
    req_len += snprintf(req_buf + req_len, sizeof(req_buf) - req_len,
                        "%.*s %s HTTP/1.1\r\nHost: %s\r\n",
                        method_len, method_ptr, path, host);

    /* Content-Length for body */
    if (body_len > 0) {
        req_len += snprintf(req_buf + req_len, sizeof(req_buf) - req_len,
                            "Content-Length: %d\r\n", body_len);
    }

    /* User headers (newline-separated) */
    if (headers_len > 0) {
        const char *p = headers_ptr;
        const char *hend = headers_ptr + headers_len;
        while (p < hend) {
            const char *nl = memchr(p, '\n', hend - p);
            if (!nl) nl = hend;
            int line_len = (int)(nl - p);
            /* Skip empty lines and trim \r */
            while (line_len > 0 && (p[line_len - 1] == '\r' || p[line_len - 1] == '\n')) line_len--;
            if (line_len > 0) {
                req_len += snprintf(req_buf + req_len, sizeof(req_buf) - req_len,
                                    "%.*s\r\n", line_len, p);
            }
            p = nl + 1;
        }
    }

    /* Connection: close */
    req_len += snprintf(req_buf + req_len, sizeof(req_buf) - req_len,
                        "Connection: close\r\n\r\n");

    /* Append body */
    if (body_len > 0 && req_len + body_len < (int)sizeof(req_buf)) {
        memcpy(req_buf + req_len, body_ptr, body_len);
        req_len += body_len;
    }

    /* Send */
    int sent = 0;
    while (sent < req_len) {
        ssize_t n = send(fd, req_buf + sent, req_len - sent, 0);
        if (n <= 0) {
            close(fd);
            return -errno;
        }
        sent += (int)n;
    }

    /* Read response */
    char *resp_buf = (char *)malloc(MAX_HEADER_SIZE + MAX_BODY_SIZE);
    if (!resp_buf) { close(fd); return -1; }
    int resp_len = read_all(fd, resp_buf, MAX_HEADER_SIZE + MAX_BODY_SIZE - 1);
    close(fd);

    if (resp_len <= 0) {
        free(resp_buf);
        return -1;
    }

    int hi = alloc_handle();
    if (hi < 0) {
        free(resp_buf);
        return -1;
    }

    handles[hi].type = HANDLE_RESPONSE;
    handles[hi].fd = -1;
    if (parse_http_response(&handles[hi], resp_buf, resp_len) < 0) {
        handles[hi].type = HANDLE_FREE;
        free(resp_buf);
        return -1;
    }

    free(resp_buf);
    return hi;
}

int vibe_http_response_status(int handle) {
    if (handle < 0 || handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[handle].type != HANDLE_RESPONSE) return -1;
    return handles[handle].status;
}

int vibe_http_response_header(int handle, const char *name_ptr, int name_len,
                              char *out_buf, int out_buf_len) {
    if (handle < 0 || handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[handle].type != HANDLE_RESPONSE) return -1;
    return find_header_value(handles[handle].headers, handles[handle].headers_len,
                             name_ptr, name_len, out_buf, out_buf_len);
}

int vibe_http_response_body(int handle, char *out_buf, int out_buf_len) {
    if (handle < 0 || handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[handle].type != HANDLE_RESPONSE) return -1;
    int len = handles[handle].body_len;
    if (len > out_buf_len) len = out_buf_len;
    memcpy(out_buf, handles[handle].body, len);
    return len;
}

int vibe_http_close(int handle) {
    if (handle < 0 || handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[handle].type == HANDLE_FREE) return -1;
    if (handles[handle].fd >= 0) {
        close(handles[handle].fd);
    }
    handles[handle].type = HANDLE_FREE;
    return 0;
}

int vibe_http_listen(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -errno;

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int err = errno;
        close(fd);
        return -err;
    }

    if (listen(fd, 16) < 0) {
        int err = errno;
        close(fd);
        return -err;
    }

    int hi = alloc_handle();
    if (hi < 0) {
        close(fd);
        return -1;
    }

    handles[hi].type = HANDLE_SERVER;
    handles[hi].fd = fd;
    return hi;
}

int vibe_http_accept(int server_handle) {
    if (server_handle < 0 || server_handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[server_handle].type != HANDLE_SERVER) return -1;

    int fd = accept(handles[server_handle].fd, NULL, NULL);
    if (fd < 0) return -errno;

    /* Read request data */
    char req_buf[MAX_HEADER_SIZE + MAX_BODY_SIZE];
    int total = 0;

    /* Read headers first */
    while (total < (int)sizeof(req_buf) - 1) {
        ssize_t n = recv(fd, req_buf + total, sizeof(req_buf) - 1 - total, 0);
        if (n <= 0) break;
        total += (int)n;
        /* Check for end of headers */
        if (total >= 4) {
            int found = 0;
            for (int i = 0; i <= total - 4; i++) {
                if (req_buf[i] == '\r' && req_buf[i+1] == '\n' &&
                    req_buf[i+2] == '\r' && req_buf[i+3] == '\n') {
                    found = 1;
                    /* Check Content-Length for body */
                    char cl_buf[32];
                    int cl = find_header_value(req_buf, i, "Content-Length", 14, cl_buf, sizeof(cl_buf));
                    if (cl > 0) {
                        cl_buf[cl] = '\0';
                        int body_expected = atoi(cl_buf);
                        int body_start = i + 4;
                        int body_have = total - body_start;
                        while (body_have < body_expected && total < (int)sizeof(req_buf) - 1) {
                            ssize_t m = recv(fd, req_buf + total, sizeof(req_buf) - 1 - total, 0);
                            if (m <= 0) break;
                            total += (int)m;
                            body_have = total - body_start;
                        }
                    }
                    found = 1;
                    break;
                }
            }
            if (found) break;
        }
    }

    if (total <= 0) {
        close(fd);
        return -1;
    }

    int hi = alloc_handle();
    if (hi < 0) {
        close(fd);
        return -1;
    }

    handles[hi].type = HANDLE_REQUEST;
    handles[hi].fd = fd;

    /* Parse request line: METHOD URL HTTP/1.x */
    const char *p = req_buf;
    const char *end = req_buf + total;
    const char *sp1 = memchr(p, ' ', end - p);
    if (!sp1) { handles[hi].type = HANDLE_FREE; close(fd); return -1; }

    int mlen = (int)(sp1 - p);
    if (mlen >= (int)sizeof(handles[hi].method)) mlen = sizeof(handles[hi].method) - 1;
    memcpy(handles[hi].method, p, mlen);
    handles[hi].method[mlen] = '\0';

    const char *url_start = sp1 + 1;
    const char *sp2 = memchr(url_start, ' ', end - url_start);
    if (!sp2) { handles[hi].type = HANDLE_FREE; close(fd); return -1; }

    int ulen = (int)(sp2 - url_start);
    if (ulen >= (int)sizeof(handles[hi].url)) ulen = sizeof(handles[hi].url) - 1;
    memcpy(handles[hi].url, url_start, ulen);
    handles[hi].url[ulen] = '\0';

    /* Find headers (after first line) */
    const char *first_nl = memchr(req_buf, '\n', total);
    if (first_nl) {
        const char *hdr_start = first_nl + 1;
        /* Find blank line */
        const char *hdr_end = NULL;
        for (const char *s = hdr_start; s < end - 3; s++) {
            if (s[0] == '\r' && s[1] == '\n' && s[2] == '\r' && s[3] == '\n') {
                hdr_end = s;
                break;
            }
        }
        if (hdr_end) {
            int hlen = (int)(hdr_end - hdr_start);
            if (hlen > MAX_HEADER_SIZE - 1) hlen = MAX_HEADER_SIZE - 1;
            memcpy(handles[hi].headers, hdr_start, hlen);
            handles[hi].headers_len = hlen;

            /* Body after blank line */
            const char *body_start = hdr_end + 4;
            int blen = (int)(end - body_start);
            if (blen > 0 && blen < MAX_BODY_SIZE) {
                memcpy(handles[hi].body, body_start, blen);
                handles[hi].body_len = blen;
            }
        }
    }

    return hi;
}

int vibe_http_request_method(int handle, char *out_buf, int out_buf_len) {
    if (handle < 0 || handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[handle].type != HANDLE_REQUEST) return -1;
    int len = (int)strlen(handles[handle].method);
    if (len > out_buf_len) len = out_buf_len;
    memcpy(out_buf, handles[handle].method, len);
    return len;
}

int vibe_http_request_url(int handle, char *out_buf, int out_buf_len) {
    if (handle < 0 || handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[handle].type != HANDLE_REQUEST) return -1;
    int len = (int)strlen(handles[handle].url);
    if (len > out_buf_len) len = out_buf_len;
    memcpy(out_buf, handles[handle].url, len);
    return len;
}

int vibe_http_request_header(int handle, const char *name_ptr, int name_len,
                             char *out_buf, int out_buf_len) {
    if (handle < 0 || handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[handle].type != HANDLE_REQUEST) return -1;
    return find_header_value(handles[handle].headers, handles[handle].headers_len,
                             name_ptr, name_len, out_buf, out_buf_len);
}

int vibe_http_request_body(int handle, char *out_buf, int out_buf_len) {
    if (handle < 0 || handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[handle].type != HANDLE_REQUEST) return -1;
    int len = handles[handle].body_len;
    if (len > out_buf_len) len = out_buf_len;
    memcpy(out_buf, handles[handle].body, len);
    return len;
}

int vibe_http_respond(int handle, int status,
                      const char *headers_ptr, int headers_len,
                      const char *body_ptr, int body_len) {
    if (handle < 0 || handle >= MAX_HTTP_HANDLES) return -1;
    if (handles[handle].type != HANDLE_REQUEST) return -1;
    int fd = handles[handle].fd;
    if (fd < 0) return -1;

    char resp_buf[MAX_HEADER_SIZE];
    int resp_len = 0;

    /* Status line */
    resp_len += snprintf(resp_buf + resp_len, sizeof(resp_buf) - resp_len,
                         "HTTP/1.1 %d OK\r\n", status);

    /* Content-Length */
    resp_len += snprintf(resp_buf + resp_len, sizeof(resp_buf) - resp_len,
                         "Content-Length: %d\r\n", body_len);

    /* User headers */
    if (headers_len > 0) {
        const char *p = headers_ptr;
        const char *hend = headers_ptr + headers_len;
        while (p < hend) {
            const char *nl = memchr(p, '\n', hend - p);
            if (!nl) nl = hend;
            int line_len = (int)(nl - p);
            while (line_len > 0 && (p[line_len - 1] == '\r' || p[line_len - 1] == '\n')) line_len--;
            if (line_len > 0) {
                resp_len += snprintf(resp_buf + resp_len, sizeof(resp_buf) - resp_len,
                                     "%.*s\r\n", line_len, p);
            }
            p = nl + 1;
        }
    }

    /* Connection: close */
    resp_len += snprintf(resp_buf + resp_len, sizeof(resp_buf) - resp_len,
                         "Connection: close\r\n\r\n");

    /* Send headers */
    int sent = 0;
    while (sent < resp_len) {
        ssize_t n = send(fd, resp_buf + sent, resp_len - sent, 0);
        if (n <= 0) { close(fd); handles[handle].fd = -1; return -errno; }
        sent += (int)n;
    }

    /* Send body */
    if (body_len > 0) {
        sent = 0;
        while (sent < body_len) {
            ssize_t n = send(fd, body_ptr + sent, body_len - sent, 0);
            if (n <= 0) { close(fd); handles[handle].fd = -1; return -errno; }
            sent += (int)n;
        }
    }

    close(fd);
    handles[handle].fd = -1;
    return 0;
}
