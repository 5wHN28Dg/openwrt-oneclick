#!/bin/sh
# Kids' devices: fixed addresses plus a nightly internet cut-off, matched by MAC
# address (so it covers IPv4 and IPv6, and any IP the device picks itself).
# Run after setup.sh (safe to re-run; it replaces its own rules):
#
#   ./kids.sh                  # router at 192.168.1.1
#   ./kids.sh HOST [PORT]
#
# Devices and times live in private/kids.conf; if it doesn't exist yet you are
# asked for them and can save them.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/laptop.sh"
HOST=${1:-192.168.1.1}
PORT=${2:-22}
PRIV=${ONECLICK_PRIVATE:-$HERE/private}   # override for tests
[ -f "$PRIV/config.env" ] || { say "Run ./setup.sh first (private/config.env is missing)."; exit 1; }
. "$PRIV/config.env"
KIDS=$PRIV/kids.conf

valid_mac() { printf '%s' "$1" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
valid_ip()  { printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
valid_name() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]{1,32}$'; }
valid_hm()  { printf '%s' "$1" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$'; }

if [ ! -f "$KIDS" ]; then
	say "No kids' devices saved yet ($KIDS)."
	ask_yn "Enter them now?" y || exit 1
	DEVICES=
	say "One device at a time; leave the name empty to finish."
	while :; do
		ask name "Device name"
		[ -z "$name" ] && break
		valid_name "$name" || { say "  Use letters, digits, . _ - only (max 32)."; [ -t 0 ] || exit 1; continue; }
		while ask mac "  MAC address (aa:bb:cc:dd:ee:ff)"; do valid_mac "$mac" && break; say "  Not a MAC address."; [ -t 0 ] || exit 1; done
		while ask ip "  Fixed IP address"; do valid_ip "$ip" && break; say "  Not an IPv4 address."; [ -t 0 ] || exit 1; done
		DEVICES="$DEVICES$name|$mac|$ip
"
	done
	[ -n "$DEVICES" ] || { say "No devices entered."; exit 1; }
	while ask CUTOFF_START "Internet off from (HH:MM)" 21:30; do valid_hm "$CUTOFF_START" && break; [ -t 0 ] || exit 1; done
	while ask CUTOFF_STOP "Internet back at (HH:MM)" 05:30; do valid_hm "$CUTOFF_STOP" && break; [ -t 0 ] || exit 1; done
	CUTOFF_START=$CUTOFF_START:00 CUTOFF_STOP=$CUTOFF_STOP:00
	if ask_yn "Save these in $KIDS for next time?" y; then
		mkdir -p "$PRIV"
		(umask 077; {
			echo "# Kids' devices for kids.sh: name|MAC|fixed IP, one per line."
			printf 'DEVICES=%s\n' "$(shq "$DEVICES")"
			printf 'CUTOFF_START=%s\nCUTOFF_STOP=%s\n' "$(shq "$CUTOFF_START")" "$(shq "$CUTOFF_STOP")"
		} > "$KIDS")
		say "Saved $KIDS"
	fi
else
	. "$KIDS"
fi

KNOWN=$(mktemp); trap 'rm -f "$KNOWN"' EXIT
target=$HOST; [ "$PORT" = 22 ] || target="[$HOST]:$PORT"
[ -f "$PRIV/host_keys/host_keys.pub" ] && sed "s|^|$target |" "$PRIV/host_keys/host_keys.pub" > "$KNOWN"
STRICT=yes; [ -s "$KNOWN" ] || STRICT=accept-new

ssh -p "$PORT" -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
	-o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking="$STRICT" "root@$HOST" \
	"DEVICES=$(shq "$DEVICES") START=$(shq "$CUTOFF_START") STOP=$(shq "$CUTOFF_STOP") sh -s" <<'EOF'
set -eu
for cfg in dhcp firewall; do
	for s in $(uci -q show $cfg | sed -n "s/^$cfg\.\([^.]*\)\.kids='1'$/\1/p" | sort -r); do uci delete "$cfg.$s"; done
done
uci batch >/dev/null <<-B
	add firewall rule
	set firewall.@rule[-1].kids='1'
	set firewall.@rule[-1].name='kids time restriction'
	set firewall.@rule[-1].src='lan'
	set firewall.@rule[-1].dest='*'
	set firewall.@rule[-1].target='REJECT'
	set firewall.@rule[-1].start_time='$START'
	set firewall.@rule[-1].stop_time='$STOP'
B
printf '%s\n' "$DEVICES" | while IFS='|' read -r name mac ip; do
	[ -n "$name" ] || continue
	uci batch >/dev/null <<-B
		add dhcp host
		set dhcp.@host[-1].kids='1'
		set dhcp.@host[-1].name='$name'
		set dhcp.@host[-1].ip='$ip'
		add_list dhcp.@host[-1].mac='$mac'
		add_list firewall.@rule[-1].src_mac='$mac'
	B
done
uci commit dhcp; uci commit firewall
/etc/init.d/dnsmasq reload >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
n=$(nft list ruleset | grep -c 'kids time restriction' || true)
h=$(uci -q show dhcp | grep -c "\.kids='1'" || true)
if [ "$n" -gt 0 ] && [ "$h" -gt 0 ]; then
	echo "PASS  kids: $h fixed addresses, internet off $START-$STOP (nft rules: $n)"
else
	echo "FAIL  kids rules not active (nft rules: $n, hosts: $h)"; exit 1
fi
EOF
