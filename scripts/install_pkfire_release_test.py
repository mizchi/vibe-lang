#!/usr/bin/env python3
"""Exercise release downloads with real curl and a local fault-injection server."""
import collections
import http.server
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parent.parent
PIN = (ROOT / ".github/pkfire-version").read_text().strip()


def executable(output):
    return f"#!/bin/sh\nprintf '%s\\n' '{output}'\n".encode()


def archive(version):
    data = executable(version)
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as tar:
        member = tarfile.TarInfo("pkf")
        member.size = len(data)
        member.mode = 0o755
        tar.addfile(member, io.BytesIO(data))
    return stream.getvalue()


class InstallerTest(unittest.TestCase):
    def run_installer(self, faults=None, pkf_version=PIN):
        faults = faults or {}
        counts = collections.Counter()
        bodies = {"pkf": archive(pkf_version), "pkl": executable("Pkl 0.32.1 (test, native)")}
        paths = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                tool = "pkf" if "/mizchi/pkfire/" in self.path else "pkl"
                counts[tool] += 1
                paths.append(self.path)
                fault = faults.get(tool)
                if fault == "always-504" or (fault == "504" and counts[tool] == 1):
                    self.send_error(504)
                    return
                body = bodies[tool]
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if fault == "partial" and counts[tool] == 1:
                    self.wfile.write(body[:7])
                    self.close_connection = True
                else:
                    self.wfile.write(body)

            def log_message(self, *_args):
                pass

        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary)
            install = temp / "installed"
            (install / "bin").mkdir(parents=True)
            for tool in bodies:
                (install / "bin" / tool).write_bytes(b"previous installation")
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            # Redirect only the transport. Retry/error/output-file options still
            # come from the installer; curl itself handles the injected faults.
            curl = temp / "curl"
            curl.write_text(
                f"#!{sys.executable}\nimport subprocess, sys\n"
                f"args = [a.replace('https://github.com', 'http://127.0.0.1:{server.server_port}') for a in sys.argv[1:]]\n"
                f"sys.exit(subprocess.call([{shutil.which('curl')!r}, *args, '--retry-delay', '1']))\n"
            )
            curl.chmod(0o755)
            env = dict(os.environ, PATH=f"{temp}:{os.environ['PATH']}", PKFIRE_INSTALL_DIR=str(install))
            try:
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/install_pkfire_release.sh")],
                    env=env, capture_output=True, text=True, timeout=25,
                )
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
            installed = {tool: (install / "bin" / tool).read_bytes() for tool in bodies}
        return result, counts, paths, installed

    def test_pinned_releases_install(self):
        result, counts, paths, installed = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(counts, {"pkf": 1, "pkl": 1})
        self.assertIn(f"/pkfire@{PIN}/pkf-", paths[0])
        self.assertIn("/apple/pkl/releases/download/0.32.1/pkl-", paths[1])
        self.assertEqual(installed["pkf"], executable(PIN))
        self.assertEqual(installed["pkl"], executable("Pkl 0.32.1 (test, native)"))

    def test_retries_504_and_truncated_download(self):
        result, counts, _, installed = self.run_installer({"pkf": "504", "pkl": "partial"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(counts, {"pkf": 2, "pkl": 2})
        self.assertEqual(installed["pkf"], executable(PIN))
        self.assertEqual(installed["pkl"], executable("Pkl 0.32.1 (test, native)"))

    def test_persistent_failure_preserves_existing_installation(self):
        result, counts, _, installed = self.run_installer({"pkl": "always-504"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(counts, {"pkf": 1, "pkl": 6})
        self.assertTrue(all(data == b"previous installation" for data in installed.values()))

    def test_wrong_release_is_not_installed(self):
        result, _, _, installed = self.run_installer(pkf_version="0.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pkfire pin not honoured", result.stderr)
        self.assertTrue(all(data == b"previous installation" for data in installed.values()))


if __name__ == "__main__":
    unittest.main()
