#!/usr/bin/env python3
"""Simple HTTP echo server for vibe/http E2E tests.

Usage: python3 tests/http_echo_server.py [port]
Default port: 18280

Endpoints:
  GET  /hello   -> 200 "hello"
  POST /echo    -> 200 (echoes request body)
  GET  /headers -> 200 (JSON of received headers)
  *    *        -> 404 "not found"
"""

import sys
import json
from http.server import HTTPServer, BaseHTTPRequestHandler


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/hello":
            self._respond(200, "hello")
        elif self.path == "/headers":
            headers = {k: v for k, v in self.headers.items()}
            body = json.dumps(headers)
            self._respond(200, body, content_type="application/json")
        else:
            self._respond(404, "not found")

    def do_POST(self):
        if self.path == "/echo":
            body = self._read_body()
            self._respond(200, body)
        else:
            self._respond(404, "not found")

    def _read_body(self):
        """Read request body supporting both Content-Length and chunked transfer encoding."""
        transfer_encoding = self.headers.get("Transfer-Encoding", "")
        if "chunked" in transfer_encoding.lower():
            chunks = []
            while True:
                size_line = self.rfile.readline().strip()
                chunk_size = int(size_line, 16)
                if chunk_size == 0:
                    self.rfile.readline()  # trailing CRLF
                    break
                chunks.append(self.rfile.read(chunk_size).decode("utf-8"))
                self.rfile.readline()  # trailing CRLF
            return "".join(chunks)
        else:
            length = int(self.headers.get("Content-Length", 0))
            return self.rfile.read(length).decode("utf-8") if length > 0 else ""

    def _respond(self, status, body, content_type="text/plain"):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format, *args):
        # Suppress default logging
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18280
    server = HTTPServer(("127.0.0.1", port), Handler)
    actual_port = server.server_address[1]
    print(f"HTTP echo server listening on 127.0.0.1:{actual_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
