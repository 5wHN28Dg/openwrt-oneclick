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
#   OPENWRT_VERSION     release to test (default 25.12.5; must use apk, so 25.12 or later)
#   TEST_DNS_UPSTREAM   plain DNS server for dnsproxy inside the VM, for
#                       networks that block DoH for their own LAN clients
#                       (the VM is such a client); e.g. 10.0.2.3:53. Reddit's
#                       hosts then come from a hosts file (such networks may
#                       block Reddit): REDDIT_TEST_IP, default 151.101.1.140
#   VM_SSH_PORT         localhost port for the VM's SSH (default 2222)
#   SPEED_PORT          localhost port for the stand-in speed test server
#                       (default 18080)
#   TS_TEST_AUTHKEY_FILE  a real Tailscale auth key (ephemeral, reusable) for
#                       the full scenario; without it the router tries a dummy
#                       key, which Tailscale refuses (an expected FAIL that
#                       shows the router reached Tailscale)
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
#   - "Tailscale: not logged in" (without TS_TEST_AUTHKEY_FILE): the dummy key.

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/lib/laptop.sh"
VER=${OPENWRT_VERSION:-25.12.5}
PORT=${VM_SSH_PORT:-2222}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/openwrt-oneclick
IMG=openwrt-$VER-x86-64-generic-squashfs-combined.img
W=$(mktemp -d)
QPID='' SPID='' XPID='' RPID=''
export ONECLICK_TEST=1   # allows the plain-http Proton API stand-in
SPORT=${SPEED_PORT:-18080}
XPORT=${PROTON_PORT:-18181}
RPORT=${RELEASES_PORT:-18282}
cleanup() { for p in "$QPID" "$SPID" "$XPID" "$RPID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$W"; }
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
	# Such a network may filter Reddit too (a home router with family
	# filtering): Redlib's lookups, which go to dnsproxy, get Reddit's
	# address from a hosts file instead (REDDIT_TEST_IP, default Reddit's
	# Fastly address).
	sed -i "/config dnsproxy 'hosts'/,/^\$/{s/option enabled '0'/option enabled '1'/; s|list hosts_files ''|list hosts_files '/etc/oneclick-test-reddit.hosts'|}" "$f"
	for h in reddit.com www.reddit.com oauth.reddit.com accounts.reddit.com gql.reddit.com gql-fed.reddit.com old.reddit.com; do
		echo "${REDDIT_TEST_IP:-151.101.1.140} $h"
	done > "$W/router/files/etc/oneclick-test-reddit.hosts"
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
# Stand-in for the Redlib fork's "latest" release (redlib-update's
# decisions), as the fork names its builds: a build a day old, one whose
# SHA-256 doesn't match, builds that run but never answer (each its own
# program, as builds are known by their SHA-256), and one whose download
# address would pass curl an option. Programs are in folders: the file name
# is the fork's (redlib-<CPU>).
TS_ASSET=redlib-x86_64-unknown-linux-musl
rel() { # file age-days digest commit folder [address]
	printf '{"name":"Latest build (%s)","tag_name":"latest","assets":[{"name":"%s","created_at":"%s","browser_download_url":"%s","digest":"sha256:%s"}]}\n' \
		"$4" "$TS_ASSET" "$(date -u -d "-$2 days" +%Y-%m-%dT%H:%M:%SZ)" "${6:-http://10.0.2.2:$RPORT/$5/$TS_ASSET}" "$3" > "$W/rel/$1"
}
mkdir -p "$W/rel/g" "$W/rel/f1" "$W/rel/f2" "$W/rel/f3" "$W/rel/f4"
printf 'not a program\n' > "$W/rel/g/$TS_ASSET"
for i in 1 2 3 4; do
	printf '#!/bin/sh\n# build %s\n[ "$1" = --version ] && { echo "redlib 9.9.9"; exit 0; }\nexec sleep 600\n' "$i" > "$W/rel/f$i/$TS_ASSET"
done
sha() { sha256sum "$W/rel/$1/$TS_ASSET" | cut -d' ' -f1; }
zeros=$(printf '0%.0s' $(seq 64))
rel too-new.json 1 "$zeros" 1111111 g
rel bad-sum.json 10 "$zeros" 2222222 g
rel silent.json 10 "$(sha f1)" 9999999 f1
rel silent-too.json 10 "$(sha f2)" 9999998 f2
rel young.json 1 "$(sha f3)" 7777777 f3
rel stale-young.json 1 "$(sha f4)" 6666666 f4
rel evil.json 10 "$(sha f1)" 5555555 f1 '-K/tmp/x'
V_SILENT_TOO=$(sha f2 | cut -c1-12) V_YOUNG=$(sha f3 | cut -c1-12)
# Stand-ins for Telegram's list: an error page, and a list with one new range
# and lines that aren't ranges.
printf '<html><body>Service unavailable</body></html>\n' > "$W/rel/tg-junk.txt"
cp "$HERE/router/lists/telegram-cidr.txt" "$W/rel/tg-repo.txt"
{ cat "$HERE/router/lists/telegram-cidr.txt"; echo 10.0.2.0/24; } > "$W/rel/tg-plus-test.txt"
{ cat "$HERE/router/lists/telegram-cidr.txt"; printf '203.0.113.0/24\n300.1.1.0/24\ngarbage\n'; } > "$W/rel/tg-new.txt"
python3 -I -m http.server -b 127.0.0.1 -d "$W/rel" "$RPORT" >/dev/null 2>&1 & RPID=$!
sleep 1
kill -0 "$RPID" 2>/dev/null || { RPID=''; echo "release list stand-in did not start (port $RPORT in use?)"; exit 1; }
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
			VPN_ROUTE_DOMAINS="example.com" VPN_ROUTE_SUBNETS="198.51.100.0/24" TELEGRAM_VIA_VPN=1
			TELEGRAM_PROXY=1 TELEGRAM_PROXY_PORT=1080 TELEGRAM_PROXY_USER=telegram TELEGRAM_PROXY_PASS=0123456789abcdef01234567
			PROTON_AUTO=1 PROTON_COUNTRIES="PL CH" PROTON_API=http://10.0.2.2:$XPORT
			ENABLE_MANGADEX=1 ENABLE_REDLIB=1
			ENABLE_REMOTE=1 REMOTE_HOST='' REMOTE_PORT=51820 REMOTE_NET=10.77.0.0/24
			# 11 devices: re-runs then delete peer sections across [9]/[10]
			REMOTE_SERVER_KEY=$(wg_genkey) REMOTE_PEERS="phone|2|$(wg_genkey)|$(wg_psk)
laptop|3|$(wg_genkey)|$(wg_psk)"
			for i in 4 5 6 7 8 9 10 11 12; do REMOTE_PEERS="$REMOTE_PEERS
dev$i|$i|$(wg_genkey)|$(wg_psk)"; done
			# A network whose controller doesn't exist: the router waits for approval.
			ENABLE_ZEROTIER=1 ZEROTIER_NETWORK=$ZT_TEST_NET
			ENABLE_TAILSCALE=1
			SPEEDTEST_URL=$SPEED_URL
		else
			FAMILY_FILTER=0 ADBLOCK_EXTRA_LISTS='' BANIP_FEEDS='' ENABLE_VPN=0 ENABLE_MANGADEX=0 ENABLE_REMOTE=0 ENABLE_REDLIB=0 ENABLE_ZEROTIER=0 ENABLE_TAILSCALE=0
			unset PROTON_AUTO PROTON_COUNTRIES PROTON_API
			SQM_DOWN=50000 SQM_UP=10000   # fixed rates: nothing is measured
		fi
		write_config "$1/config.env"
	)
	if [ "$2" = full ]; then
		printf 'example.net\n' > "$1/blocklist.txt"
		printf '# test\nreddit_session=testonly\n' > "$1/redlib-sessions.txt"
		if [ -n "${TS_TEST_AUTHKEY_FILE-}" ]; then (umask 077; cp "$TS_TEST_AUTHKEY_FILE" "$1/tailscale-authkey")
		else echo tskey-auth-kTESTonlyCNTRL-0000000000000000000000000000000000 > "$1/tailscale-authkey"; fi
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
		| grep -v 'SQM latency under load' \
		| { if [ -n "${TS_TEST_AUTHKEY_FILE-}" ]; then cat; else grep -v 'Tailscale: not logged in'; fi; } || true)
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

# Redlib: a device on the LAN (a network namespace on the LAN bridge) finds
# reddit.lan and gets Redlib through port 80; only Redlib's user gets past the
# block list; the updater keeps the running version when a release is too new
# or doesn't match its SHA-256. (Reddit itself is not needed.)
redlib_checks() {
	r=$(vm_ssh 'apk add kmod-veth ip-full >/dev/null 2>&1 || exit 1
		ip link add veth0 type veth peer name veth1; ip link set veth0 master br-lan up
		ip netns add lc; ip link set veth1 netns lc; ip -n lc link set lo up; ip -n lc link set veth1 up
		ip -n lc addr add 192.168.1.60/24 dev veth1
		a=$(ip netns exec lc nslookup reddit.lan 192.168.1.1 2>/dev/null | awk "/^Address: /{print \$2}" | tail -1)
		ip netns exec lc uclient-fetch -T 10 -qO- "http://$a/settings" 2>/dev/null | grep -q "Redlib" && echo "served-at-$a"
		ip netns exec lc uclient-fetch -T 3 -qO /dev/null http://192.168.1.1:8080/settings 2>/dev/null && echo "8080-open"
		ip netns del lc; ip link del veth0 2>/dev/null
		start-stop-daemon -S -c redlib -x /usr/bin/nslookup -- example.net 2>/dev/null | awk "/^Name:/{n=1} n && /^Address/" | grep -q . && echo redlib-resolves
		start-stop-daemon -S -c nobody -x /usr/bin/nslookup -- example.net 2>/dev/null | awk "/^Name:/{n=1} n && /^Address/" | grep -q . && echo nobody-resolves
		true' 2>&1 | tr '\n' ' ')
	[ "$r" = "served-at-192.168.1.254 redlib-resolves " ] && ok "Redlib: reddit.lan serves it on port 80 to LAN devices; only its user gets past the block list" \
		|| bad "Redlib from the LAN (want 'served-at-192.168.1.254 redlib-resolves'): $r"
	# After a firmware upgrade the service comes back disabled (and procd may
	# give up after repeated memory kills): the nightly run starts it again.
	r=$(vm_ssh '/etc/init.d/redlib stop; /etc/init.d/redlib disable; /usr/sbin/redlib-update >/dev/null 2>&1; sleep 2
		/etc/init.d/redlib enabled && echo enabled; pidof redlib >/dev/null && echo running' 2>&1 | tr '\n' ' ')
	[ "$r" = "enabled running " ] && ok "Redlib: stopped and disabled (as after a firmware upgrade), the nightly update starts it again" \
		|| bad "Redlib not restarted by the update (want 'enabled running'): $r"
	for c in too-new bad-sum evil silent silent stale-young; do
		# (installed 20 days ago, and the rollback before over a week ago)
		[ $c = stale-young ] && vm_ssh 'for f in /etc/redlib.version /etc/redlib.rejected; do touch -d "$(date -d @$(( $(date +%s) - 20 * 86400 )) "+%Y-%m-%d %H:%M:%S")" $f; done'
		r=$(vm_ssh "v=\$(cat /etc/redlib.version); REDLIB_DOWNLOAD_BASE=http://10.0.2.2:$RPORT/ REDLIB_RELEASES_API=http://10.0.2.2:$RPORT/$c.json /usr/sbin/redlib-update; echo rc=\$?; [ \"\$(cat /etc/redlib.version)\" = \"\$v\" ] && { i=0; until uclient-fetch -qO- http://192.168.1.254:8080/settings 2>/dev/null | grep -q Redlib || [ \$i -ge 120 ]; do sleep 1; i=\$((i + 1)); done; [ \$i -lt 120 ]; } && echo kept" 2>&1 | tr '\n' ' ')
		case $c:$r in
			too-new:*"under 3 days old; the installed one stays"*"rc=0 kept "*) ok "Redlib update: a build under 3 days old is not taken, the running one stays" ;;
			bad-sum:*"does not match GitHub's SHA-256"*"rc=1 kept "*) ok "Redlib update: a download that doesn't match its SHA-256 is refused, the running one stays" ;;
			evil:*"unexpected download address"*"rc=1 kept "*) ok "Redlib update: a download address that isn't the fork's (here a curl option) is refused" ;;
			silent:*"put that back"*"rc=1 kept "*) ok "Redlib update: a release that doesn't answer while the old one did is rolled back" ;;
			silent:*"was rolled back before"*"rc=1 kept "*) ok "Redlib update: a rolled-back build is not tried again" ;;
			stale-young:*"over 14 days old: taking"*"put that back"*"rc=1 kept "*) ok "Redlib update: with the installed build over 14 days old, a newer one is tried although young" ;;
			*) bad "Redlib update ($c): $r" ;;
		esac
	done
	# Not answering before the update either (as when Reddit refuses Redlib):
	# the new build stays, nothing is deleted. With nothing installed, a build
	# under 3 days old is taken. Then the real one comes back (also taken at
	# once, whatever its age: nothing is installed).
	r=$(vm_ssh "/etc/init.d/redlib stop; REDLIB_DOWNLOAD_BASE=http://10.0.2.2:$RPORT/ REDLIB_RELEASES_API=http://10.0.2.2:$RPORT/silent-too.json /usr/sbin/redlib-update; echo rc=\$?
		echo v=\$(cat /etc/redlib.version); [ -x /usr/sbin/redlib ] && echo present
		/etc/init.d/redlib stop; rm -f /usr/sbin/redlib /etc/redlib.version
		REDLIB_DOWNLOAD_BASE=http://10.0.2.2:$RPORT/ REDLIB_RELEASES_API=http://10.0.2.2:$RPORT/young.json /usr/sbin/redlib-update 2>&1 | grep -o 'nothing from the fork installed yet'; echo v=\$(cat /etc/redlib.version)
		/etc/init.d/redlib stop; rm -f /usr/sbin/redlib /etc/redlib.version /etc/redlib.rejected
		/usr/sbin/redlib-update >/dev/null 2>&1; { i=0; until uclient-fetch -qO- http://192.168.1.254:8080/settings 2>/dev/null | grep -q Redlib || [ \$i -ge 120 ]; do sleep 1; i=\$((i + 1)); done; [ \$i -lt 120 ]; } && echo real-back" 2>&1 | tr '\n' ' ')
	case $r in *"not answering yet"*"rc=0 v=$V_SILENT_TOO present nothing from the fork installed yet v=$V_YOUNG real-back "*) ok "Redlib update: when nothing answered before, a new build is kept, not deleted; with nothing installed, a young build is taken (then the real one is reinstalled)" ;;
		*) bad "Redlib update without a working version to compare: $r" ;; esac
	# Reddit sessions: only the redlib user can read them; Redlib gets the file.
	r=$(vm_ssh 'ls -ld /etc/redlib | awk "{print \$1, \$3, \$4}"; ls -l /etc/redlib/sessions | awk "{print \$1, \$3, \$4}"
		start-stop-daemon -S -c redlib -x /bin/cat -- /etc/redlib/sessions 2>/dev/null | grep -q testonly && echo redlib-reads
		start-stop-daemon -S -c nobody -x /bin/cat -- /etc/redlib/sessions 2>/dev/null | grep -q testonly && echo nobody-reads
		tr "\0" "\n" < /proc/$(pidof redlib)/environ | grep -c "^REDLIB_REDDIT_COOKIE_FILE=/etc/redlib/sessions$"
		[ "$(awk "/^Gid:/ { print \$2 }" /proc/$(pidof redlib)/status)" = "$(sed -n "s/^redlib:[^:]*:\([0-9]*\):.*/\1/p" /etc/group)" ] && echo in-group
		grep -qxF /etc/redlib/ /etc/sysupgrade.conf && echo kept' 2>&1 | tr '\n' ' ')
	want="drwxr-x--- root redlib -rw-r----- root redlib redlib-reads 1 in-group kept "
	[ "$r" = "$want" ] && ok "Redlib: Reddit sessions owned by root, readable by Redlib only, passed to it, kept across upgrades" \
		|| bad "Redlib sessions file (want '$want'): $r"
	# The fork's build, with its page cache kept small.
	r=$(vm_ssh 'p=$(pidof redlib); tr "\0" "\n" < /proc/$p/environ | grep -c "^REDLIB_STALE_CACHE_MB=4$"; cat /etc/redlib.version' 2>&1 | tr '\n' ' ')
	case $r in "1 "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]" ") ok "Redlib: Nachtalb's fork (build $(echo "$r" | cut -d' ' -f2)), page cache at 4 MB" ;;
		*) bad "Redlib fork build / cache setting: $r" ;; esac
}

# Telegram through the VPN: the policy holds Telegram's ranges and pbr routes
# them; a broken download changes nothing; a new list is taken over without
# its junk lines; the repo's list puts it back.
telegram_checks() {
	r=$(vm_ssh 'p=$(uci show pbr | sed -n "s/^pbr\.\([^.]*\)\.name=.Telegram through VPN.$/\1/p"); echo "policies=$(uci show pbr | grep -c "telegram=.1.")"
		uci get pbr.$p.dest_addr | tr " " "\n" | grep -c "/" | sed "s/^/ranges=/"
		uci get pbr.$p.dest_addr | grep -q "t.me telegram.org" && echo domains
		nft list chain inet fw4 pbr_prerouting | grep -q "149.154.160.0/20" && echo routed
		grep -c telegram-ranges /etc/crontabs/root | sed "s/^/cron=/"' | tr '\n' ' ')
	case $r in "policies=2 ranges=9 domains routed cron=1 ") ok "Telegram: its 9 ranges and web domains routed through the VPN (devices and the router's proxy), refreshed daily" ;;
		*) bad "Telegram policy (want 'policies=2 ranges=9 domains routed cron=1'): $r" ;; esac
	r=$(vm_ssh "u=http://10.0.2.2:$RPORT
		p=\$(uci show pbr | sed -n \"s/^pbr\\.\\([^.]*\\)\\.name=.Telegram through VPN.\$/\\1/p\"); before=\$(uci get pbr.\$p.dest_addr)
		TELEGRAM_CIDR_URL=\$u/tg-junk.txt /usr/sbin/telegram-ranges >/dev/null 2>&1; echo junk-rc=\$?
		[ \"\$(uci get pbr.\$p.dest_addr)\" = \"\$before\" ] && echo junk-kept
		TELEGRAM_CIDR_URL=\$u/tg-new.txt /usr/sbin/telegram-ranges >/dev/null 2>&1; echo new-rc=\$?
		d=\$(uci get pbr.\$p.dest_addr); case \" \$d \" in *' 203.0.113.0/24 '*) echo new-range ;; esac
		case \" \$d \" in *300.1.1*|*garbage*) echo junk-taken ;; esac
		sleep 3; nft list chain inet fw4 pbr_prerouting | grep -q 203.0.113 && echo new-routed
		uclient-fetch -qO /tmp/tg-list.txt \$u/tg-repo.txt && /usr/sbin/telegram-ranges /tmp/tg-list.txt >/dev/null 2>&1; echo back-rc=\$?; rm -f /tmp/tg-list.txt" 2>&1 | tr '\n' ' ')
	case $r in "junk-rc=1 junk-kept new-rc=0 new-range new-routed back-rc=0 ") ok "Telegram list update: an error page changes nothing; a new range is taken over (and routed), junk lines are not" ;;
		*) bad "Telegram list update (want 'junk-rc=1 junk-kept new-rc=0 new-range new-routed back-rc=0'): $r" ;; esac
	# The VPN has no IPv6: Telegram's IPv6 ranges are rejected from the LAN.
	r=$(vm_ssh 'r=$(uci show firewall | sed -n "s/^firewall\.\([^.]*\)\.telegram=.1.$/\1/p"); echo "rules=$(echo $r | wc -w) enabled=$(uci -q get firewall.$r.enabled)"
		nft list ruleset | grep "Telegram-IPv6-not-through-VPN" | grep -q "ip6 daddr .*2001:b28:f2" && echo rejected' | tr '\n' ' ')
	case $r in "rules=1 enabled=1 rejected "|"rules=1 enabled= rejected ") ok "Telegram IPv6 (the VPN has none) is rejected from the LAN" ;;
		*) bad "Telegram IPv6 reject rule: $r" ;; esac
	# pbr refusing the new list (here: a second Telegram policy whose interface
	# doesn't exist) puts the previous list back.
	r=$(vm_ssh "u=http://10.0.2.2:$RPORT
		p=\$(uci show pbr | sed -n \"s/^pbr\\.\\([^.]*\\)\\.name=.Telegram through VPN.\$/\\1/p\"); before=\$(uci get pbr.\$p.dest_addr)
		uci add pbr policy >/dev/null; uci set pbr.@policy[-1].name=rollback-test; uci set pbr.@policy[-1].interface=testvpn; uci set pbr.@policy[-1].dest_addr=bad_domain!; uci commit pbr
		out=\$(TELEGRAM_CIDR_URL=\$u/tg-new.txt /usr/sbin/telegram-ranges 2>&1); echo \"\$out\" | grep -o 'put the previous one back'; echo rc=\$?; echo \"[\$out]\" | tr '\\n' ' '
		echo \"errors-now=[\$(ubus call service list '{\"name\":\"pbr\"}' | jsonfilter -e '@.pbr.instances.main.data.errors[*]' | tr '\\n' ' ')]\"; sleep 20
		echo \"errors-20s=[\$(ubus call service list '{\"name\":\"pbr\"}' | jsonfilter -e '@.pbr.instances.main.data.errors[*]' | tr '\\n' ' ')] delay=\$(uci -q get pbr.config.procd_reload_delay)\"; logread -e pbr | tail -4 | cut -c1-160 | tr '\\n' ' '
		[ \"\$(uci get pbr.\$p.dest_addr)\" = \"\$before\" ] && echo restored
		uci delete pbr.@policy[-1]; uci commit pbr; /etc/init.d/pbr reload >/dev/null 2>&1" 2>&1 | tr '\n' ' ')
	case $r in *"put the previous one back rc=0 "*"restored "*) ok "Telegram list update: when pbr refuses it, the previous list comes back" ;;
		*) bad "Telegram rollback when pbr refuses the list: $r" ;; esac
}

# Telegram proxy, from a LAN device. The test VPN is a dead tunnel, so curl's
# exit code tells what happened: 28 = let through and stuck in the VPN (or
# dropped), 97 = refused by the proxy. A Telegram address goes into the VPN;
# with pbr stopped it would leave directly, so it is dropped (the counter of
# that rule rises); an address that isn't Telegram's, the router's unfiltered
# DNS (5354), the router's web page and a wrong password are refused.
telegram_proxy_checks() {
	r=$(vm_ssh "px=socks5h://telegram:0123456789abcdef01234567@192.168.1.1:1080
		ip link add veth2 type veth peer name veth3; ip link set veth2 master br-lan up
		ip netns add pc; ip link set veth3 netns pc; ip -n pc link set lo up; ip -n pc link set veth3 up; ip -n pc addr add 192.168.1.61/24 dev veth3
		t() { ip netns exec pc curl -s -m 6 -o /dev/null -x \$1 \$2; echo \"\$3=\$?\"; }
		w() { i=0; until ip route show table pbr_testvpn 2>/dev/null | grep -q default || [ \$i -ge 30 ]; do sleep 1; i=\$((i + 1)); done; sleep 2; }
		w   # pbr may still be rebuilding its tables after the checks before
		rj() { nft list chain inet fw4 oneclick_telegram_proxy | sed -n 's/.*packets \([0-9]*\).*reject.*/\1/p'; }
		# (the dead test VPN may make pbr refuse it itself: what counts is that
		# the proxy's own rules let it through)
		r0=\$(rj); ip netns exec pc curl -s -m 6 -o /dev/null -x \$px http://149.154.167.99/; [ \"\$(rj)\" = \"\$r0\" ] && echo telegram-let-through
		d0=\$(nft list chain inet fw4 oneclick_telegram_proxy_vpn | sed -n 's/.*packets \([0-9]*\).*/\1/p')
		/etc/init.d/pbr stop >/dev/null 2>&1; t \$px http://149.154.167.99/ telegram-without-vpn
		[ \"\$(nft list chain inet fw4 oneclick_telegram_proxy_vpn | sed -n 's/.*packets \([0-9]*\).*/\1/p')\" -gt \"\$d0\" ] && echo dropped-outside-vpn
		/etc/init.d/pbr start >/dev/null 2>&1; w
		t \$px http://192.0.2.1/ other
		t \$px http://127.0.0.1:5354/ router-dns
		t \$px http://192.168.1.1/ router-web
		t socks5h://telegram:wrong@192.168.1.1:1080 http://149.154.167.99/ wrong-password
		ip netns del pc" 2>&1 | tr '\n' ' ')
	want="telegram-let-through telegram-without-vpn=28 dropped-outside-vpn other=97 router-dns=97 router-web=97 wrong-password=97 "
	if [ "$r" = "$want" ]; then ok "Telegram proxy (from a LAN device): only Telegram, only through the VPN, only with the password"
	else
		bad "Telegram proxy (want '$want'): $r"
		vm_ssh 'nft list chain inet fw4 oneclick_telegram_proxy; nft list set inet fw4 oneclick_telegram4 | grep -c 149.154; uci show pbr | grep -E "telegram=|chain=|\.interface="; ls -l /etc/nftables.d/' 2>&1 | sed 's/^/        | /'
	fi
}

# A firmware upgrade keeps the files in /etc/sysupgrade.conf, and switches
# on only the packages' services. Checked: the upgrade backup would hold the
# setup's files. Then what an upgrade drops is dropped by hand (LuCI's
# index.html with the manga.lan redirect, adblock-lean and Redlib switched
# off, the Redlib program, the firmware mark); after a reboot it's all back.
upgrade_checks() {
	r=$(vm_ssh 'sysupgrade -l > /tmp/keep
		for f in /usr/sbin/oneclick-after-upgrade /etc/safesearch/google.domains /etc/init.d/adblock-lean /etc/init.d/redlib \
			/usr/sbin/redlib-update /usr/sbin/telegram-ranges /etc/rc.local /etc/oneclick-vpn-aaaa.applied /etc/crontabs/root \
			/etc/redlib.conf /etc/nftables.d/30-oneclick-redlib-dns.nft /etc/nftables.d/31-oneclick-telegram-proxy.nft \
			/usr/sbin/safesearch-hosts /usr/sbin/redlib-block /etc/redlib-block.allow /etc/banip/banip.custom.feeds \
			/usr/sbin/tailscaled /usr/sbin/tailscale /etc/init.d/tailscale /etc/nftables.d/32-oneclick-tailscale-dns.nft \
			$(find /etc/adblock-lean /usr/lib/adblock-lean /www/mangadex-safe /www/cgi-bin/md /etc/proton /usr/share/proton-pick \
				/usr/sbin/proton-pick /etc/proton-pick.conf /etc/tailscale -type f 2>/dev/null); do
			grep -qxF "$f" /tmp/keep || echo "not-kept:$f"
		done
		grep -qxF /etc/oneclick-firmware /tmp/keep && echo mark-kept
		grep -c "oneclick-after-upgrade boot" /etc/rc.local' 2>&1 | tr '\n' ' ')
	[ "$r" = "1 " ] && ok "firmware upgrade: the backup keeps the setup's files; rc.local starts the after-upgrade fixes" \
		|| bad "firmware upgrade keep list (want '1'): $r"
	vm_ssh '/etc/init.d/redlib stop; /etc/init.d/redlib disable; /etc/init.d/adblock-lean stop; /etc/init.d/adblock-lean disable
		/etc/init.d/tailscale stop; /etc/init.d/tailscale disable
		rm -f /usr/sbin/redlib /etc/redlib.version /etc/oneclick-firmware; sed -i "/safe-otaku: manga.lan/d" /www/index.html
		reboot' >/dev/null 2>&1
	sleep 20; i=0 r=''
	while [ $i -lt 60 ]; do
		r=$(vm_ssh 'grep -q "safe-otaku: manga.lan" /www/index.html && echo redirect
			/etc/init.d/adblock-lean enabled && /etc/init.d/adblock-lean status >/dev/null 2>&1 && echo adblock
			/etc/init.d/redlib enabled && pidof redlib >/dev/null && echo redlib
			/etc/init.d/tailscale enabled && pidof tailscaled >/dev/null && echo tailscale
			[ "$(cat /etc/oneclick-firmware 2>/dev/null)" = "$(. /etc/openwrt_release; echo "$DISTRIB_REVISION")" ] && echo marked
			true' 2>/dev/null | tr '\n' ' ')
		[ "$r" = "redirect adblock redlib tailscale marked " ] && break
		sleep 10; i=$((i + 1))
	done
	[ "$r" = "redirect adblock redlib tailscale marked " ] && ok "firmware upgrade (simulated): after the reboot manga.lan redirect, adblock-lean, Redlib and Tailscale are back" \
		|| bad "after the simulated upgrade (want 'redirect adblock redlib tailscale marked'; Redlib comes from GitHub, whose API allows 60 calls an hour): $r"
	# On later boots of the same firmware it changes nothing: adblock-lean
	# switched off by hand stays off.
	r=$(vm_ssh '/etc/init.d/adblock-lean disable; /usr/sbin/oneclick-after-upgrade boot; /etc/init.d/adblock-lean enabled && echo re-enabled
		/etc/init.d/adblock-lean enable; true' 2>&1 | tr '\n' ' ')
	[ -z "$r" ] && ok "after-upgrade fixes run once per firmware: a service switched off by hand stays off" || bad "after-upgrade on a later boot: $r"
}

# ZeroTier: joined (waiting for approval: the test network has no
# controller), its interfaces in their own zone, the public example network
# gone, the identity saved on the laptop and only readable by root.
ZT_TEST_NET=deadbeef00c0ffee
zerotier_checks() {
	r=$(vm_ssh "pidof zerotier-one >/dev/null && echo running
		zerotier-cli -j info | jsonfilter -e @.online
		uci -q get zerotier.oneclick.id; uci show zerotier | grep -c '=network'
		uci show zerotier | grep -c 8056c2e21c000001
		ls -l /etc/config/zerotier | cut -c1-10
		uci -q get firewall.@zone[0].device | grep -q zt && echo in-lan
		z=\$(uci show firewall | sed -n \"s/^firewall\\.\\([^.]*\\)\\.name='zerotier'\$/\\1/p\")
		echo zone=\$(uci -q get firewall.\$z.device)/\$(uci -q get firewall.\$z.input)/\$(uci -q get firewall.\$z.forward)
		uci show firewall | grep -c \"\\.src='zerotier'\"
		nft list chain inet fw4 forward_zerotier >/dev/null 2>&1 && echo chain
		nft list chain inet fw4 forward_zerotier 2>/dev/null | grep -c accept_to
		zerotier-cli -j listnetworks | jsonfilter -e '@[*].id'" 2>&1 | tr '\n' ' ')
	want="running true $ZT_TEST_NET 1 0 -rw------- zone=zt+/ACCEPT/REJECT 0 chain 0 $ZT_TEST_NET "
	[ "$r" = "$want" ] && ok "ZeroTier: online, joins only that network, own zone that forwards nowhere, settings readable by root only" \
		|| bad "ZeroTier on the router (want '$want'): $r"
	grep -q "^INFO  ZeroTier: router [0-9a-f]\{10\} waits for approval" "$W/full.log" && ok "ZeroTier: report asks to approve the router" \
		|| bad "ZeroTier report: $(grep ZeroTier "$W/full.log" | tr '\n' ' ')"
	node=$(vm_ssh 'zerotier-cli -j info | jsonfilter -e @.address')
	f=$P/zerotier/identity.secret
	if [ -f "$f" ] && [ "$(stat -c %a "$f")" = 600 ] && [ "$(cut -d: -f1 "$f")" = "$node" ]; then ok "ZeroTier: the router's identity saved in private/ (mode 600)"
	else bad "ZeroTier identity on the laptop: node $node, file $(ls -l "$f" 2>&1)"; fi
	grep -q "approve the router at https://my.zerotier.com" "$W/full.log" && ok "ZeroTier: setup.sh says what to approve" || bad "ZeroTier: no approval hint from setup.sh"
}

# Tailscale: running in its own group, whose DNS lookups go past the block
# lists (tailscale_dns_used, right after the setup run), its own zone forwarding only into the VPN, its files kept across
# upgrades. Then a stand-in for the tailscale0 device (a veth with a "phone"
# behind it, 100.100.100.2): Telegram goes into the VPN (a counter on that
# forwarding rises), other addresses are refused, and with pbr stopped Telegram is
# refused too (it would leave through the WAN). Then telegram-ranges hands a
# changed list to Tailscale.
# The DNS rule's counter rose during the setup run: Tailscale's lookups went
# through it (it also has built-in fallback addresses, so reaching its
# servers alone wouldn't show it). Read right after the run: firewall
# reloads in later checks reset counters, and once connected Tailscale
# looks nothing up again.
tailscale_dns_used() {
	vm_ssh 'nft list chain inet fw4 oneclick_tailscale_dns' 2>&1 | grep -q "counter packets [1-9]" \
		&& ok "Tailscale's DNS lookups went through its own rule (past the block lists)" \
		|| bad "Tailscale's DNS rule counted nothing: $(vm_ssh 'nft list chain inet fw4 oneclick_tailscale_dns' 2>&1 | grep counter)"
}
tailscale_checks() {
	r=$(vm_ssh 'p=$(pidof tailscaled); [ -n "$p" ] && echo running
		[ "$(awk "/^Gid:/ { print \$2 }" /proc/$p/status)" = "$(sed -n "s/^tailscale:[^:]*:\([0-9]*\):.*/\1/p" /etc/group)" ] && echo own-group
		/etc/init.d/tailscale enabled && echo enabled
		ls -ld /etc/tailscale | cut -c1-10
		z=$(uci show firewall | sed -n "s/^firewall\.\([^.]*\)\.name=.tailscale.$/\1/p")
		echo zone=$(uci -q get firewall.$z.device)/$(uci -q get firewall.$z.input)/$(uci -q get firewall.$z.forward)
		uci show firewall | grep -c "src=.tailscale."
		nft list chain inet fw4 forward_tailscale | grep -c "jump accept_to_testvpn"
		nft list chain inet fw4 oneclick_tailscale_dns | grep -q "skgid.*redirect to :5354" && echo dns-rule' 2>&1 | tr '\n' ' ')
	want="running own-group enabled drwx------ zone=tailscale0/ACCEPT/REJECT 1 1 dns-rule "
	[ "$r" = "$want" ] && ok "Tailscale: runs in its own group, own zone that forwards only into the VPN, state readable by root only" \
		|| bad "Tailscale on the router (want '$want'): $r"
	if [ -n "${TS_TEST_AUTHKEY_FILE-}" ]; then
		grep -q '^PASS  Tailscale: the router is 100\.' "$W/full.log" && ok "Tailscale: logged in with the test key" || bad "Tailscale login: $(grep 'Tailscale' "$W/full.log" | tr '\n' ' ')"
	else
		grep -qi '^FAIL  Tailscale: not logged in (.*invalid key' "$W/full.log" && ok "Tailscale: reached its servers (they refused the dummy key)" \
			|| bad "Tailscale with the dummy key (want: refused as invalid): $(grep 'Tailscale' "$W/full.log" | tr '\n' ' ')"
	fi
	r=$(vm_ssh 'nslookup controlplane.tailscale.com 127.0.0.1 2>/dev/null | awk "/^Name:/{n=1} n && /^Address/" | grep -q . && echo resolves || echo blocked')
	[ "$r" = blocked ] && ok "tailscale.com stays blocked for the LAN (the router's Tailscale alone skips the list)" || bad "tailscale.com for the LAN: $r"
	r=$(vm_ssh "apk add ip-full >/dev/null 2>&1   # BusyBox ip can't make veth pairs
		/etc/init.d/tailscale stop; sleep 2; ip link del tailscale0 2>/dev/null
		ip link add tailscale0 type veth peer name tsp; ip link set tailscale0 up
		ip netns add ph; ip link set tsp netns ph; ip -n ph link set lo up; ip -n ph link set tsp up
		ip -n ph addr add 100.100.100.2/32 dev tsp; ip addr add 100.100.100.1/32 dev tailscale0
		ip -n ph route add 100.100.100.1 dev tsp; ip -n ph route add default via 100.100.100.1
		ip route add 100.100.100.2/32 dev tailscale0
		w() { i=0; until ip route show table pbr_testvpn 2>/dev/null | grep -q default || [ \$i -ge 30 ]; do sleep 1; i=\$((i + 1)); done; sleep 2; }
		nft insert rule inet fw4 forward_tailscale oifname testvpn counter   # a probe: packets forwarded into the VPN
		tx() { nft list chain inet fw4 forward_tailscale | sed -n 's/.*oifname \"testvpn\" counter packets \([0-9]*\).*/\1/p'; }
		t() { ip netns exec ph curl -s -m 4 -o /dev/null http://\$1/; echo \"\$2=\$?\"; }
		w; a=\$(tx); ip netns exec ph curl -s -m 4 -o /dev/null http://149.154.167.99/; c=\$?; [ \"\$(tx)\" -gt \"\$a\" ] && echo telegram-into-vpn || echo \"telegram=\$c probe=\$a/\$(tx)\"
		a=\$(tx); t 198.18.0.1 other; [ \"\$(tx)\" = \"\$a\" ] && echo other-not-in-vpn
		t 192.168.1.50 lan-device
		/etc/init.d/pbr stop >/dev/null 2>&1; a=\$(tx); t 149.154.167.99 telegram-without-pbr; [ \"\$(tx)\" = \"\$a\" ] && echo not-in-vpn
		/etc/init.d/pbr start >/dev/null 2>&1; w
		ip netns del ph; ip link del tailscale0 2>/dev/null; fw4 reload >/dev/null 2>&1; /etc/init.d/tailscale start" 2>&1 | tr '\n' ' ')
	want="telegram-into-vpn other=7 other-not-in-vpn lan-device=7 telegram-without-pbr=7 not-in-vpn "
	[ "$r" = "$want" ] && ok "Tailscale (stand-in device): Telegram goes into the VPN; other addresses, LAN devices, and Telegram without the VPN rules, are refused" \
		|| bad "Tailscale forwarding (want '$want'): $r"
	r=$(vm_ssh "f=/etc/tailscale/oneclick-routes; [ -f \$f ] && cp \$f /tmp/routes.bak
		i=0; until /usr/sbin/tailscale status --json >/dev/null 2>&1 || [ \$i -ge 30 ]; do sleep 1; i=\$((i + 1)); done
		echo 1.2.3.0/24 > \$f
		uclient-fetch -qO /tmp/tg.txt http://10.0.2.2:$RPORT/tg-repo.txt && /usr/sbin/telegram-ranges /tmp/tg.txt >/dev/null 2>&1; rm -f /tmp/tg.txt
		grep -c 149.154.160.0/20 \$f; grep -c 1.2.3.0 \$f
		if [ -f /tmp/routes.bak ]; then mv /tmp/routes.bak \$f; else rm -f \$f; fi" 2>&1 | tr '\n' ' ')
	[ "$r" = "1 0 " ] && ok "telegram-ranges hands a changed list to Tailscale" || bad "telegram-ranges -> Tailscale routes (want '1 0'): $r"
}

scenario_full() {
	echo "== full: every option on"
	start_vm; P=$W/p-full; make_private "$P" full
	shape_line
	run_setup "$P" "$W/full.log"
	tailscale_dns_used
	abl_check
	zerotier_checks
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
	redlib_checks
	telegram_checks
	telegram_proxy_checks
	tailscale_checks
	upgrade_checks
	# Family filtering with no Redlib instance allowed still blocks them all
	# (BusyBox's grep -vxF -f dropped every line when the allow list was empty).
	r=$(vm_ssh 'cp /etc/redlib-block.allow /tmp/allow.bak; : > /etc/redlib-block.allow; /usr/sbin/redlib-block
		awk "/^# >>> redlib\$/{s=1;next} /^# <<< redlib\$/{s=0} s" /etc/adblock-lean/blocklist | grep -c .
		cp /tmp/allow.bak /etc/redlib-block.allow; /usr/sbin/redlib-block' 2>&1 | tail -1)
	[ "${r:-0}" -ge 1 ] 2>/dev/null && ok "Redlib block list with nothing allowed: $r instances blocked" || bad "Redlib block list with an empty allow list: $r"
	r=$(ONECLICK_PRIVATE=$P "$W/kids.sh" 127.0.0.1 "$PORT" 2>&1)
	case $r in *PASS*) ok "kids.sh: $r" ;; *) bad "kids.sh: $r" ;; esac
	# A kid's device can't be given Redlib's address; the rules in place stay.
	cp -R "$P" "$W/p-kids254"
	printf '%s\n' "DEVICES='TV|02:00:00:00:00:01|192.168.1.254'" "CUTOFF_START='21:30:00'" "CUTOFF_STOP='05:30:00'" > "$W/p-kids254/kids.conf"
	r=$(ONECLICK_PRIVATE=$W/p-kids254 "$W/kids.sh" 127.0.0.1 "$PORT" 2>&1)
	n=$(vm_ssh 'uci show firewall | grep -c "name=.kids time restriction."')
	case $r in *"address for Redlib"*) [ "$n" = 1 ] && ok "kids.sh refuses Redlib's address for a device; existing rules stay" || bad "kids.sh 254: rules after refusal: $n" ;;
		*) bad "kids.sh accepted Redlib's address: $r" ;; esac
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
	# ZeroTier: a router that lost its identity gets the saved one back;
	# networks added by hand are dropped (the setup manages ZeroTier).
	vm_ssh "uci delete zerotier.global.secret; uci set zerotier.home=network; uci set zerotier.home.id=feedfacecafe0002; uci commit zerotier"
	run_setup "$P" "$W/full-rerun.log"
	r=$(vm_ssh "zerotier-cli -j info | jsonfilter -e @.address; uci show zerotier | grep -c '=network'; uci -q get zerotier.oneclick.id" | tr '\n' ' ')
	[ "$r" = "$(cut -d: -f1 "$P/zerotier/identity.secret") 1 $ZT_TEST_NET " ] && ok "ZeroTier re-run: the saved identity comes back; only the settings' network" \
		|| bad "ZeroTier re-run (want '$(cut -d: -f1 "$P/zerotier/identity.secret") 1 $ZT_TEST_NET'): $r"
	r=$(vm_ssh 'uci show pbr | grep -c "telegram=.1."; grep -c telegram-ranges /etc/crontabs/root' | tr '\n' ' ')
	[ "$r" = "2 1 " ] && ok "re-run: two Telegram policies (devices, proxy), one daily job" || bad "re-run Telegram duplicates (policy cron): $r"
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
	# (one FAIL in the report), and the router still blocks. The same run turns
	# only the Telegram proxy off (the VPN and Telegram stay on).
	# shellcheck disable=SC2034  # write_config reads the settings through eval
	(. "$P/config.env"; TELEGRAM_PROXY=0; write_config "$P/config.env")
	vm_ssh 'echo "0.0.0.0 api.github.com" >> /etc/hosts'
	ONECLICK_PRIVATE=$P timeout 1500 "$W/setup.sh" 127.0.0.1 "$PORT" > "$W/full-nogh.log" 2>&1; rc=$?
	vm_ssh 'sed -i "/api.github.com/d" /etc/hosts; /etc/init.d/dnsmasq restart >/dev/null 2>&1'
	other=$(grep '^FAIL' "$W/full-nogh.log" | sort -u | grep -v 'VPN WireGuard handshake\|SQM speed test failed.*429\|kept the installed adblock-lean' \
		| { if [ -n "${TS_TEST_AUTHKEY_FILE-}" ]; then cat; else grep -v 'Tailscale: not logged in'; fi; })
	if [ "$rc" = 2 ] && [ -z "$other" ] && grep -q '^FAIL.*kept the installed adblock-lean' "$W/full-nogh.log" \
		&& grep -q '^PASS  adblock-lean blocklist loaded' "$W/full-nogh.log"; then
		ok "GitHub unreachable: kept the installed adblock-lean, still blocking"
	else
		bad "GitHub unreachable: exit $rc; other FAILs: $other"; tail -8 "$W/full-nogh.log" | sed 's/^/        | /'
	fi
	left=$(vm_ssh 'pidof microsocks >/dev/null && echo running; apk info -e microsocks >/dev/null 2>&1 && echo package
		[ -e /etc/config/microsocks ] && echo config; [ -e /etc/nftables.d/31-oneclick-telegram-proxy.nft ] && echo rules
		echo "telegram-policies=$(uci show pbr | grep -c "telegram=.1.")"' | tr '\n' ' ')
	[ "$left" = "telegram-policies=1 " ] && ok "Telegram proxy turned off (VPN still on): package, config with its password, rules and router policy removed; Telegram for devices stays" \
		|| bad "Telegram proxy off (want 'telegram-policies=1'): $left"
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
	k=$(vm_ssh "nft list ruleset | grep 'kids router pages'")
	case $k in *"ether saddr"*) case $k in *"dport { 80, 443, 8080 }"*) ok "kids: the router's own pages (reddit.lan, manga.lan, LuCI) are cut off too" ;;
		*) bad "kids router-pages rule ports: $k" ;; esac ;; *) bad "kids router-pages rule: $k" ;; esac

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
		ENABLE_VPN=0 ENABLE_MANGADEX=0 ENABLE_REMOTE=0 ENABLE_REDLIB=0 ENABLE_ZEROTIER=0 ENABLE_TAILSCALE=0
		SSH_KEY_OLD=$SSH_KEY SSH_PUBKEYS_OLD=$SSH_PUBKEYS SSH_KEY=$W/key2 SSH_PUBKEYS=$(cat "$W/key2.pub")
		write_config "$P/config.env"
	)
	printf "PROTON_UID='uid-test'\nPROTON_REFRESH='refresh-x'\n" > "$P/proton-session"
	run_setup "$P" "$W/full-off.log"
	[ -f "$P/proton-session" ] && ok "Proton: with the VPN off the laptop session is not sent and stays" || bad "Proton: laptop session deleted though the VPN is off"
	VM_KEY=$W/key2   # the router now only knows the new key
	left=$(vm_ssh 'uci show network | grep -c testvpn; uci show firewall | grep -c "name=.testvpn."; uci -q get dhcp.@dnsmasq[0].address | grep -c "::"' | tr '\n' ' ')
	[ "$left" = "0 0 0 " ] && ok "VPN turned off: interface, zone and IPv6 suppression removed" || bad "VPN leftovers (network firewall aaaa): $left"
	left=$(vm_ssh 'uci show pbr | grep -c "telegram=.1."; grep -c telegram-ranges /etc/crontabs/root' | tr '\n' ' ')
	[ "$left" = "0 0 " ] && ok "VPN turned off: Telegram policy and its daily job removed" || bad "Telegram leftovers (policy cron): $left"
	left=$(vm_ssh 'pidof microsocks >/dev/null && echo running; apk info -e microsocks >/dev/null 2>&1 && echo package
		[ -e /etc/nftables.d/31-oneclick-telegram-proxy.nft ] && echo rules; uci show pbr | grep -q "chain=.output." && echo policy; true' | tr '\n' ' ')
	[ -z "$left" ] && ok "VPN turned off: Telegram proxy, its rules and policy removed" || bad "Telegram proxy leftovers: $left"
	left=$(vm_ssh 'pidof redlib >/dev/null && echo process
		for f in /usr/sbin/redlib /usr/sbin/redlib-update /etc/init.d/redlib /etc/redlib.conf /etc/redlib.version /etc/nftables.d/30-oneclick-redlib-dns.nft /etc/redlib; do [ -e $f ] && echo $f; done
		grep -q "^redlib:" /etc/passwd /etc/group /etc/shadow && echo user
		uci -q get network.redlib >/dev/null && echo address
		uci show firewall | grep -q "name=.Redlib." && echo redirect
		nft list chain inet fw4 oneclick_redlib_dns >/dev/null 2>&1 && echo dns-rule
		grep -q redlib-update /etc/crontabs/root && echo cron
		grep -qE "^/(etc/init.d/redlib|usr/sbin/redlib-update|etc/redlib.conf|etc/nftables.d/30-oneclick-redlib-dns.nft)$" /etc/sysupgrade.conf && echo sysupgrade
		uci show dhcp | grep -q "name=.reddit.lan." && echo reddit.lan
		ip -4 addr | grep -q "192.168.1.254" && echo ip
		true' | tr '\n' ' ')
	[ -z "$left" ] && ok "Redlib turned off: program, files, user, address, rules, cron and name removed" || bad "Redlib leftovers: $left"
	left=$(vm_ssh 'pidof zerotier-one >/dev/null && echo running; apk info -e zerotier >/dev/null 2>&1 && echo package
		[ -e /etc/config/zerotier ] && echo config; uci show firewall | grep -q "zt+" && echo zone; true' | tr '\n' ' ')
	[ -z "$left" ] && ok "ZeroTier turned off: package, settings with the private key, firewall zone removed" || bad "ZeroTier leftovers: $left"
	left=$(vm_ssh 'pidof tailscaled >/dev/null && echo running; ip link show tailscale0 >/dev/null 2>&1 && echo device
		for f in /usr/sbin/tailscaled /usr/sbin/tailscale /etc/init.d/tailscale /etc/tailscale /etc/nftables.d/32-oneclick-tailscale-dns.nft; do [ -e $f ] && echo $f; done
		grep -q "^tailscale:" /etc/group && echo group; uci show firewall | grep -q "tailscale" && echo zone
		nft list chain inet fw4 oneclick_tailscale_dns >/dev/null 2>&1 && echo dns-rule; grep -q tailscale /etc/sysupgrade.conf && echo sysupgrade; true' | tr '\n' ' ')
	[ -z "$left" ] && ok "Tailscale turned off: program, state, group, zone, DNS rule and upgrade entries removed" || bad "Tailscale leftovers: $left"
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
		[ -e /etc/init.d/redlib ] && echo "redlib"
		apk info -e microsocks >/dev/null 2>&1 && echo "microsocks"
		apk info -e zerotier >/dev/null 2>&1 && echo "zerotier"
		[ -e /usr/sbin/tailscaled ] && echo "tailscale"
		apk info -e kmod-tun >/dev/null 2>&1 && echo "kmod-tun"
		apk info -e bind-dig >/dev/null 2>&1 && echo "bind-dig"
		apk info -e openssl-util >/dev/null 2>&1 && echo "openssl-util"
		true')
	[ -z "$r" ] && ok "nothing optional installed" || bad "optional parts present: $(echo $r)"
	# A ZeroTier set up by hand (zt+ in the lan zone, its own network): with
	# the option on the setup takes it over (its identity kept, only the
	# settings' network, zt+ moved to the ZeroTier zone).
	vm_ssh 'apk add zerotier >/dev/null 2>&1; uci set zerotier.global.enabled=1; uci set zerotier.mine=network
		uci set zerotier.mine.id=feedfacecafe0001; uci commit zerotier; /etc/init.d/zerotier restart
		uci set firewall.@zone[0].device=zt+; uci commit firewall; fw4 reload' >/dev/null 2>&1   # a single option, not a list
	i=0 node=''; until [ -n "$node" ] || [ $i -ge 30 ]; do sleep 1; i=$((i + 1)); node=$(vm_ssh 'uci -q get zerotier.global.secret | cut -d: -f1'); done
	# shellcheck disable=SC2034  # write_config reads the settings through eval
	(. "$P/config.env"; ENABLE_ZEROTIER=1 ZEROTIER_NETWORK=$ZT_TEST_NET; write_config "$P/config.env")
	run_setup "$P" "$W/minimal-zt.log"
	r=$(vm_ssh 'uci show zerotier | sed -n "s/^zerotier\.\([^.]*\)=network$/\1/p"; uci -q get zerotier.global.secret | cut -d: -f1
		uci -q get firewall.@zone[0].device | grep -q zt && echo in-lan; uci show firewall | grep -c "name=.zerotier."' | tr '\n' ' ')
	[ -n "$node" ] && [ "$r" = "oneclick $node 1 " ] && ok "ZeroTier set up by hand: taken over (identity kept, only the settings' network, zt+ from the lan zone to its own)" \
		|| bad "ZeroTier taken over (want 'oneclick ${node:-<identity>} 1'): $r"
	# ZeroTier in a zone in a form the setup doesn't manage: stopped before any change.
	vm_ssh 'uci set network.ztif=interface; uci set network.ztif.proto=none; uci set network.ztif.device=zt1234567890
		uci commit network; uci add_list firewall.@zone[0].network=ztif; uci commit firewall'
	out=$(ONECLICK_PRIVATE=$P timeout 600 "$W/setup.sh" 127.0.0.1 "$PORT" 2>&1); rc=$?
	case $out in *"ZeroTier interfaces are in firewall zones"*) case $out in *"==> Packages"*) bad "ZeroTier in lan zone: refused only after changes began" ;;
			*) [ $rc = 1 ] && ok "ZeroTier interface added to the lan zone by hand: setup stops before changing anything" || bad "ZeroTier in lan zone: exit $rc" ;; esac ;;
		*) bad "ZeroTier interface in the lan zone not refused (exit $rc)" ;; esac
	vm_ssh 'uci del_list firewall.@zone[0].network=ztif; uci commit firewall; uci delete network.ztif; uci commit network'
	# The same for Tailscale: its device put in the lan zone by hand.
	vm_ssh 'uci add_list firewall.@zone[0].device=tailscale0; uci commit firewall'
	echo tskey-auth-kTESTonlyCNTRL-0000 > "$P/tailscale-authkey"
	# shellcheck disable=SC2034
	(. "$P/config.env"; ENABLE_TAILSCALE=1; write_config "$P/config.env")
	out=$(ONECLICK_PRIVATE=$P timeout 900 "$W/setup.sh" 127.0.0.1 "$PORT" 2>&1); rc=$?
	case $out in *"Tailscale's interface is in firewall zones"*) case $out in *"==> Packages"*) bad "Tailscale in lan zone: refused only after changes began" ;;
			*) [ $rc = 1 ] && ok "Tailscale's device added to the lan zone by hand: setup stops before changing anything" || bad "Tailscale in lan zone: exit $rc" ;; esac ;;
		*) bad "Tailscale's device in the lan zone not refused (exit $rc): $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')" ;; esac
	vm_ssh 'uci del_list firewall.@zone[0].device=tailscale0; uci commit firewall'
	# shellcheck disable=SC2034
	(. "$P/config.env"; ENABLE_TAILSCALE=0; write_config "$P/config.env")
	rm -f "$P/tailscale-authkey"
	# shellcheck disable=SC2034
	(. "$P/config.env"; ENABLE_ZEROTIER=0; write_config "$P/config.env")
	run_setup "$P" "$W/minimal-zt-off.log"
	r=$(vm_ssh 'apk info -e zerotier >/dev/null 2>&1 && echo package; [ -e /etc/config/zerotier ] && echo config
		pidof zerotier-one >/dev/null && echo running; uci show firewall | grep -c "zt"' | tr '\n' ' ')
	[ "$r" = "0 " ] && ok "ZeroTier option off: package, settings and zone removed" || bad "ZeroTier off after take-over (want '0'): $r"
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
