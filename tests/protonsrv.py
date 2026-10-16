#!/usr/bin/env python3
"""Stand-in for Proton's VPN API, used by tests/vm.sh for proton-pick.

Usage: protonsrv.py PORT REAL_KEY

REAL_KEY is the public key of a real WireGuard server that tests/vm.sh runs
inside the VM at 10.99.0.2 (listed as CH-FREE#2), so switching to it ends in
a real handshake.

Session: UID "uid-test", first refresh token "refresh-0". Every successful
/auth/refresh rotates the refresh token and the access token, like Proton,
and only the latest refresh token is accepted, so a router that doesn't keep
the new token fails on its next refresh.

  POST /auth/refresh       -> new tokens (422 with a stale token or after /_end)
  GET  /vpn/v2             -> {"VPN": {"MaxTier": 0}}       (needs the access token)
  GET  /vpn/v1/logicals    -> the fixed list below              (needs the access token)
  GET  /_end               -> end the session (later refreshes get 422)
  GET  /_new               -> a new session "uid-new" / "refresh-new" (a fresh login)
  GET  /_evil              -> the next refresh answers with a token holding shell quotes
  GET  /_stats             -> {"refreshes": N, "list_fetches": N}
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
REAL_KEY = sys.argv[2]
state = {"uid": "uid-test", "refresh": "refresh-0", "access": None, "n": 0, "ended": False, "lists": 0, "evil": False}


def key(i):
    return base64.b64encode(bytes([i]) * 32).decode()


def logical(name, cc, tier, status, load, ip, k, features=0, phys_status=1):
    return {"Name": name, "ExitCountry": cc, "Tier": tier, "Status": status, "Load": load,
            "Features": features, "Servers": [{"EntryIP": ip, "X25519PublicKey": k, "Status": phys_status}]}


SERVERS = [
    logical("PL-FREE#5", "PL", 0, 1, 91, "198.51.100.5", key(1)),
    logical("PL-FREE#9", "PL", 0, 1, 40, "198.51.100.9", key(2)),       # least loaded in PL, no ping
    logical("CH-FREE#2", "CH", 0, 1, 95, "10.99.0.2", REAL_KEY),        # the real server in the VM
    logical("RO-FREE#22", "RO", 0, 0, 10, "198.51.100.22", key(4)),     # disabled
    logical("NL#100", "NL", 2, 1, 5, "198.51.100.100", key(5)),         # paid tier
    logical("CH-SC#1", "CH", 0, 1, 5, "198.51.100.101", key(6), features=1),  # Secure Core
    logical("JP-FREE#1", "JP", 0, 1, 5, "198.51.100.102", key(7), phys_status=0),  # no working machine
    logical("US-FREE#1", "US", 0, 1, 20, "198.51.100.20", key(8)),      # outside the country filter
]


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authed(self):
        return (self.headers.get("x-pm-uid") == state["uid"] and state["access"]
                and self.headers.get("Authorization") == f"Bearer {state['access']}")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0)
        if self.path != "/auth/refresh":
            return self.reply(404, {"Code": 404})
        try:
            req = json.loads(body)
        except ValueError:
            return self.reply(400, {"Code": 2001})
        if (state["ended"] or self.headers.get("x-pm-uid") != state["uid"]
                or req.get("RefreshToken") != state["refresh"] or req.get("GrantType") != "refresh_token"):
            return self.reply(422, {"Code": 10013, "Error": "Invalid refresh token"})
        state["n"] += 1
        state["refresh"] = f"refresh-{state['n']}"
        if state["evil"]:
            state["evil"] = False
            state["refresh"] = "x'; touch /tmp/PWNED; '"
        state["access"] = f"access-{state['n']}"
        self.reply(200, {"Code": 1000, "AccessToken": state["access"], "RefreshToken": state["refresh"],
                         "ExpiresIn": 86400, "UID": state["uid"]})

    def do_GET(self):
        if self.path == "/_end":
            state["ended"] = True
            return self.reply(200, {"ended": True})
        if self.path == "/_evil":
            state["evil"] = True
            return self.reply(200, {"evil": True})
        if self.path == "/_new":
            state.update(uid="uid-new", ended=False, refresh="refresh-new", access=None)
            return self.reply(200, {"refresh": "refresh-new"})
        if self.path == "/_stats":
            return self.reply(200, {"refreshes": state["n"], "list_fetches": state["lists"]})
        if not self.authed():
            return self.reply(401, {"Code": 401, "Error": "Invalid access token"})
        if self.path == "/vpn/v2":
            return self.reply(200, {"Code": 1000, "VPN": {"MaxTier": 0}})
        if self.path.startswith("/vpn/v1/logicals"):
            state["lists"] += 1
            return self.reply(200, {"Code": 1000, "LogicalServers": SERVERS})
        self.reply(404, {"Code": 404})

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
