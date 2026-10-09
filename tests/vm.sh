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
#
# Expected FAILs (the test checks these are the only ones):
#   - "VPN WireGuard handshake": the test peer is a documentation address.
#   - "SQM speed test failed" with HTTP 429: Cloudflare rate-limits repeated
#     speed tests from one IP for about an hour; the saved rates are used.

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/lib/laptop.sh"
VER=${OPENWRT_VERSION:-25.12.5}
PORT=${VM_SSH_PORT:-2222}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/openwrt-oneclick
IMG=openwrt-$VER-x86-64-generic-squashfs-combined.img
W=$(mktemp -d)
QPID=
cleanup() { [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; rm -rf "$W"; }
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
			ENABLE_MANGADEX=1
			ENABLE_REMOTE=1 REMOTE_HOST='' REMOTE_PORT=51820 REMOTE_NET=10.77.0.0/24
			# 11 devices: re-runs then delete peer sections across [9]/[10]
			REMOTE_SERVER_KEY=$(wg_genkey) REMOTE_PEERS="phone|2|$(wg_genkey)|$(wg_psk)
laptop|3|$(wg_genkey)|$(wg_psk)"
			for i in 4 5 6 7 8 9 10 11 12; do REMOTE_PEERS="$REMOTE_PEERS
dev$i|$i|$(wg_genkey)|$(wg_psk)"; done
		else
			FAMILY_FILTER=0 ADBLOCK_EXTRA_LISTS='' BANIP_FEEDS='' ENABLE_VPN=0 ENABLE_MANGADEX=0 ENABLE_REMOTE=0
		fi
		write_config "$1/config.env"
	)
	if [ "$2" = full ]; then
		printf 'example.net\n' > "$1/blocklist.txt"
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
		| grep -v 'SQM speed test failed.*HTTP codes: 429' || true)
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

scenario_full() {
	echo "== full: every option on"
	start_vm; P=$W/p-full; make_private "$P" full
	run_setup "$P" "$W/full.log"
	abl_check
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
	r=$(ONECLICK_PRIVATE=$P "$W/kids.sh" 127.0.0.1 "$PORT" 2>&1)
	case $r in *PASS*) ok "kids.sh: $r" ;; *) bad "kids.sh: $r" ;; esac
	r=$(ONECLICK_PRIVATE=$P "$W/kids.sh" --remove 127.0.0.1 "$PORT" 2>&1)
	[ "$(vm_ssh 'uci show firewall | grep -c "kids time restriction"')" = 0 ] && ok "kids.sh --remove: $r" || bad "kids.sh --remove left rules: $r"
	ONECLICK_PRIVATE=$P "$W/kids.sh" 127.0.0.1 "$PORT" >/dev/null 2>&1
	g=$(vm_ssh 'nslookup -type=a www.google.de 127.0.0.1 | awk "/^Address: /{print \$2}" | tail -1')
	[ "$g" = 216.239.38.120 ] && ok "safe search on a Google country domain (www.google.de)" || bad "www.google.de -> $g"
	a=$(vm_ssh 'nslookup -type=aaaa example.com 127.0.0.1 | awk "/^Address: /{print \$2}" | tail -1')
	[ "$a" = "::" ] && ok "VPN domain has no IPv6 answer (VPN has no IPv6)" || bad "VPN domain AAAA: $a"
	run_setup "$P" "$W/full-rerun.log"

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
	run_setup "$P" "$W/full-off.log"
	VM_KEY=$W/key2   # the router now only knows the new key
	left=$(vm_ssh 'uci show network | grep -c testvpn; uci show firewall | grep -c "name=.testvpn."; uci -q get dhcp.@dnsmasq[0].address | grep -c "::"' | tr '\n' ' ')
	[ "$left" = "0 0 0 " ] && ok "VPN turned off: interface, zone and IPv6 suppression removed" || bad "VPN leftovers (network firewall aaaa): $left"
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
