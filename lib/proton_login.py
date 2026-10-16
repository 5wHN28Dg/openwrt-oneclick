"""Log in to Proton VPN once and hand the session to the router.

Run through ./proton-login.sh, which installs nothing itself and passes the
API address (Proton's API names are usually blocked by the router's own
filter lists, so the address is resolved on the router through dnsproxy).

What it does:
  1. Logs in with Proton's own client library (SRP, CAPTCHA via Proton's
     verification page in your browser, 2FA code).
  2. Fetches the server list once and prints the free servers in the chosen
     countries (and saves them to private/proton-servers.txt for checks).
  3. Writes the session's UID and refresh token to private/proton-session
     (mode 600). It does NOT log out: the router continues this session.
     The password is never stored or sent anywhere but to Proton.
"""
import argparse
import getpass
import json
import os
import socket
import sys

API_HOST = "vpn-api.proton.me"
APPVERSION = "Other"   # proton-core's default; we don't pose as an official client
SECURE_CORE, TOR = 1, 2

ap = argparse.ArgumentParser()
ap.add_argument("--ip", required=True, help=f"address of {API_HOST}")
ap.add_argument("--private", required=True, help="private/ directory")
ap.add_argument("--countries", default="RO PL CH", help="exit countries to list (the router picks by ping)")
args = ap.parse_args()

# Pin the API host name to the given address for this process only.
_real = socket.getaddrinfo
socket.getaddrinfo = lambda host, *a, **k: _real(args.ip if host == API_HOST else host, *a, **k)

import requests  # noqa: E402  (installed with proton-core)
from proton.session import Session  # noqa: E402
from proton.session.exceptions import ProtonAPIError, ProtonAPIHumanVerificationNeeded  # noqa: E402
from proton.session.transports.aiohttp import AiohttpTransport  # noqa: E402


def say(*a):
    print(*a, file=sys.stderr)


session = Session(appversion=APPVERSION, user_agent="openwrt-oneclick")
session.transport_factory = AiohttpTransport          # TLS-pinned transport
username = input("Proton username or email: ").strip()
password = getpass.getpass("Proton password: ")
hv = None
try:
    for attempt in (1, 2):
        try:
            if not session.authenticate(username, password, additional_headers=hv):
                sys.exit("Wrong username or password.")
            break
        except ProtonAPIError as e:
            human = isinstance(e, ProtonAPIHumanVerificationNeeded) or e.body_code in (9001, 12087)
            if not human or attempt == 2:
                sys.exit(f"Login failed: {e.http_code} {e.body_code} {e.error}")
            d = (getattr(e, "json_data", None) or {}).get("Details", {})
            token = d.get("HumanVerificationToken")
            if not token or "captcha" not in d.get("HumanVerificationMethods", []):
                sys.exit("Proton asks for a verification method other than CAPTCHA; log in once in a browser first.")
            say(f"\nProton wants a CAPTCHA. Open this in a browser, solve it, then come back:\n"
                f"  https://verify.proton.me/?methods=captcha&token={token}\n")
            input("Press Enter once the page says verification succeeded... ")
            hv = {"x-pm-human-verification-token": token, "x-pm-human-verification-token-type": "captcha"}
finally:
    del password
if session.needs_twofa and not session.provide_2fa(input("2FA code: ").strip()):
    sys.exit("2FA failed.")

state = session.__getstate__()
uid, access, refresh = state["UID"], state["AccessToken"], state["RefreshToken"]
del state
# Save the session first: a failed list fetch must not cost a new login.
priv = args.private
os.makedirs(priv, mode=0o700, exist_ok=True)
old = os.umask(0o077)
try:
    tmp = os.path.join(priv, "proton-session.tmp")
    with open(tmp, "w") as f:
        f.write("# Proton VPN session for the router (UID + refresh token). Secret.\n")
        f.write(f"PROTON_UID='{uid}'\nPROTON_REFRESH='{refresh}'\n")
    os.replace(tmp, os.path.join(priv, "proton-session"))
finally:
    os.umask(old)
say("Saved private/proton-session (the session for the router).")

h = {"x-pm-uid": uid, "Authorization": f"Bearer {access}", "x-pm-appversion": APPVERSION,
     "Accept": "application/vnd.protonmail.v1+json"}

tier = requests.get(f"https://{API_HOST}/vpn/v2", headers=h, timeout=30).json().get("VPN", {}).get("MaxTier", 0)
r = requests.get(f"https://{API_HOST}/vpn/v1/logicals?SecureCoreFilter=all&WithState=true", headers=h, timeout=60)
r.raise_for_status()
want = args.countries.split()
rows = []
for s in r.json()["LogicalServers"]:
    if s.get("Status") != 1 or s.get("Tier", 99) > tier or s.get("Features", 0) & (SECURE_CORE | TOR):
        continue
    if s.get("ExitCountry") not in want:
        continue
    for p in s.get("Servers", []):
        if p.get("Status") == 1 and p.get("X25519PublicKey"):
            rows.append((want.index(s["ExitCountry"]), s.get("Load", 100), s["ExitCountry"], s["Name"],
                         p["EntryIP"], p["X25519PublicKey"]))
            break
rows.sort()

old = os.umask(0o077)
try:
    with open(os.path.join(priv, "proton-servers.txt"), "w") as f:
        for _, load, cc, name, ip, key in rows:
            f.write(f"{cc} {load} {name} {ip} {key}\n")
finally:
    os.umask(old)

say(f"\nPlan tier {tier}. {len(rows)} usable servers in {' '.join(want)} (by country, then load; the router picks by ping):")
for _, load, cc, name, ip, _key in rows[:12]:
    say(f"  {cc}  {name:<12} load {load:>3}%  {ip}")
say("\nSaved private/proton-servers.txt.")
say("Not logged out: the router continues this session.")
