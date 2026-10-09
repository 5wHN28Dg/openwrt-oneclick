#!/bin/sh
# End-to-end test on a throwaway OpenWrt VM (qemu, KVM if available). Never
# touches a real router: the VM's LAN is only reachable on localhost ports.
#
#   tests/vm.sh [full|minimal|both]     (default: both)
#
# full:    every option on, then kids.sh, setup.sh again (no duplicates), a
#          different host key (refused), and a re-run with the VPN off
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
	(
		WIFI_SSID=TestNet WIFI_KEY="it's a test" WIFI_ENCRYPTION=sae-mixed
		ROOT_PASSWORD_HASH=$(printf test | openssl passwd -5 -stdin)
		SSH_KEY=$W/key SSH_PUBKEYS=$(cat "$W/key.pub")
		TZ_NAME=Europe/Berlin TZ_POSIX=$(posix_tz Europe/Berlin)
		WAN_PROTO=dhcp LINK_TYPE=fiber SQM_FALLBACK_DOWN=100000 SQM_FALLBACK_UP=20000
		if [ "$2" = full ]; then
			FAMILY_FILTER=1 BANIP_FEEDS="doh vpn" REDLIB_ALLOW=safereddit.com
			ADBLOCK_LISTS="hagezi:pro hagezi:tif.mini hagezi:nsfw hagezi:nosafesearch hagezi:doh-vpn-proxy-bypass"
			ENABLE_VPN=1 VPN_IFACE=testvpn WG_PRIVATE_KEY=$(wgkey) WG_PEER_PUBLIC_KEY=$(wgkey)
			WG_ADDRESSES=10.66.0.2/32 WG_DNS=10.66.0.1 WG_ENDPOINT_HOST=192.0.2.1 WG_ENDPOINT_PORT=51820
			WG_ALLOWED_IPS="0.0.0.0/0 ::/0" WG_KEEPALIVE=25
			VPN_ROUTE_DOMAINS="example.com" VPN_ROUTE_SUBNETS="198.51.100.0/24"
			ENABLE_MANGADEX=1
		else
			FAMILY_FILTER=0 ADBLOCK_LISTS="hagezi:pro" BANIP_FEEDS= ENABLE_VPN=0 ENABLE_MANGADEX=0
		fi
		write_config "$1/config.env"
	)
	if [ "$2" = full ]; then
		printf 'example.net\n' > "$1/blocklist.txt"
		printf '%s\n' "DEVICES='TV|02:00:00:00:00:01|192.168.1.150'" "CUTOFF_START='21:30:00'" "CUTOFF_STOP='05:30:00'" > "$1/kids.conf"
	fi
}

vm_ssh() { # uses the host keys setup.sh saved, or accepts a fresh one
	ssh -p "$PORT" -i "$W/key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
		-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR root@127.0.0.1 "$@"
}

run_setup() { # private-dir log
	ONECLICK_PRIVATE=$1 timeout 1500 "$W/setup.sh" 127.0.0.1 "$PORT" > "$2" 2>&1
	rc=$?
	unexpected=$(grep '^FAIL' "$2" | sort -u \
		| grep -v 'VPN WireGuard handshake' \
		| grep -v 'SQM speed test failed.*HTTP codes: 429' || true)
	if [ -z "$unexpected" ] && [ "$rc" -le 2 ]; then
		ok "setup.sh ($(basename "$2" .log)): exit $rc, $(grep -c '^PASS' "$2") PASS, only expected FAILs"
	else
		bad "setup.sh ($(basename "$2" .log)): exit $rc"; printf '%s\n' "$unexpected" | sed 's/^/        /'
		tail -15 "$2" | sed 's/^/        | /'
	fi
	grep -q 'SQM speed test failed.*429' "$2" && echo "      note: Cloudflare rate limit hit; measured SQM path not exercised"
}

scenario_full() {
	echo "== full: every option on"
	start_vm; P=$W/p-full; make_private "$P" full
	run_setup "$P" "$W/full.log"
	r=$(ONECLICK_PRIVATE=$P "$W/kids.sh" 127.0.0.1 "$PORT" 2>&1)
	case $r in *PASS*) ok "kids.sh: $r" ;; *) bad "kids.sh: $r" ;; esac
	ONECLICK_PRIVATE=$P "$W/kids.sh" 127.0.0.1 "$PORT" >/dev/null 2>&1
	run_setup "$P" "$W/full-rerun.log"
	counts=$(vm_ssh 'printf "%s %s %s %s %s %s\n" \
		"$(uci show firewall | grep -c "name=.testvpn.")" \
		"$(uci show firewall | grep -c "name=.Block-WireGuard-LAN.")" \
		"$(uci show dhcp | grep -c "name=.manga.lan.")" \
		"$(grep -c safesearch-hosts /etc/crontabs/root)" \
		"$(uci show network | grep -c "=wireguard_testvpn")" \
		"$(uci show firewall | grep -c "name=.kids time restriction.")"')
	[ "$counts" = "1 1 1 1 1 1" ] && ok "re-run: no duplicates" || bad "re-run duplicates (zone rule domain cron peer kids): $counts"
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

	# Turning the VPN off on a re-run removes its interface too.
	sed -i 's/^ENABLE_VPN=.*/ENABLE_VPN='"'"'0'"'"'/' "$P/config.env"
	run_setup "$P" "$W/full-novpn.log"
	left=$(vm_ssh 'uci show network | grep -c testvpn; uci show firewall | grep -c "name=.testvpn."' | tr '\n' ' ')
	[ "$left" = "0 0 " ] && ok "VPN turned off: interface and zone removed" || bad "VPN leftovers after turning it off (network firewall): $left"
}

scenario_minimal() {
	echo "== minimal: every option off"

	start_vm; P=$W/p-min; make_private "$P" minimal
	run_setup "$P" "$W/minimal.log"
	r=$(vm_ssh '
		[ -e /www/mangadex-safe ] && echo "mangadex installed"
		uci -q get network.vpn >/dev/null && echo "vpn interface"
		apk info -e luci-proto-wireguard >/dev/null 2>&1 && echo "wireguard package"
		/etc/init.d/pbr enabled 2>/dev/null && echo "pbr enabled"
		grep -q safesearch-hosts /etc/crontabs/root && echo "safe-search cron"
		nft list ruleset | grep -q Block-WireGuard-LAN && echo "vpn-protocol blocks"
		grep -q "nsfw" /etc/adblock-lean/config && echo "nsfw list"
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
