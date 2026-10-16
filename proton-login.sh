#!/bin/sh
# Log in to Proton VPN once, so the router can keep its server list current
# (see "Proton VPN server choice" in README.md).
#
#   ./proton-login.sh [HOST [PORT]]     # router at 192.168.1.1
#
# Needs Proton's own Python client library in .venv (gitignored); the first
# run prints the one install command. Your password goes only to Proton; the
# router gets the session (UID + refresh token) on the next ./setup.sh.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/laptop.sh"
HOST=${1:-192.168.1.1}
PORT=${2:-22}
PRIV=${ONECLICK_PRIVATE:-$HERE/private}
# Proton's client library, pinned (it is not on PyPI under its own name).
PROTON_CORE=git+https://github.com/ProtonVPN/python-proton-core.git@9bd4662ddde2d439e4e8c900f0431e23958bd512

[ -f "$PRIV/config.env" ] || { say "Run ./setup.sh first (private/config.env is missing)."; exit 1; }
. "$PRIV/config.env"
if [ ! -x "$HERE/.venv/bin/python" ]; then
	say "Proton's client library isn't installed yet. Install it once with:"
	say "  python3 -m venv '$HERE/.venv' && '$HERE/.venv/bin/pip' install '$PROTON_CORE'"
	exit 1
fi

# Proton's API names are on common block lists (the router's own too), so ask
# the router's encrypted resolver directly for the address.
KNOWN=$(mktemp); trap 'rm -f "$KNOWN"' EXIT
target=$HOST; [ "$PORT" = 22 ] || target="[$HOST]:$PORT"
[ -f "$PRIV/host_keys/host_keys.pub" ] && sed "s|^|$target |" "$PRIV/host_keys/host_keys.pub" > "$KNOWN"
STRICT=yes; [ -s "$KNOWN" ] || STRICT=accept-new
IP=$(ssh -p "$PORT" -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile="$KNOWN" \
	-o StrictHostKeyChecking="$STRICT" "root@$HOST" \
	"nslookup -type=a vpn-api.proton.me 127.0.0.1:5354 | awk '/^Non-authoritative/ { f = 1 } f && /^Address: / { print \$2; exit }'")
case $IP in [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;; *) say "Couldn't resolve vpn-api.proton.me on the router."; exit 1 ;; esac

exec "$HERE/.venv/bin/python" -I "$HERE/lib/proton_login.py" --ip "$IP" --private "$PRIV" \
	--countries "${PROTON_COUNTRIES:-RO PL CH}"
