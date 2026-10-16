#!/bin/sh
# End-to-end test on a throwaway OpenWrt VM (qemu, KVM if available). Never
# touches a real router: the VM's LAN is only reachable on localhost ports.
#
#   tests/vm.sh [full|minimal|both]     (default: both)
#
# full:    every option on (a WireGuard client inside the VM uses the remote-
#          access config), then kids.sh, setup.sh again (no duplicates), a
#          different host key (refused), and a re-run with the VPN, MangaDex
#          and remote access off
# minimal: every option off; checks nothing optional was installed
#
# Environment:
#   OPENWRT_VERSION     release to test (default 25.12.5)
#   TEST_DNS_UPSTREAM   plain DNS server for dnsproxy inside the VM, for
#                       networks that block DoH for their own LAN clients
#                       (the VM is such a client); e.g. 10.0.2.3:53
#   VM_SSH_PORT         localhost port for the VM's SSH (default 2222)
#   SPEED_PORT          localhost port for the stand-in speed test server
#                       (default 18080)
#
# The full scenario measures the line against tests/speedsrv.py on this
# computer (needs python3), which holds the eight streams to 20 Mbit/s down
# and 10 Mbit/s up together, so the result is known. Without python3 it uses Cloudflare.
#
# Expected FAILs (the test checks these are the only ones):
#   - "VPN WireGuard handshake": the test peer is a documentation address.
#   - "SQM speed test failed" with HTTP 429: Cloudflare rate-limits repeated
#     speed tests from one IP for about an hour; the saved rates are used.
#   - "SQM latency under load" may pass or fail: qemu's user network has no
#     real line behind it. The test only checks that it was measured.

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/lib/laptop.sh"
VER=${OPENWRT_VERSION:-25.12.5}
PORT=${VM_SSH_PORT:-2222}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/openwrt-oneclick
IMG=openwrt-$VER-x86-64-generic-squashfs-combined.img
W=$(mktemp -d)
QPID='' SPID='' XPID=''
export ONECLICK_TEST=1   # allows the plain-http Proton API stand-in
SPORT=${SPEED_PORT:-18080}
XPORT=${PROTON_PORT:-18181}
cleanup() { for p in "$QPID" "$SPID" "$XPID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$W"; }
trap cleanup EXIT INT TERM
fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; }

# ---------------------------------------------------------------- image
mkdir -p "$CACHE"
if [ ! -f "$CACHE/$IMG" ]; then
	base=https://downloads.openwrt.org/releases/$VER/targets/x86/64
	curl -fsS -o "$CACHE/sha256sums" "$base/sha256sums" && curl -fsS -o "$CACHE/$IMG.gz" "$base/$IMG.gz" || { echo "download failed"; exit 1; }
	(cd "$CACHE" && grep " \*$IMG.gz\$" sha256sums | sed 's/ \*/  /' | sha256sum -c -) || { echo "checksum mismatch"; exit 1; }
	gunzip -c "$CACHE/$IMG.gz" > "$CACHE/$IMG" 2>/dev/null || [ -s "$CACHE/$IMG" ] || { echo "unpack failed"; exit 1; }
fi

start_vm() {
	[ -n "$QPID" ] && { kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; }
	rm -f "$W/disk.qcow2"
	qemu-img create -q -f qcow2 -F raw -b "$CACHE/$IMG" "$W/disk.qcow2" 512M
	kvm=; [ -w /dev/kvm ] && kvm="-enable-kvm -cpu host"
	# shellcheck disable=SC2086
	qemu-system-x86_64 $kvm -smp 2 -m 256 -display none -serial file:"$W/console.log" \
		-drive file="$W/disk.qcow2",if=virtio \
		-netdev user,id=lan,net=192.168.1.0/24,host=192.168.1.2,dhcpstart=192.168.1.200,restrict=on,hostfwd=tcp:127.0.0.1:$PORT-192.168.1.1:22 \
		-device virtio-net-pci,netdev=lan \
		-netdev user,id=wan -device virtio-net-pci,netdev=wan &
	QPID=$!
}

# ---------------------------------------------------------------- workspace
cp -R "$HERE/setup.sh" "$HERE/kids.sh" "$HERE/lib" "$HERE/router" "$W/"
if [ -n "${TEST_DNS_UPSTREAM-}" ]; then
	f=$W/router/files/etc/config/dnsproxy
	sed -i "/list upstream/d; /list bootstrap/d; /list fallback/d" "$f"
	sed -i "/config dnsproxy 'servers'/a\\	list upstream '$TEST_DNS_UPSTREAM'\n\tlist bootstrap '$TEST_DNS_UPSTREAM'" "$f"
fi
ssh-keygen -q -t ed25519 -N '' -f "$W/key"
# The VM reaches this computer's localhost as 10.0.2.2.
SPEED_URL=
if command -v python3 >/dev/null; then
	python3 -I "$HERE/tests/speedsrv.py" "$SPORT" 2500 1250 & SPID=$!
	sleep 1
	if kill -0 "$SPID" 2>/dev/null; then SPEED_URL=http://10.0.2.2:$SPORT; else SPID=''; echo "speed test server did not start (port $SPORT in use?)"; exit 1; fi
fi
# Stand-in for Proton's API (tests/protonsrv.py): rotating tokens, fixed list.
# A real WireGuard server for the list (run in the VM, see proton_checks).
SRV_PRIV=$(wg_genkey) && SRV_PUB=$(wg_pubkey "$SRV_PRIV") || { echo "cannot make WireGuard keys with openssl"; exit 1; }
python3 -I "$HERE/tests/protonsrv.py" "$XPORT" "$SRV_PUB" & XPID=$!
sleep 1
kill -0 "$XPID" 2>/dev/null || { XPID=''; echo "Proton API stand-in did not start (port $XPORT in use?)"; exit 1; }
wgkey() { head -c 32 /dev/urandom | base64; }

make_private() { # dir full|minimal
	mkdir -p "$1"
	# shellcheck disable=SC2034  # write_config reads the settings through eval
	(
		WIFI_SSID=TestNet WIFI_KEY="it's a test" WIFI_ENCRYPTION=sae-mixed
		ROOT_PASSWORD_HASH=$(printf test | openssl passwd -5 -stdin)
		SSH_KEY=$W/key SSH_PUBKEYS=$(cat "$W/key.pub")
		TZ_NAME=Europe/Berlin TZ_POSIX=$(posix_tz Europe/Berlin)
		WAN_PROTO=dhcp LINK_TYPE=fiber SQM_FALLBACK_DOWN=100000 SQM_FALLBACK_UP=20000 WIFI_COUNTRY=DE
		if [ "$2" = full ]; then
			FAMILY_FILTER=1 BANIP_FEEDS="doh vpn" REDLIB_ALLOW=safereddit.com
			ADBLOCK_EXTRA_LISTS="hagezi:nsfw hagezi:nosafesearch hagezi:doh-vpn-proxy-bypass"
			ENABLE_VPN=1 VPN_IFACE=testvpn WG_PRIVATE_KEY=$(wgkey) WG_PEER_PUBLIC_KEY=$(wgkey)
			WG_ADDRESSES=10.66.0.2/32 WG_DNS=10.66.0.1 WG_ENDPOINT_HOST=192.0.2.1 WG_ENDPOINT_PORT=51820
			WG_ALLOWED_IPS="0.0.0.0/0 ::/0" WG_KEEPALIVE=25
			VPN_ROUTE_DOMAINS="example.com" VPN_ROUTE_SUBNETS="198.51.100.0/24"
			PROTON_AUTO=1 PROTON_COUNTRIES="PL CH" PROTON_API=http://10.0.2.2:$XPORT
			ENABLE_MANGADEX=1
			ENABLE_REMOTE=1 REMOTE_HOST='' REMOTE_PORT=51820 REMOTE_NET=10.77.0.0/24
			# 11 devices: re-runs then delete peer sections across [9]/[10]
			REMOTE_SERVER_KEY=$(wg_genkey) REMOTE_PEERS="phone|2|$(wg_genkey)|$(wg_psk)
laptop|3|$(wg_genkey)|$(wg_psk)"
			for i in 4 5 6 7 8 9 10 11 12; do REMOTE_PEERS="$REMOTE_PEERS
dev$i|$i|$(wg_genkey)|$(wg_psk)"; done
			SPEEDTEST_URL=$SPEED_URL
		else
			FAMILY_FILTER=0 ADBLOCK_EXTRA_LISTS='' BANIP_FEEDS='' ENABLE_VPN=0 ENABLE_MANGADEX=0 ENABLE_REMOTE=0
			unset PROTON_AUTO PROTON_COUNTRIES PROTON_API
			SQM_DOWN=50000 SQM_UP=10000   # fixed rates: nothing is measured
		fi
		write_config "$1/config.env"
	)
	if [ "$2" = full ]; then
		printf 'example.net\n' > "$1/blocklist.txt"
		printf "PROTON_UID='uid-test'\nPROTON_REFRESH='refresh-0'\n" > "$1/proton-session"
		printf '%s\n' "DEVICES='TV|02:00:00:00:00:01|192.168.1.150'" "CUTOFF_START='21:30:00'" "CUTOFF_STOP='05:30:00'" > "$1/kids.conf"
	fi
}

vm_ssh() { # uses the host keys setup.sh saved, or accepts a fresh one
	ssh -p "$PORT" -i "${VM_KEY:-$W/key}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
		-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR root@127.0.0.1 "$@"
}

run_setup() { # private-dir log
	ONECLICK_PRIVATE=$1 timeout 1500 "$W/setup.sh" 127.0.0.1 "$PORT" > "$2" 2>&1
	rc=$?
	unexpected=$(grep '^FAIL' "$2" | sort -u \
		| grep -v 'VPN WireGuard handshake' \
		| grep -v 'SQM speed test failed.*HTTP codes: 429' \
		| grep -v 'SQM latency under load' || true)
	# A crash prints no FAIL line: the report at the end must be there.
	if [ -z "$unexpected" ] && [ "$rc" -le 2 ] && grep -q '^=* REPORT =*$' "$2"; then
		ok "setup.sh ($(basename "$2" .log)): exit $rc, $(grep -c '^PASS' "$2") PASS, only expected FAILs"
	else
		bad "setup.sh ($(basename "$2" .log)): exit $rc"; printf '%s\n' "$unexpected" | sed 's/^/        /'
		tail -15 "$2" | sed 's/^/        | /'
	fi
	grep -q 'SQM speed test failed.*429' "$2" && echo "      note: Cloudflare rate limit hit; measured SQM path not exercised"
}

# adblock-lean came from its project (the current release), with lists the
# router's memory allows plus the family lists when they are on.
abl_check() {
	want=$(curl -fsS https://api.github.com/repos/lynxthecat/adblock-lean/releases/latest | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p')
	got=$(vm_ssh 'sed -n "s/^ABL_VERSION=\"\(.*\)\"$/\1/p" /etc/init.d/adblock-lean')
	[ -n "$want" ] && [ "$got" = "$want" ] && ok "adblock-lean is the current release ($got)" || bad "adblock-lean version: got [$got], latest release [$want]"
	lists=$(vm_ssh 'sed -n "s/^raw_block_lists=//p" /etc/adblock-lean/config')
	case $lists in *hagezi:pro*) ok "adblock-lean lists from its memory preset: $lists" ;; *) bad "adblock-lean lists: $lists" ;; esac
}

# Proton server choice after the first run: list, pick, a real handshake
# before anything is saved, no switching while the line is down, every server
# tried once when none answers, token rotation, one run at a time.
proton_checks() {
	grep -q '^PASS  Proton server list: 3 servers in PL CH' "$W/full.log" && ok "Proton: list fetched (3 usable of 8; disabled, paid, Secure Core, dead and other countries left out)" \
		|| bad "Proton list report: $(grep -i proton "$W/full.log" | tr '\n' ' ')"
	# 10.99.0.2 doesn't exist yet: nothing answers ping, so the least loaded
	# server is taken, in the kernel only (it never answered, so not saved).
	r=$(vm_ssh 'awk "{print \$2}" /etc/proton/servers | tr "\n" " "; wg show testvpn endpoints | cut -f2
		uci -q get network.@wireguard_testvpn[0].endpoint_host; grep -c "refresh-1" /etc/proton/session; ls -l /etc/proton/session | cut -c1-10')
	[ "$(echo $r)" = "CH-FREE#2 PL-FREE#5 PL-FREE#9 198.51.100.9:51820 192.0.2.1 1 -rw-------" ] \
		&& ok "Proton: left the unlisted server for the least loaded (no ping answers yet), not saved before a handshake; rotated token stored (mode 600)" \
		|| bad "Proton first pick (want 'CH-FREE#2 PL-FREE#5 PL-FREE#9 198.51.100.9:51820 192.0.2.1 1 -rw-------'): $(echo $r)"
	[ ! -e "$P/proton-session" ] && ok "Proton: laptop copy of the session removed after handing it over" || bad "Proton: laptop session copy still there"
	# A real WireGuard server for "CH-FREE#2" in a network namespace.
	r=$(printf '%s\n' "$SRV_PRIV" | vm_ssh 'apk add ip-full kmod-veth >/dev/null 2>&1 || exit 1
		cat > /tmp/srv.key; ip netns add srv; ip link add v0 type veth peer name v1; ip link set v1 netns srv
		ip addr add 10.99.0.1/24 dev v0; ip link set v0 up
		ip -n srv addr add 10.99.0.2/24 dev v1; ip -n srv link set v1 up; ip -n srv link set lo up
		ip -n srv link add wgs type wireguard
		ip netns exec srv wg set wgs private-key /tmp/srv.key listen-port 51820 peer "$(wg show testvpn public-key)" allowed-ips 10.66.0.2/32
		rm -f /tmp/srv.key; ip -n srv addr add 10.66.0.1/24 dev wgs; ip -n srv link set wgs up
		ping -c1 -W2 10.99.0.2 >/dev/null && echo up')
	[ "$r" = up ] || bad "test WireGuard server in the VM not set up: $r"
	# Stale tunnel, 5-minute limit passed: CH-FREE#2 now answers ping and wins,
	# the handshake is real, and only then is it saved.
	r=$(vm_ssh 'sed -i "s/^STALE=.*/STALE=1/" /etc/proton-pick.conf; echo 0 > /tmp/proton/last-switch; proton-pick check
		wg show testvpn endpoints | cut -f2
		i=0; until [ "$(wg show testvpn latest-handshakes | cut -f2)" != 0 ] || [ $i -ge 15 ]; do ping -I testvpn -c1 -W1 10.66.0.1 >/dev/null 2>&1; i=$((i+1)); done
		sed -i "s/^STALE=.*/STALE=300/" /etc/proton-pick.conf; proton-pick check
		uci -q get network.@wireguard_testvpn[0].endpoint_host; uci -q get network.@wireguard_testvpn[0].description; logread | grep -c "answers; saved"' | tr '\n' '|')
	[ "$r" = "10.99.0.2:51820|10.99.0.2|Proton CH-FREE#2|1|" ] && ok "Proton: moved to the server answering ping fastest, real handshake, then saved (and only then)" \
		|| bad "Proton real switch (want '10.99.0.2:51820|10.99.0.2|Proton CH-FREE#2|1|'): $r"
	# The internet line down (its checks blocked): a stale tunnel is not switched.
	r=$(vm_ssh 'nft add table inet pptest; nft add chain inet pptest o "{ type filter hook output priority -10; }"
		nft add rule inet pptest o ip daddr "{ 1.1.1.1, 8.8.8.8 }" drop; nft add rule inet pptest o ip6 daddr 2606:4700:4700::1111 drop
		ip netns exec srv ip link set wgs down
		sleep 3   # let the last handshake age past STALE=1
		sed -i "s/^STALE=.*/STALE=1/" /etc/proton-pick.conf; echo 0 > /tmp/proton/last-switch; proton-pick check
		wg show testvpn endpoints | cut -f2; logread | grep -c "internet line is down"; nft delete table inet pptest' | tr '\n' ' ')
	[ "$r" = "10.99.0.2:51820 1 " ] && ok "Proton: no switching while the internet line is down" || bad "Proton with the line down (want '10.99.0.2:51820 1'): $r"
	# No server answers (the real one is down, the others don't exist): each is
	# tried once, then it waits for the next list. Nothing is written to flash.
	r=$(vm_ssh 'for i in 1 2 3 4; do echo 0 > /tmp/proton/last-switch; proton-pick check >/dev/null 2>&1; wg show testvpn endpoints | cut -f2; done
		logread | grep -c "no listed server answered"; uci -q get network.@wireguard_testvpn[0].endpoint_host
		sed -i "s/^STALE=.*/STALE=300/" /etc/proton-pick.conf; ip netns exec srv ip link set wgs up' | tr '\n' ' ')
	[ "$r" = "198.51.100.9:51820 198.51.100.5:51820 198.51.100.5:51820 198.51.100.5:51820 1 10.99.0.2 " ] \
		&& ok "Proton: with no server answering, each is tried once, then it waits; nothing written to flash" \
		|| bad "Proton when nothing answers (want '198.51.100.9:51820 198.51.100.5:51820 198.51.100.5:51820 198.51.100.5:51820 1 10.99.0.2'): $r"
	r=$(vm_ssh 'proton-pick refresh >/dev/null 2>&1; echo $?; grep -c "refresh-2" /etc/proton/session; [ -e /tmp/proton/exhausted ] && echo waiting
		logread | grep -cE "refresh-[0-9]|access-[0-9]|uid-test"' | tr '\n' ' ')
	[ "$r" = "0 1 0 " ] && ok "Proton: next refresh uses the rotated token and gives every server a new chance; no tokens in the system log" \
		|| bad "Proton refresh/log (want '0 1 0'): $r"
	# Two runs at once (cron + boot + by hand): one waits for the other.
	r=$(vm_ssh 'proton-pick refresh >/tmp/a 2>&1 & proton-pick refresh >/tmp/b 2>&1; wait
		[ -f /tmp/proton/session-ended ] && echo ended; grep -c "refresh-4" /etc/proton/session' | tr '\n' ' ')
	[ "$r" = "1 " ] && ok "Proton: two refreshes at once run one after the other (token rotated twice, session intact)" \
		|| bad "Proton concurrent refreshes (want '1'): $r"
}

# After the re-run (which was sent a stale copy of the session): the router
# kept its own; the chosen server is kept; bad tokens refused; an ended
# session keeps the list; a new login is installed.
proton_rerun_checks() {
	r=$(vm_ssh 'uci -q get network.@wireguard_testvpn[0].endpoint_host')
	[ "$r" = 10.99.0.2 ] && ok "Proton: re-run kept the server proton-pick chose" || bad "Proton: re-run reset the server to $r"
	grep -q "kept the router's own Proton session" "$W/full-rerun.log" && grep -q '^PASS  Proton server list' "$W/full-rerun.log" && [ ! -e "$P/proton-session" ] \
		&& ok "Proton: a stale laptop copy of the session is refused; the router's newer session keeps working" \
		|| bad "Proton stale copy: $(grep -i proton "$W/full-rerun.log" | tr '\n' ' ')"
	curl -s "http://127.0.0.1:$XPORT/_evil" >/dev/null
	r=$(vm_ssh 'proton-pick refresh >/dev/null 2>&1; echo $?; grep -c "PWNED" /etc/proton/session; [ -e /tmp/PWNED ] && echo pwned; logread | grep -c "no usable tokens"' | tr '\n' ' ')
	[ "$r" = "1 0 1 " ] && ok "Proton: a token with shell quotes is refused, never stored or run" || bad "Proton evil token (want '1 0 1'): $r"
	curl -s "http://127.0.0.1:$XPORT/_end" >/dev/null
	r=$(vm_ssh 'proton-pick refresh >/dev/null 2>&1; echo $?; proton-pick status | grep -c "session:    ENDED"; wc -l < /etc/proton/servers' | tr '\n' ' ')
	[ "$r" = "1 1 3 " ] && ok "Proton: ended session reported in status, last list kept" || bad "Proton ended session (want '1 1 3'): $r"
	# Logging in again (./proton-login.sh) gives a new session for setup.sh.
	curl -s "http://127.0.0.1:$XPORT/_new" >/dev/null
	printf "PROTON_UID='uid-new'\nPROTON_REFRESH='refresh-new'\n" > "$P/proton-session"
	run_setup "$P" "$W/full-relogin.log"
	r=$(vm_ssh 'proton-pick status | grep -c "session:    present"')
	grep -q 'new Proton session installed' "$W/full-relogin.log" && grep -q '^PASS  Proton server list' "$W/full-relogin.log" && [ "$r" = 1 ] && [ ! -e "$P/proton-session" ] \
		&& ok "Proton: after a new login, setup.sh installs the new session and the list refreshes" || bad "Proton re-login (status present: $r): $(grep -i proton "$W/full-relogin.log" | tr '\n' ' ')"
}

# The upload side of the test line: a 10 Mbit/s shaper on the VM's WAN, where
# a real line's limit is. The speed stand-in's own pace can't do this: qemu's
# user network queues up to the host's TCP send buffer (4 MB per connection)
# ahead of it and refills that in bursts every few seconds, so the router's
# byte counter swung between ~6 and ~11 Mbit/s (6 of 16 runs off; with the
# shaper 0 of 16, each second within 2% of 10). It stays through the first
# run's package installs and "sqm stop", until the SQM that run sets up
# replaces it, so only the first run's rates are checked (re-runs measure an
# unshaped line).
shape_line() {
	i=0; until vm_ssh true 2>/dev/null; do i=$((i + 1)); [ $i -ge 40 ] && { bad "VM did not come up"; return 1; }; sleep 3; done
	r=$(vm_ssh 'i=0; until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || [ $i -ge 30 ]; do sleep 1; i=$((i + 1)); done
		apk update >/dev/null 2>&1 && apk add tc-tiny kmod-sched-core >/dev/null 2>&1 &&
		tc qdisc replace dev eth1 root tbf rate 10mbit burst 32kb latency 100ms && tc qdisc show dev eth1 root')
	case $r in *"tbf"*"rate 10Mbit"*) ;; *) bad "test line shaper not set up: $r" ;; esac
}

scenario_full() {
	echo "== full: every option on"
	start_vm; P=$W/p-full; make_private "$P" full
	shape_line
	run_setup "$P" "$W/full.log"
	abl_check
	# SQM: 8 streams at 2.5 Mbit/s each = 20 Mbit/s down, shaped at 90%; the
	# bounds allow for packet framing (counted, about 4%). Up: the 10 Mbit/s
	# shaper (see shape_line) counts framing itself, so 90% is ~9000 and the
	# bounds are tight: without the shaper they fail instead of flaking.
	if [ -n "$SPEED_URL" ]; then
		r=$(vm_ssh 'uci -q get sqm.wan.download; uci -q get sqm.wan.upload' | tr '\n' ' ')
		# shellcheck disable=SC2086  # two numbers
		set -- $r
		if grep -q '^PASS  SQM measured' "$W/full.log" && [ "${1:-0}" -ge 14000 ] && [ "${1:-0}" -le 21000 ] && [ "${2:-0}" -ge 8500 ] && [ "${2:-0}" -le 9500 ]; then
			ok "SQM measured the 20/10 Mbit/s test line: shaping at $r kbit/s"
		else
			bad "SQM measurement of the 20/10 Mbit/s test line: $r; $(grep 'SQM' "$W/full.log" | head -3 | tr '\n' ' ')"
		fi
		grep -q 'SQM latency under load' "$W/full.log" && ok "SQM latency under load measured: $(grep -m1 'SQM latency under load' "$W/full.log" | cut -c1-110)" \
			|| bad "SQM latency under load not reported"
	fi
	grep -q 'IPv4 yes (NAT), IPv6 no$' "$W/full.log" && grep -q 'after restart: IPv6 not usable$' "$W/full.log" \
		&& ok "report states IPv4/IPv6 plainly" || bad "report IPv4/IPv6 wording: $(grep -E 'online via|after restart' "$W/full.log" | tr '\n' ' ')"
	# Remote access: the laptop got one config per device, pointing at the
	# router's WAN address. A WireGuard client in a network namespace inside
	# the VM uses phone.conf (its socket stays outside, so it reaches the WAN
	# address) and gets DNS and the MangaDex reader through the tunnel.
	c=$P/remote/phone.conf
	if [ -f "$c" ] && [ "$(stat -c %a "$c")" = 600 ] && [ -f "$P/remote/laptop.conf" ]; then ok "remote access: device configs written (mode 600)"; else bad "remote access: device configs missing"; fi
	e=$(sed -n 's/^Endpoint = //p' "$c"); a=$(sed -n 's/^AllowedIPs = //p' "$c")
	[ "$e|$a" = "10.0.2.15:51820|10.77.0.0/24, 192.168.1.0/24" ] && ok "remote access: endpoint and routes in phone.conf" || bad "remote access: phone.conf endpoint/routes: $e|$a"
	grep -q 'private or carrier-grade NAT' "$W/full.log" && ok "remote access: warns that 10.0.2.15 is not reachable from outside" || bad "remote access: no NAT warning"
	r=$(sed '/^Address/d; /^DNS/d' "$c" | vm_ssh 'apk add ip-full >/dev/null 2>&1 || exit 1
		cat > /tmp/rc.conf; ip netns add rc; ip link add wgc type wireguard; wg setconf wgc /tmp/rc.conf; rm -f /tmp/rc.conf
		ip link set wgc netns rc; ip -n rc link set lo up; ip -n rc addr add 10.77.0.2/32 dev wgc; ip -n rc link set wgc up
		ip -n rc route add 10.77.0.0/24 dev wgc; ip -n rc route add 192.168.1.0/24 dev wgc
		echo "dns=$(ip netns exec rc nslookup manga.lan 10.77.0.1 2>/dev/null | awk "/^Address: /{print \$2}" | tail -1)"
		ip netns exec rc wget -qO- -T 10 http://192.168.1.1/mangadex-safe/ | grep -qi "<html" && echo served
		ip netns exec rc nslookup example.net 10.77.0.1 2>/dev/null | awk "/^Name:/{n=1} n && /^Address/" | grep -q . || echo own-list-blocks
		ip netns del rc' 2>&1 | tr '\n' ' ')
	[ "$r" = "dns=192.168.1.1 served own-list-blocks " ] && ok "remote access: through the tunnel manga.lan resolves, the reader loads, own list blocks" \
		|| bad "remote access through the tunnel (want 'dns=192.168.1.1 served own-list-blocks'): $r"
	proton_checks
	r=$(ONECLICK_PRIVATE=$P "$W/kids.sh" 127.0.0.1 "$PORT" 2>&1)
	case $r in *PASS*) ok "kids.sh: $r" ;; *) bad "kids.sh: $r" ;; esac
	r=$(ONECLICK_PRIVATE=$P "$W/kids.sh" --remove 127.0.0.1 "$PORT" 2>&1)
	[ "$(vm_ssh 'uci show firewall | grep -c "kids time restriction"')" = 0 ] && ok "kids.sh --remove: $r" || bad "kids.sh --remove left rules: $r"
	ONECLICK_PRIVATE=$P "$W/kids.sh" 127.0.0.1 "$PORT" >/dev/null 2>&1
	g=$(vm_ssh 'nslookup -type=a www.google.de 127.0.0.1 | awk "/^Address: /{print \$2}" | tail -1')
	[ "$g" = 216.239.38.120 ] && ok "safe search on a Google country domain (www.google.de)" || bad "www.google.de -> $g"
	a=$(vm_ssh 'nslookup -type=aaaa example.com 127.0.0.1 | awk "/^Address: /{print \$2}" | tail -1')
	[ "$a" = "::" ] && ok "VPN domain has no IPv6 answer (VPN has no IPv6)" || bad "VPN domain AAAA: $a"
	# Hardware flow offloading switched on by hand goes back to software (it bypasses SQM).
	vm_ssh 'uci set firewall.@defaults[0].flow_offloading_hw=1; uci commit firewall'
	printf "PROTON_UID='uid-test'\nPROTON_REFRESH='refresh-0'\n" > "$P/proton-session"   # an old copy
	run_setup "$P" "$W/full-rerun.log"
	r=$(vm_ssh 'uci -q get firewall.@defaults[0].flow_offloading; uci -q get firewall.@defaults[0].flow_offloading_hw' | tr '\n' ' ')
	[ "$r" = "1 0 " ] && ok "flow offloading: software on, hardware off" || bad "flow offloading (software hardware): $r"
	proton_rerun_checks

	# Settings that can't work (tunnel range = the LAN) stop the run before
	# anything changes: blocking and remote access stay as they were.
	cp -R "$P" "$W/p-overlap"
	# shellcheck disable=SC2034  # write_config reads the settings through eval
	(. "$W/p-overlap/config.env"; REMOTE_NET=192.168.1.0/24; write_config "$W/p-overlap/config.env")
	out=$(ONECLICK_PRIVATE=$W/p-overlap timeout 600 "$W/setup.sh" 127.0.0.1 "$PORT" 2>&1); rc=$?
	st=$(vm_ssh '/etc/init.d/adblock-lean status >/dev/null 2>&1 && echo blocking; uci -q get network.remote.listen_port' | tr '\n' ' ')
	case $out in *"overlaps the LAN"*) [ "$rc|$st" = "1|blocking 51820 " ] && ok "tunnel range overlapping the LAN: stopped before changing anything" \
		|| bad "overlap: exit $rc, after: $st" ;; *) bad "overlapping tunnel range not refused (exit $rc)" ;; esac

	# GitHub's API unreachable on a re-run: the installed adblock-lean is kept
	# (one FAIL in the report), and the router still blocks.
	vm_ssh 'echo "0.0.0.0 api.github.com" >> /etc/hosts'
	ONECLICK_PRIVATE=$P timeout 1500 "$W/setup.sh" 127.0.0.1 "$PORT" > "$W/full-nogh.log" 2>&1; rc=$?
	vm_ssh 'sed -i "/api.github.com/d" /etc/hosts; /etc/init.d/dnsmasq restart >/dev/null 2>&1'
	other=$(grep '^FAIL' "$W/full-nogh.log" | sort -u | grep -v 'VPN WireGuard handshake\|SQM speed test failed.*429\|kept the installed adblock-lean')
	if [ "$rc" = 2 ] && [ -z "$other" ] && grep -q '^FAIL.*kept the installed adblock-lean' "$W/full-nogh.log" \
		&& grep -q '^PASS  adblock-lean blocklist loaded' "$W/full-nogh.log"; then
		ok "GitHub unreachable: kept the installed adblock-lean, still blocking"
	else
		bad "GitHub unreachable: exit $rc; other FAILs: $other"; tail -8 "$W/full-nogh.log" | sed 's/^/        | /'
	fi
	counts=$(vm_ssh 'printf "%s %s %s %s %s %s %s %s %s\n" \
		"$(uci show firewall | grep -c "name=.testvpn.")" \
		"$(uci show firewall | grep -c "name=.Block-WireGuard-LAN.")" \
		"$(uci show dhcp | grep -c "name=.manga.lan.")" \
		"$(grep -c safesearch-hosts /etc/crontabs/root)" \
		"$(uci show network | grep -c "=wireguard_testvpn")" \
		"$(uci show firewall | grep -c "name=.kids time restriction.")" \
		"$(uci show network | grep -c "=wireguard_remote")" \
		"$(uci show firewall | grep -c "name=.Allow-Remote-WireGuard.")" \
		"$(uci show firewall | grep "\.network=" | grep -o "remote" | wc -l)"')
	[ "$counts" = "1 1 1 1 1 1 11 1 1" ] && ok "re-run: no duplicates" || bad "re-run duplicates (zone rule domain cron peer kids remote-peers remote-rule remote-in-lan): $counts"
	# Re-runs delete their old sections by position; every rule must be there once.
	d=$(vm_ssh "uci show firewall | sed -n \"s/^firewall\.[^.]*\.name='\(.*\)'\$/\1/p\" | sort | uniq -d")
	[ -z "$d" ] && ok "re-run: no firewall rule left twice" || bad "re-run: rules present twice: $(echo $d)"
	sqm=$(vm_ssh 'uci -q get sqm.wan.linklayer; uci -q get sqm.wan.overhead; uci -q get sqm.wan.tcMPU; uci -q get sqm.wan.iqdisc_opts' | tr '\n' '|')
	[ "$sqm" = "ethernet|44|84|nat dual-dsthost|" ] && ok "SQM fiber values + NAT fairness: $sqm" || bad "SQM values: $sqm"
	perms=$(vm_ssh 'stat -c %a / /etc /usr /www 2>/dev/null || ls -ld / /etc /usr /www | cut -c1-10' | tr '\n' ' ')
	case $perms in *700*|*drwx------*) bad "system directory permissions changed: $perms" ;; *) ok "system directories untouched: $perms" ;; esac
	[ "$(vm_ssh 'uci show firewall | grep -A8 "name=.testvpn." | grep -c "mtu_fix=.1."')" = 1 ] \
		&& ok "VPN zone clamps MSS (mtu_fix)" || bad "VPN zone lacks mtu_fix"
	k=$(vm_ssh "nft list ruleset | grep 'kids time restriction'")
	case $k in *"ether saddr"*) case $k in *"ip saddr"*) bad "kids rule still needs an IP match" ;; *) ok "kids rule matches by MAC only" ;; esac ;; *) bad "kids rule missing: $k" ;; esac

	# A router that presents a different SSH key than the saved one is refused
	# when nobody is there to confirm it (settings must not go to an impostor).
	cp -R "$P" "$W/p-impostor"
	ssh-keygen -q -t ed25519 -N '' -f "$W/other"
	cut -d' ' -f1,2 "$W/other.pub" > "$W/p-impostor/host_keys/host_keys.pub"
	out=$(ONECLICK_PRIVATE=$W/p-impostor timeout 120 "$W/setup.sh" 127.0.0.1 "$PORT" </dev/null 2>&1); rc=$?
	case $out in *"different SSH key"*) [ $rc -eq 1 ] && ok "different host key refused without confirmation" || bad "host key mismatch: exit $rc" ;; *) bad "host key mismatch not detected (exit $rc)" ;; esac

	# Re-run with VPN and MangaDex off, PPPoE switched off (simulated: the
	# PPPoE marker set on a DHCP line), a new SSH key, and a key added by hand.
	vm_ssh 'uci set network.wan.setup_pppoe=1; uci commit network; echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBy3handaddedkeyhandaddedkeyhandadd hand" >> /etc/dropbear/authorized_keys'
	ssh-keygen -q -t ed25519 -N '' -f "$W/key2"
	. "$P/config.env"
	# shellcheck disable=SC2034  # write_config reads the settings through eval
	(
		. "$P/config.env"
		ENABLE_VPN=0 ENABLE_MANGADEX=0 ENABLE_REMOTE=0
		SSH_KEY_OLD=$SSH_KEY SSH_PUBKEYS_OLD=$SSH_PUBKEYS SSH_KEY=$W/key2 SSH_PUBKEYS=$(cat "$W/key2.pub")
		write_config "$P/config.env"
	)
	printf "PROTON_UID='uid-test'\nPROTON_REFRESH='refresh-x'\n" > "$P/proton-session"
	run_setup "$P" "$W/full-off.log"
	[ -f "$P/proton-session" ] && ok "Proton: with the VPN off the laptop session is not sent and stays" || bad "Proton: laptop session deleted though the VPN is off"
	VM_KEY=$W/key2   # the router now only knows the new key
	left=$(vm_ssh 'uci show network | grep -c testvpn; uci show firewall | grep -c "name=.testvpn."; uci -q get dhcp.@dnsmasq[0].address | grep -c "::"' | tr '\n' ' ')
	[ "$left" = "0 0 0 " ] && ok "VPN turned off: interface, zone and IPv6 suppression removed" || bad "VPN leftovers (network firewall aaaa): $left"
	left=$(vm_ssh 'ls -d /etc/proton /etc/proton-pick.conf /usr/sbin/proton-pick 2>/dev/null; grep -c proton /etc/crontabs/root /etc/rc.local /etc/sysupgrade.conf' | tr '\n' ' ')
	[ "$left" = "/etc/crontabs/root:0 /etc/rc.local:0 /etc/sysupgrade.conf:0 " ] && ok "VPN turned off: Proton session, settings and jobs removed" || bad "Proton leftovers: $left"
	left=$(vm_ssh 'uci show network | grep -c "remote"; uci show firewall | grep -c "remote\|Remote"; wg show remote 2>/dev/null | grep -c peer' | tr '\n' ' ')
	[ "$left" = "0 0 0 " ] && ok "remote access turned off: interface, peers, lan-zone entry and port rule removed" || bad "remote access leftovers (network firewall peers): $left"
	oldk=$(cut -d' ' -f2 "$W/key.pub")
	m=$(ssh -p "$PORT" -i "$W/key2" -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR root@127.0.0.1 "
		[ -e /www/mangadex-safe ] && echo app; grep -q 'safe-otaku: manga.lan' /www/index.html && echo redirect
		echo maxreq=\$(uci get uhttpd.main.max_requests) wan=\$(uci get network.wan.proto)
		grep -c handaddedkey /etc/dropbear/authorized_keys; grep -cF '$oldk' /etc/dropbear/authorized_keys" 2>&1 | tr '\n' ' ')
	[ "$m" = "maxreq=3 wan=dhcp 1 0 " ] && ok "MangaDex removed, PPPoE back to DHCP, new key works, old key gone, hand-added key kept" \
		|| bad "after turning things off (expect 'maxreq=3 wan=dhcp 1 0'): $m"
	[ -z "$(. "$P/config.env"; echo "${SSH_KEY_OLD-}")" ] && ok "old SSH key dropped from settings after the run" || bad "SSH_KEY_OLD still saved"
}

scenario_minimal() {
	echo "== minimal: every option off"
	VM_KEY=

	start_vm; P=$W/p-min; make_private "$P" minimal
	run_setup "$P" "$W/minimal.log"
	abl_check
	r=$(vm_ssh 'uci -q get sqm.wan.download; uci -q get sqm.wan.upload' | tr '\n' ' ')
	if [ "$r" = "50000 10000 " ] && grep -q '^PASS  SQM fixed rates' "$W/minimal.log" && ! grep -q 'measuring line speed' "$W/minimal.log"; then
		ok "SQM fixed rates used as they are, nothing measured"
	else
		bad "SQM fixed rates: $r"
	fi
	r=$(vm_ssh '
		[ -e /www/mangadex-safe ] && echo "mangadex installed"
		uci -q get network.vpn >/dev/null && echo "vpn interface"
		apk info -e luci-proto-wireguard >/dev/null 2>&1 && echo "wireguard package"
		/etc/init.d/pbr enabled 2>/dev/null && echo "pbr enabled"
		grep -q safesearch-hosts /etc/crontabs/root && echo "safe-search cron"
		nft list ruleset | grep -q Block-WireGuard-LAN && echo "vpn-protocol blocks"
		grep -q "nsfw" /etc/adblock-lean/config && echo "nsfw list"
		uci -q get network.remote >/dev/null && echo "remote interface"
		apk info -e bind-dig >/dev/null 2>&1 && echo "bind-dig"
		apk info -e openssl-util >/dev/null 2>&1 && echo "openssl-util"
		true')
	[ -z "$r" ] && ok "nothing optional installed" || bad "optional parts present: $(echo $r)"
}

case ${1:-both} in
	full) scenario_full ;;
	minimal) scenario_minimal ;;
	both) scenario_full; scenario_minimal ;;
	*) echo "usage: $0 [full|minimal|both]"; exit 2 ;;
esac
echo
[ $fails -eq 0 ] && echo "VM tests passed" || echo "$fails VM test(s) failed"
[ $fails -eq 0 ]
