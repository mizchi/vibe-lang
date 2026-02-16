"""Minimal TCP echo server for socket integration tests.

Accepts multiple sequential connections. Each connection echoes data back
until the client disconnects. The server shuts down after MAX_CONNS
connections (default 4) or when killed.
"""
import socket
import sys
import os

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    max_conns = int(os.environ.get("MAX_CONNS", "4"))

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    actual_port = srv.getsockname()[1]
    # Signal readiness
    print(actual_port, flush=True)

    for _ in range(max_conns):
        conn, _ = srv.accept()
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                conn.sendall(data)
        finally:
            conn.close()

    srv.close()

if __name__ == "__main__":
    main()
