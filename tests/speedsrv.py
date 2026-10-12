#!/usr/bin/env python3
"""Stand-in for speed.cloudflare.com, used by tests/vm.sh.

GET /__down?bytes=N sends N zero bytes; POST /__up swallows the body. Each
connection is held to a fixed rate, so the test knows what the router should
measure (eight streams -> eight times the rate).

Usage: speedsrv.py PORT DOWN_KBIT_PER_STREAM UP_KBIT_PER_STREAM [refuse]

With "refuse" every request gets HTTP 429 (a rate-limiting server) and is
written to stdout, one line each.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT, DOWN_KBIT, UP_KBIT = (int(a) for a in sys.argv[1:4])
REFUSE = sys.argv[4:] == ["refuse"]
CHUNK = 4096


class Pace:
    """Sleeps so that the bytes counted so far stay at the given rate."""

    def __init__(self, kbit):
        self.per_second = kbit * 1000 / 8
        self.start = time.monotonic()
        self.count = 0

    def add(self, n):
        self.count += n
        ahead = self.count / self.per_second - (time.monotonic() - self.start)
        if ahead > 0:
            time.sleep(ahead)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def refuse(self):
        print(self.command, flush=True)
        self.send_response(429)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def do_GET(self):
        if REFUSE:
            return self.refuse()
        left = int(parse_qs(urlparse(self.path).query).get("bytes", ["0"])[0])
        self.send_response(200)
        self.send_header("Content-Length", str(left))
        self.end_headers()
        pace = Pace(DOWN_KBIT)
        zeros = bytes(CHUNK)
        try:
            while left > 0:
                n = min(left, CHUNK)
                self.wfile.write(zeros[:n])
                left -= n
                pace.add(n)
        except OSError:
            self.close_connection = True

    def _swallow(self, n, pace):
        while n > 0:
            got = self.rfile.read(min(n, CHUNK))
            if not got:
                raise OSError("client went away")
            n -= len(got)
            pace.add(len(got))

    def do_POST(self):
        if REFUSE:
            return self.refuse()
        pace = Pace(UP_KBIT)
        try:
            if "chunked" in self.headers.get("Transfer-Encoding", ""):
                while True:
                    size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                    if size == 0:
                        self.rfile.readline()
                        break
                    self._swallow(size, pace)
                    self.rfile.readline()
            else:
                self._swallow(int(self.headers.get("Content-Length", "0")), pace)
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
        except (OSError, ValueError):
            self.close_connection = True


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
