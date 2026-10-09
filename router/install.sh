#!/bin/sh
# Sets up a fresh OpenWrt router from ../private/config.env (see setup.sh).
# Runs on the router. Hardware-specific values (WAN device, radios) and the
# internet type (IPv4 with NAT, IPv6) are detected here, not assumed.

set -u
umask 022
ROUTER=$(cd "$(dirname "$0")" && pwd)
PRIV=$ROUTER/../private
. "$PRIV/config.env"

REPORT=/tmp/setup-report.txt
: > "$REPORT"
pass() { echo "PASS  $1" | tee -a "$REPORT"; }
fail() { echo "FAIL  $1" | tee -a "$REPORT"; }
info() { echo "INFO  $1" | tee -a "$REPORT"; }
step() { echo; echo "==> $1"; }
die()  { fail "$1"; echo; cat "$REPORT"; exit 1; }
on()   { [ "${1:-0}" = 1 ]; }

VPN=${VPN_IFACE:-vpn}
case $VPN in *[!a-z0-9_]*|'') echo "VPN_IFACE must be lowercase letters, digits or _"; exit 1 ;; esac
RESERVED=' lan wan wan6 wan_6 loopback remote '
case $RESERVED in *" $VPN "*) echo "VPN_IFACE '$VPN' is reserved"; exit 1 ;; esac
if [ -n "$VPN" ] && uci -q get "network.$VPN" >/dev/null && [ "$(uci -q get "network.$VPN.setup")" != 1 ]; then
	echo "VPN_IFACE '$VPN' is an existing interface not made by this tool; pick another name"; exit 1
fi
on "${ENABLE_VPN:-0}" || VPN=
LAN_IP=$(uci get network.lan.ipaddr | cut -d/ -f1)
REMOTE=; on "${ENABLE_REMOTE:-0}" && REMOTE=1

# curl: SQM speed test (streamed upload); gawk, sed, coreutils-sort: adblock-lean's
# fast list processing; dnsmasq-full: nftset support for pbr and adblock-lean.
PACKAGES="luci luci-ssl luci-app-attendedsysupgrade owut luci-app-banip luci-app-sqm
	dnsmasq-full dnsproxy curl gawk sed coreutils-sort"
[ -n "$VPN$REMOTE" ] && PACKAGES="$PACKAGES luci-proto-wireguard"
[ -n "$VPN" ] && PACKAGES="$PACKAGES luci-app-pbr"
[ "${WAN_PROTO:-dhcp}" = pppoe ] && PACKAGES="$PACKAGES ppp-mod-pppoe luci-proto-ppp"

# Copy files only: never apply directory modes to system directories like /etc.
put_tree() { # SRC-DIR
	(cd "$1" && find . -type f) | while read -r f; do
		f=${f#./}
		mkdir -p "/${f%/*}"
		cp -p "$1/$f" "/$f"
		chown root:root "/$f"
	done
}

# ---------------------------------------------------------------- internet
step "Internet"
[ -f /etc/openwrt_release ] || die "not an OpenWrt system"
. /etc/openwrt_release
info "OpenWrt $DISTRIB_RELEASE on $(ubus call system board | jsonfilter -e '@.model')"
if command -v apk >/dev/null; then PKG=apk; elif command -v opkg >/dev/null; then PKG=opkg; else die "no package manager"; fi

if [ "${WAN_PROTO:-dhcp}" = pppoe ]; then
	uci set network.wan.proto=pppoe
	uci set "network.wan.username=$PPPOE_USER"
	uci set "network.wan.password=$PPPOE_PASS"
	uci set network.wan.setup_pppoe=1
	uci commit network
	ifup wan
elif [ "$(uci -q get network.wan.setup_pppoe)" = 1 ]; then   # PPPoE turned off since the last run
	uci set network.wan.proto=dhcp
	uci -q delete network.wan.username; uci -q delete network.wan.password; uci -q delete network.wan.setup_pppoe
	uci commit network
	ifup wan
fi

online4() { ping -4 -c1 -W3 1.1.1.1 >/dev/null 2>&1; }
online6() { ping -6 -c1 -W3 2606:4700:4700::1111 >/dev/null 2>&1; }
i=0
until online4 || online6; do
	i=$((i + 1)); [ $i -ge 30 ] && die "no internet after 90 s (WAN cable in the internet box? PPPoE details right?)"
	sleep 3
done
wan_dev() { ubus call network.interface."$1" status 2>/dev/null | jsonfilter -e '@.l3_device'; }
WAN_DEV=$(wan_dev wan); [ -n "$WAN_DEV" ] || WAN_DEV=$(wan_dev wan6)

# IPv4 behind this router's NAT? Usable IPv6 (global address + default route + reachability)?
HAS_V4=; online4 && [ -n "$(ubus call network.interface.wan status | jsonfilter -e '@["ipv4-address"][0].address')" ] && HAS_V4=1
has_v6() { online6 && ip -6 route show default | grep -q . && ip -6 addr show scope global | grep -q inet6; }
HAS_V6=; has_v6 && HAS_V6=1
yes_no() { if [ -n "$1" ]; then echo "$2"; else echo "$3"; fi; }
pass "online via $WAN_DEV: IPv4 $(yes_no "$HAS_V4" 'yes (NAT)' no), IPv6 $(yes_no "$HAS_V6" yes no)"

i=0
until [ "$(date +%Y)" -ge 2026 ]; do   # TLS needs a sane clock
	i=$((i + 1)); [ $i -ge 20 ] && die "clock not synced (NTP), downloads would fail"
	/etc/init.d/sysntpd restart >/dev/null 2>&1; sleep 3
done

# ---------------------------------------------------------------- packages
step "Packages"
if [ $PKG = apk ]; then
	apk update >/dev/null 2>&1 || die "apk update failed"
	# shellcheck disable=SC2086
	apk add $PACKAGES >/tmp/setup-pkg.log 2>&1 || { tail -5 /tmp/setup-pkg.log; die "package install failed (/tmp/setup-pkg.log)"; }
else
	opkg update >/dev/null 2>&1 || die "opkg update failed"
	# Download dnsmasq-full while the old dnsmasq still answers DNS, then swap.
	(cd /tmp && opkg download dnsmasq-full >/dev/null 2>&1) || die "opkg download dnsmasq-full failed"
	OPKG_PACKAGES=$(echo $PACKAGES | sed 's/dnsmasq-full//')
	# shellcheck disable=SC2086
	opkg install $OPKG_PACKAGES >/tmp/setup-pkg.log 2>&1 || die "package install failed (/tmp/setup-pkg.log)"
	opkg remove dnsmasq >/dev/null 2>&1
	opkg install /tmp/dnsmasq-full_*.ipk >>/tmp/setup-pkg.log 2>&1 || die "dnsmasq-full install failed (/tmp/setup-pkg.log)"
fi
# dnsmasq-full replaces dnsmasq but isn't started; keep the router's own DNS working.
/etc/init.d/dnsmasq enable; /etc/init.d/dnsmasq restart >/dev/null 2>&1
pass "installed: $(echo $PACKAGES | tr -s ' \t\n' ' ')"

# ---------------------------------------------------------------- adblock-lean
# Fetched from its project on every run, so it starts out current. Its default
# config is generated the way its own setup does it without questions (the
# path LuCI uses): the preset, and with it the base lists and size limits,
# follows the router's memory. Our extra lists are added on top.
step "adblock-lean"
ABL_INSTALLER=https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh
uclient-fetch -q -O /tmp/abl-install.sh "$ABL_INSTALLER" || die "could not download $ABL_INSTALLER"
DO_DIALOGS=0 sh /tmp/abl-install.sh -v release >/tmp/setup-abl.log 2>&1 \
	|| { tail -5 /tmp/setup-abl.log; die "adblock-lean install failed (/tmp/setup-abl.log)"; }
rm -f /tmp/abl-install.sh
rm -f /etc/adblock-lean/config   # a fresh default config each run
DO_DIALOGS=0 luci_preset=auto luci_upd_cron_job=1 luci_cron_schedule='0 5 * * *' \
	/etc/init.d/adblock-lean gen_config >>/tmp/setup-abl.log 2>&1 && [ -s /etc/adblock-lean/config ] \
	|| { tail -5 /tmp/setup-abl.log; die "adblock-lean gen_config failed (/tmp/setup-abl.log)"; }
ABL_VER=$(sed -n 's/^ABL_VERSION="\(.*\)"$/\1/p' /etc/init.d/adblock-lean)
abl_get() { sed -n "s/^$1=\"\(.*\)\"\$/\1/p" /etc/adblock-lean/config; }
abl_set() { sed -i "s|^$1=.*|$1=\"$2\"|" /etc/adblock-lean/config; }
ABL_BASE=$(abl_get raw_block_lists)
case ${ADBLOCK_EXTRA_LISTS-} in *[!A-Za-z0-9:._/\ -]*) die "ADBLOCK_EXTRA_LISTS has unexpected characters" ;; esac
ABL_LISTS=$ABL_BASE
for l in ${ADBLOCK_EXTRA_LISTS-}; do case " $ABL_LISTS " in *" $l "*) ;; *) ABL_LISTS="$ABL_LISTS $l" ;; esac; done
abl_set raw_block_lists "$ABL_LISTS"
# The preset's size limit is sized for its own lists; the family lists add
# about 100,000 entries (1.6 MB), so make room for them at adblock-lean's
# own 25 bytes per entry. Other extra lists have to fit in what is left.
if on "${FAMILY_FILTER:-0}"; then
	abl_set max_blocklist_file_size_KB $(( $(abl_get max_blocklist_file_size_KB) + 2500 ))
fi
pass "adblock-lean $ABL_VER from github.com/lynxthecat/adblock-lean; lists for this router: $ABL_BASE${ADBLOCK_EXTRA_LISTS:+; added: $ADBLOCK_EXTRA_LISTS}"

# ---------------------------------------------------------------- files
step "Files"
put_tree "$ROUTER/files"
if on "${ENABLE_MANGADEX:-0}"; then put_tree "$ROUTER/vendor/safe-otaku"; chmod 755 /www/cgi-bin/md; fi
chmod 755 /usr/sbin/safesearch-hosts /usr/sbin/redlib-block

# adblock-lean local lists: own entries + project sections
section() { # NAME FILE -> marked section, if the file has entries
	[ -s "$2" ] || return 0
	echo "# >>> $1"; grep -vE '^[[:space:]]*(#|$)' "$2"; echo "# <<< $1"
}
{
	[ -f "$PRIV/blocklist.txt" ] && grep -vE '^[[:space:]]*(#|$)' "$PRIV/blocklist.txt"
	on "${FAMILY_FILTER:-0}" && section safe-otaku "$ROUTER/lists/safe-otaku-block.txt"
} > /etc/adblock-lean/blocklist
{
	[ -f "$PRIV/allowlist.txt" ] && grep -vE '^[[:space:]]*(#|$)' "$PRIV/allowlist.txt"
	on "${FAMILY_FILTER:-0}" && section safe-otaku "$ROUTER/lists/safe-otaku-allow.txt"
	# The bypass lists block VPN providers; keep our own VPN's endpoint name resolvable.
	if [ -n "$VPN" ] && ! echo "$WG_ENDPOINT_HOST" | grep -qE '^[0-9.]+$|:'; then
		echo "# >>> vpn-endpoint"; echo "$WG_ENDPOINT_HOST"; echo "# <<< vpn-endpoint"
	fi
} > /etc/adblock-lean/allowlist
printf '%s\n' ${REDLIB_ALLOW-} > /etc/redlib-block.allow

# banIP: hardware-specific device, IPv6 only where usable, feeds from the settings
uci -q delete banip.global.ban_dev; uci add_list banip.global.ban_dev="$WAN_DEV"
uci -q delete banip.global.ban_ifv4; uci add_list banip.global.ban_ifv4=wan
uci -q delete banip.global.ban_ifv6
uci -q delete banip.global.ban_feed
for f in ${BANIP_FEEDS-}; do uci add_list banip.global.ban_feed="$f"; done
uci commit banip   # IPv6 coverage is set after the network restart, once IPv6 had time to come up
MEM_KB=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
if [ "${MEM_KB:-0}" -lt 200000 ]; then   # 128 MB class: small caches, the block lists need the room
	uci set dnsproxy.cache.size=4194304; uci commit dnsproxy; DNS_CACHE=2000
else
	DNS_CACHE=10000
fi
pass "copied adblock-lean lists, banIP, dnsproxy and safe-search files${ENABLE_MANGADEX:+$(on "$ENABLE_MANGADEX" && echo ', MangaDex app')}"

# ---------------------------------------------------------------- access
step "Access"
sed -i "s|^root:[^:]*:|root:${ROOT_PASSWORD_HASH}:|" /etc/shadow
# Keep keys added by hand; replace the previous key of this tool when it changed.
touch /etc/dropbear/authorized_keys
{
	grep -vxF -e "$SSH_PUBKEYS" ${SSH_PUBKEYS_OLD:+-e "$SSH_PUBKEYS_OLD"} /etc/dropbear/authorized_keys
	printf '%s\n' "$SSH_PUBKEYS"
} > /tmp/setup-authkeys && cat /tmp/setup-authkeys > /etc/dropbear/authorized_keys; rm -f /tmp/setup-authkeys
chmod 600 /etc/dropbear/authorized_keys
if [ -f "$PRIV/host_keys/dropbear_ed25519_host_key" ]; then
	for k in "$PRIV"/host_keys/dropbear_*_host_key; do cp "$k" /etc/dropbear/; done
	chmod 600 /etc/dropbear/dropbear_*_host_key
	HOSTKEYS="restored saved SSH host keys"
else
	HOSTKEYS="new SSH host keys"
fi
pass "root password, SSH key login, $HOSTKEYS"

# ---------------------------------------------------------------- system
step "System"
uci batch >/dev/null <<-EOF
	set system.@system[0].log_size='128'
	delete system.ntp.server
	add_list system.ntp.server='216.239.35.0'
	add_list system.ntp.server='216.239.35.4'
	add_list system.ntp.server='162.159.200.123'
	add_list system.ntp.server='162.159.200.1'
	add_list system.ntp.server='2001:4860:4806::'
	add_list system.ntp.server='2606:4700:f1::1'
	set network.globals.packet_steering='2'
EOF
uci set "system.@system[0].zonename=${TZ_NAME:-UTC}"
uci set "system.@system[0].timezone=${TZ_POSIX:-UTC0}"
uci commit system
[ -n "${ULA_PREFIX-}" ] && uci set network.globals.ula_prefix="$ULA_PREFIX"
uci commit network
pass "time zone ${TZ_NAME:-UTC}, NTP by IP (no DNS needed), packet steering on all CPUs"

# ---------------------------------------------------------------- VPN
# VPN interfaces from earlier runs (tagged setup=1) go first, also when the VPN
# is now off or renamed.
for i in $(uci -q show network | sed -n "s/^network\.\([^.]*\)\.setup='1'$/\1/p"); do
	for s in $(uci -q show network | sed -n "s/^network\.\(@wireguard_$i\[[0-9]*\]\)=.*/\1/p" | sort -r); do uci delete "network.$s"; done
	uci delete "network.$i"
done
uci commit network
if [ -n "$VPN" ]; then
	step "VPN ($VPN)"
	uci -q delete "network.$VPN"
	for s in $(uci -q show network | sed -n "s/^network\.\(@wireguard_$VPN\[[0-9]*\]\)=.*/\1/p" | sort -r); do uci delete "network.$s"; done
	uci set "network.$VPN=interface"
	uci set "network.$VPN.proto=wireguard"
	uci set "network.$VPN.setup=1"
	uci set "network.$VPN.private_key=$WG_PRIVATE_KEY"
	uci set "network.$VPN.multipath=off"
	uci add network "wireguard_$VPN" >/dev/null
	uci set "network.@wireguard_${VPN}[-1].description=VPN peer"
	uci set "network.@wireguard_${VPN}[-1].public_key=$WG_PEER_PUBLIC_KEY"
	uci set "network.@wireguard_${VPN}[-1].endpoint_host=$WG_ENDPOINT_HOST"
	uci set "network.@wireguard_${VPN}[-1].endpoint_port=$WG_ENDPOINT_PORT"
	uci set "network.@wireguard_${VPN}[-1].persistent_keepalive=${WG_KEEPALIVE:-25}"
	for a in ${WG_ADDRESSES-}; do uci add_list "network.$VPN.addresses=$a"; done
	for a in ${WG_DNS-}; do uci add_list "network.$VPN.dns=$a"; done
	for a in ${WG_ALLOWED_IPS:-0.0.0.0/0 ::/0}; do uci add_list "network.@wireguard_${VPN}[-1].allowed_ips=$a"; done
	[ -n "${WG_PRESHARED_KEY-}" ] && uci set "network.@wireguard_${VPN}[-1].preshared_key=$WG_PRESHARED_KEY"
	uci commit network

	# PBR: only the chosen domains and ranges go through the VPN
	for s in $(uci -q show pbr | sed -n "s/^pbr\.\([^.]*\)\.setup='1'$/\1/p" | sort -r); do uci delete "pbr.$s"; done
	policy() { # name dest
		uci add pbr policy >/dev/null
		uci set pbr.@policy[-1].setup=1
		uci set "pbr.@policy[-1].name=$1"
		uci set "pbr.@policy[-1].dest_addr=$2"
		uci set "pbr.@policy[-1].interface=$VPN"
	}
	[ -n "${VPN_ROUTE_DOMAINS-}" ] && policy 'domains through VPN' "$VPN_ROUTE_DOMAINS"
	[ -n "${VPN_ROUTE_SUBNETS-}" ] && policy 'IP ranges through VPN' "$VPN_ROUTE_SUBNETS"
	uci commit pbr
	[ -z "${VPN_ROUTE_DOMAINS-}${VPN_ROUTE_SUBNETS-}" ] && info "VPN set up, but no domains or ranges are routed through it"
	# IPv6 to the VPN domains must not go around the VPN: route it through the
	# VPN when the VPN has IPv6, otherwise answer their AAAA queries with ::
	# (no address) so devices use IPv4, which pbr sends through the VPN.
	if echo "${WG_ADDRESSES-}" | grep -q ':'; then
		uci set pbr.config.ipv6_enabled=1
	else
		uci set pbr.config.ipv6_enabled=0
		for d in ${VPN_ROUTE_DOMAINS-}; do echo "/$d/::"; done > /etc/oneclick-vpn-aaaa
	fi
	uci commit pbr
	pass "WireGuard $VPN to $WG_ENDPOINT_HOST; PBR: ${VPN_ROUTE_DOMAINS:-no domains}${VPN_ROUTE_SUBNETS:+ + IP ranges}"
fi

# ---------------------------------------------------------------- remote access
# WireGuard server: devices outside reach the home network and the router's
# DNS (so manga.lan) through it. The interface joins the lan zone below.
# Earlier runs' interface and peers (tagged setup_remote=1) go first.
if [ "$(uci -q get network.remote.setup_remote)" = 1 ]; then
	for s in $(uci -q show network | sed -n "s/^network\.\(@wireguard_remote\[[0-9]*\]\)=.*/\1/p" | sort -r); do uci delete "network.$s"; done
	uci delete network.remote
	uci commit network
fi
ip2int() { # a.b.c.d -> integer
	echo "$1" | { IFS=. read -r a b c d; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
}
if [ -n "$REMOTE" ]; then
	step "Remote access"
	uci -q get network.remote >/dev/null && die "an interface 'remote' exists that this tool did not make; rename it first"
	lan_st=$(ubus call network.interface.lan status)
	lan_sub=$(echo "$lan_st" | jsonfilter -e '@["ipv4-address"][0].address')/$(echo "$lan_st" | jsonfilter -e '@["ipv4-address"][0].mask')
	case $lan_sub in /*|*/) lan_sub=$LAN_IP/24 ;; esac
	# The tunnel range must not overlap the LAN (compare at the shorter prefix).
	p=${lan_sub#*/}; [ "$p" -gt 24 ] && p=24
	m=$(( (0xffffffff << (32 - p)) & 0xffffffff ))
	[ $(( $(ip2int "${lan_sub%/*}") & m )) -eq $(( $(ip2int "${REMOTE_NET%/*}") & m )) ] \
		&& die "REMOTE_NET $REMOTE_NET overlaps the LAN $lan_sub; pick another range"
	RNET=${REMOTE_NET%.0/24}
	uci batch >/dev/null <<-EOF
		set network.remote=interface
		set network.remote.proto='wireguard'
		set network.remote.setup_remote='1'
		set network.remote.private_key='$REMOTE_SERVER_KEY'
		set network.remote.listen_port='$REMOTE_PORT'
		add_list network.remote.addresses='$RNET.1/24'
	EOF
	printf '%s\n' "$REMOTE_PEERS" | while IFS='|' read -r name n key psk; do
		[ -n "$name" ] || continue
		uci batch >/dev/null <<-EOF
			add network wireguard_remote
			set network.@wireguard_remote[-1].description='$name'
			set network.@wireguard_remote[-1].public_key='$(printf '%s' "$key" | wg pubkey)'
			set network.@wireguard_remote[-1].preshared_key='$psk'
			add_list network.@wireguard_remote[-1].allowed_ips='$RNET.$n/32'
		EOF
	done
	uci commit network
	REMOTE_N=$(printf '%s\n' "$REMOTE_PEERS" | grep -c .)
	pass "WireGuard server on UDP $REMOTE_PORT, $REMOTE_N devices in $REMOTE_NET, reaching $lan_sub"
fi

# ---------------------------------------------------------------- firewall
step "Firewall"
# Remove what this script added before, so re-runs don't duplicate.
for s in $(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.setup='1'$/\1/p" | sort -r); do uci delete "firewall.$s"; done
uci -q delete firewall.dns_int
uci -q delete firewall.dot_fwd
LAN_ZONE=$(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.name='lan'$/\1/p" | head -1)
[ -n "$LAN_ZONE" ] && uci -q del_list "firewall.$LAN_ZONE.network=remote"
uci batch >/dev/null <<-EOF
	set firewall.@defaults[0].flow_offloading='1'
	set firewall.dns_int=redirect
	set firewall.dns_int.name='Intercept-DNS'
	set firewall.dns_int.family='any'
	set firewall.dns_int.proto='tcp udp'
	set firewall.dns_int.src='lan'
	set firewall.dns_int.src_dport='53'
	set firewall.dns_int.target='DNAT'
EOF
if on "${FAMILY_FILTER:-0}"; then
	rule() { # name proto port
		uci batch >/dev/null <<-EOF
			add firewall rule
			set firewall.@rule[-1].setup='1'
			set firewall.@rule[-1].name='$1'
			set firewall.@rule[-1].src='lan'
			set firewall.@rule[-1].dest='wan'
			set firewall.@rule[-1].proto='$2'
			set firewall.@rule[-1].target='REJECT'
		EOF
		[ -n "$3" ] && uci set firewall.@rule[-1].dest_port="$3"
	}
	uci batch >/dev/null <<-EOF
		set firewall.dot_fwd=rule
		set firewall.dot_fwd.name='Deny-DoT'
		set firewall.dot_fwd.proto='tcp udp'
		set firewall.dot_fwd.src='lan'
		set firewall.dot_fwd.dest='wan'
		set firewall.dot_fwd.dest_port='853'
		set firewall.dot_fwd.target='REJECT'
	EOF
	rule 'Block-WireGuard-LAN'   udp 51820
	rule 'Block-OpenVPN-LAN'     'tcp udp' 1194
	rule 'Block-IKEv2-IPsec-LAN' udp '500 4500'
	rule 'Block-L2TP-LAN'        udp 1701
	rule 'Block-PPTP-LAN'        tcp 1723
	rule 'Block-GRE-LAN'         gre ''
fi
if [ -n "$VPN" ]; then
	uci batch >/dev/null <<-EOF
		add firewall zone
		set firewall.@zone[-1].setup='1'
		set firewall.@zone[-1].name='$VPN'
		set firewall.@zone[-1].input='REJECT'
		set firewall.@zone[-1].output='ACCEPT'
		set firewall.@zone[-1].forward='REJECT'
		set firewall.@zone[-1].masq='1'
		set firewall.@zone[-1].mtu_fix='1'
		add_list firewall.@zone[-1].network='$VPN'
		add firewall forwarding
		set firewall.@forwarding[-1].setup='1'
		set firewall.@forwarding[-1].src='lan'
		set firewall.@forwarding[-1].dest='$VPN'
	EOF
fi
if [ -n "$REMOTE" ]; then
	[ -n "$LAN_ZONE" ] || die "no firewall zone named lan"
	uci add_list "firewall.$LAN_ZONE.network=remote"
	uci batch >/dev/null <<-EOF
		add firewall rule
		set firewall.@rule[-1].setup='1'
		set firewall.@rule[-1].name='Allow-Remote-WireGuard'
		set firewall.@rule[-1].src='wan'
		set firewall.@rule[-1].proto='udp'
		set firewall.@rule[-1].dest_port='$REMOTE_PORT'
		set firewall.@rule[-1].target='ACCEPT'
	EOF
fi
uci commit firewall
pass "DNS hijack${FAMILY_FILTER:+$(on "$FAMILY_FILTER" && echo ', DoT and VPN-protocol blocks')}${VPN:+, $VPN zone}${REMOTE:+, remote access in the lan zone}"

# ---------------------------------------------------------------- DNS
step "Encrypted DNS"
/etc/init.d/dnsproxy enable
/etc/init.d/dnsproxy restart >/dev/null 2>&1
i=0
until nslookup openwrt.org 127.0.0.1:5354 >/dev/null 2>&1; do
	i=$((i + 1)); [ $i -ge 15 ] && die "dnsproxy does not answer on 127.0.0.1:5354; dnsmasq left unchanged"
	sleep 2
done
pass "dnsproxy answers on 127.0.0.1:5354 (Cloudflare h3, NextDNS, Quad9)"

step "dnsmasq"
for s in $(uci -q show dhcp | sed -n "s/^dhcp\.\([^.]*\)\.setup='1'$/\1/p" | sort -r); do uci delete "dhcp.$s"; done
uci batch >/dev/null <<-EOF
	set dhcp.@dnsmasq[0].cachesize='$DNS_CACHE'
	set dhcp.@dnsmasq[0].noresolv='1'
	set dhcp.@dnsmasq[0].min_cache_ttl='3600'
	set dhcp.@dnsmasq[0].max_cache_ttl='86400'
	delete dhcp.@dnsmasq[0].server
	add_list dhcp.@dnsmasq[0].server='127.0.0.1#5354'
	add_list dhcp.@dnsmasq[0].server='::1#5354'
	delete dhcp.@dnsmasq[0].addnmount
	add_list dhcp.@dnsmasq[0].addnmount='/bin/busybox'
	add_list dhcp.@dnsmasq[0].addnmount='/var/run/adblock-lean/abl-blocklist.gz'
	add_list dhcp.@dnsmasq[0].addnmount='/var/run/pbr.dnsmasq'
EOF
# AAAA suppression for VPN domains: drop what an earlier run added, add the current set.
if [ -f /etc/oneclick-vpn-aaaa.applied ]; then
	while read -r a; do uci -q del_list "dhcp.@dnsmasq[0].address=$a"; done < /etc/oneclick-vpn-aaaa.applied
	rm -f /etc/oneclick-vpn-aaaa.applied
fi
if [ -n "$VPN" ] && [ -s /etc/oneclick-vpn-aaaa ]; then
	while read -r a; do uci add_list "dhcp.@dnsmasq[0].address=$a"; done < /etc/oneclick-vpn-aaaa
	mv /etc/oneclick-vpn-aaaa /etc/oneclick-vpn-aaaa.applied
fi
rm -f /etc/oneclick-vpn-aaaa
domain() { # name ip
	uci batch >/dev/null <<-EOF
		add dhcp domain
		set dhcp.@domain[-1].setup='1'
		set dhcp.@domain[-1].name='$1'
		set dhcp.@domain[-1].ip='$2'
	EOF
}
if on "${FAMILY_FILTER:-0}"; then
	for d in yandex.com yandex.ru yandex.by yandex.kz yandex.ua; do domain "$d" 213.180.193.56; done
fi
on "${ENABLE_MANGADEX:-0}" && domain manga.lan "$LAN_IP"
uci commit dhcp
on "${FAMILY_FILTER:-0}" || rm -f /tmp/hosts/safesearch
/etc/init.d/dnsmasq restart >/dev/null 2>&1
if on "${FAMILY_FILTER:-0}"; then
	/usr/sbin/safesearch-hosts
	pass "dnsmasq forwards to dnsproxy; safe search pinned (Google in all $(wc -l < /etc/safesearch/google.domains) country domains, Bing, DuckDuckGo, Startpage, Brave, Yandex)"
else
	pass "dnsmasq forwards to dnsproxy"
fi

# ---------------------------------------------------------------- MangaDex app
if ! on "${ENABLE_MANGADEX:-0}"; then   # turned off since an earlier run: remove it
	rm -rf /www/mangadex-safe /www/cgi-bin/md
	sed -i '/safe-otaku: manga.lan/d' /www/index.html
	if [ "$(uci -q get uhttpd.main.setup_maxreq)" = 1 ]; then
		uci set uhttpd.main.max_requests=3; uci -q delete uhttpd.main.setup_maxreq; uci commit uhttpd
	fi
fi
if on "${ENABLE_MANGADEX:-0}"; then
	step "MangaDex app"
	uci set uhttpd.main.max_requests='6'; uci set uhttpd.main.setup_maxreq=1; uci commit uhttpd
	grep -q 'safe-otaku: manga.lan' /www/index.html || sed -i 's|<head>|<head>\n\t\t<script>/* safe-otaku: manga.lan opens the MangaDex safe app */ if (location.hostname === "manga.lan") location.replace("/mangadex-safe/");</script>|' /www/index.html
	pass "MangaDex reader at http://manga.lan (uhttpd max_requests 6)"
fi

# ---------------------------------------------------------------- Wi-Fi
step "Wi-Fi"
APS=$(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-iface$/\1/p")
if [ -z "$APS" ]; then
	info "no Wi-Fi radios on this device, skipped"
else
	for ap in $APS; do
		radio=$(uci get "wireless.$ap.device")
		uci set "wireless.$ap.ssid=$WIFI_SSID"
		uci set "wireless.$ap.key=$WIFI_KEY"
		uci set "wireless.$ap.encryption=${WIFI_ENCRYPTION:-sae-mixed}"
		uci set "wireless.$ap.ocv=0"
		uci set "wireless.$radio.disabled=0"
		uci set "wireless.$radio.cell_density=0"
		uci set "wireless.$radio.country=$WIFI_COUNTRY"
		case "$(uci get "wireless.$radio.band")" in
			6g) uci set "wireless.$ap.encryption=sae" ;;   # 6 GHz allows WPA3 only
			2g) uci set "wireless.$radio.channel=auto"; uci set "wireless.$radio.htmode=HT20" ;;
			5g) iwinfo "$(uci -q get "wireless.$radio.phy" || echo "$radio")" htmodelist 2>/dev/null | grep -qw HE80 \
					&& uci set "wireless.$radio.htmode=HE80" ;;
		esac
	done
	uci commit wireless
	pass "Wi-Fi '$WIFI_SSID' on: $(echo $APS)"
fi

# ---------------------------------------------------------------- jobs, upgrade persistence
step "Scheduled jobs"
touch /etc/crontabs/root
sed -i '/safesearch-hosts\|redlib-block/d' /etc/crontabs/root
sed -i '/safesearch-hosts/d' /etc/rc.local
if on "${FAMILY_FILTER:-0}"; then
	echo "*/30 * * * * /usr/sbin/safesearch-hosts" >> /etc/crontabs/root
	# Before adblock-lean's 05:00 update, which loads the refreshed Redlib section.
	echo "50 4 * * * /usr/sbin/redlib-block" >> /etc/crontabs/root
	sed -i 's|^exit 0$|(sleep 30; /usr/sbin/safesearch-hosts) \&\nexit 0|' /etc/rc.local
fi
for f in /usr/sbin/safesearch-hosts /usr/sbin/redlib-block /etc/redlib-block.allow /etc/init.d/adblock-lean /usr/lib/adblock-lean/ /etc/adblock-lean/ /www/mangadex-safe/ /www/cgi-bin/md; do
	grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
pass "custom files kept across firmware upgrades${FAMILY_FILTER:+$(on "$FAMILY_FILTER" && echo '; safe search every 30 min, Redlib list daily 04:50')}"

# ---------------------------------------------------------------- SQM (OpenWrt wiki method)
# https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm
# Measured on an idle line, 90% of it, cake + piece_of_cake, link-layer values
# for the chosen link type, plus per-host fairness. cake's "nat" keyword (find
# the real LAN host behind NAT) is only used when there is IPv4 NAT.
step "SQM: measuring line speed (about 20 s)"
/etc/init.d/sqm stop >/dev/null 2>&1
measure() { # down|up -> kbit/s over 10 s, 4 parallel streams
	out=/tmp/setup-speed.$$; : > $out
	end=$(( $(date +%s) + 10 ))
	for _ in 1 2 3 4; do (
		while [ "$(date +%s)" -lt $end ]; do
			left=$(( end - $(date +%s) )); [ $left -lt 1 ] && break
			if [ "$1" = down ]; then
				curl -s -o /dev/null --max-time $left -w '%{size_download} %{http_code}\n' 'https://speed.cloudflare.com/__down?bytes=25000000'
			else
				head -c 25000000 /dev/zero | curl -s -o /dev/null --max-time $left -X POST -H 'Expect:' -T - -w '%{size_upload} %{http_code}\n' 'https://speed.cloudflare.com/__up'
			fi
		done >> $out ) &
	done
	wait
	awk '$2 !~ /^(2|000)/ {print $2 >> "/tmp/setup-speed.codes"} {s += $1} END {printf "%d", s * 8 / 10 / 1000}' $out; rm -f $out
}
rm -f /tmp/setup-speed.codes
DOWN=$(measure down); UP=$(measure up)
# Link-layer values for LINK_TYPE, computed by setup.sh from lib/laptop.sh.
LL=${LINK_LL:-ethernet} OVH=${LINK_OVERHEAD:-44} MPU=${LINK_MPU:-96}
NAT=; [ -n "$HAS_V4" ] && NAT="nat "
if [ "${DOWN:-0}" -gt 1000 ] && [ "${UP:-0}" -gt 1000 ]; then
	RATE_DOWN=$((DOWN * 90 / 100)) RATE_UP=$((UP * 90 / 100)) SQM_OK=1
	SQM_MSG="SQM measured ${DOWN} down / ${UP} up kbit/s, shaping at 90%: $RATE_DOWN / $RATE_UP kbit/s"
elif [ -n "${SQM_FALLBACK_DOWN-}" ] && [ -n "${SQM_FALLBACK_UP-}" ] \
	&& ! echo "$SQM_FALLBACK_DOWN$SQM_FALLBACK_UP" | grep -q '[^0-9]'; then
	RATE_DOWN=$SQM_FALLBACK_DOWN RATE_UP=$SQM_FALLBACK_UP SQM_OK=
	codes=$(sort -u /tmp/setup-speed.codes 2>/dev/null | tr '\n' ' '); codes=${codes:-none}
	SQM_MSG="SQM speed test failed (down=${DOWN:-0} up=${UP:-0} kbit/s, Cloudflare HTTP codes: $codes); using saved rates $RATE_DOWN / $RATE_UP kbit/s"
else
	RATE_DOWN='' SQM_OK=''
	codes=$(sort -u /tmp/setup-speed.codes 2>/dev/null | tr '\n' ' '); codes=${codes:-none}
	SQM_MSG="SQM speed test failed (down=${DOWN:-0} up=${UP:-0} kbit/s, Cloudflare HTTP codes: $codes) and no saved rates; SQM left off, re-run setup later"
fi
if [ -n "$RATE_DOWN" ]; then
	for s in $(uci -q show sqm | sed -n "s/^sqm\.\([^.]*\)=queue$/\1/p"); do uci delete "sqm.$s"; done
	uci batch >/dev/null <<-EOF
		set sqm.wan=queue
		set sqm.wan.enabled='1'
		set sqm.wan.interface='$WAN_DEV'
		set sqm.wan.download='$RATE_DOWN'
		set sqm.wan.upload='$RATE_UP'
		set sqm.wan.qdisc='cake'
		set sqm.wan.script='piece_of_cake.qos'
		set sqm.wan.linklayer='$LL'
		set sqm.wan.overhead='$OVH'
		set sqm.wan.linklayer_advanced='1'
		set sqm.wan.tcMPU='$MPU'
		set sqm.wan.qdisc_advanced='1'
		set sqm.wan.squash_dscp='1'
		set sqm.wan.squash_ingress='1'
		set sqm.wan.ingress_ecn='ECN'
		set sqm.wan.egress_ecn='NOECN'
		set sqm.wan.qdisc_really_really_advanced='1'
		set sqm.wan.iqdisc_opts='${NAT}dual-dsthost'
		set sqm.wan.eqdisc_opts='${NAT}dual-srchost'
		commit sqm
	EOF
	/etc/init.d/sqm enable; /etc/init.d/sqm restart >/dev/null 2>&1
	SQM_MSG="$SQM_MSG on $WAN_DEV; $LINK_TYPE: $LL overhead $OVH mpu $MPU; per-host fairness${NAT:+ behind NAT}"
fi
if [ -n "$SQM_OK" ]; then pass "$SQM_MSG"; else fail "$SQM_MSG"; fi

# ---------------------------------------------------------------- start everything
step "Starting services"
/etc/init.d/sysntpd restart >/dev/null 2>&1
# restart, not reload: netifd only picks up newly installed protocol handlers
# (WireGuard, PPPoE) when it starts.
/etc/init.d/network restart
if [ -n "$VPN" ]; then
	i=0; until [ "$(ifstatus "$VPN" | jsonfilter -e '@.up')" = true ] || [ $i -ge 20 ]; do sleep 1; i=$((i + 1)); done
fi
i=0; until online4 || online6 || [ $i -ge 30 ]; do sleep 1; i=$((i + 1)); done
# IPv6 (RA, DHCPv6-PD) often comes up some seconds after IPv4: give it time, then decide.
i=0; until has_v6 || [ $i -ge 20 ]; do sleep 1; i=$((i + 1)); done
HAS_V6=; has_v6 && HAS_V6=1
V6_IF=
for i in wan6 wan_6 wan; do
	ifstatus "$i" 2>/dev/null | jsonfilter -e '@.route[*].target' 2>/dev/null | grep -qx '::' && { V6_IF=$i; break; }
done
uci -q delete banip.global.ban_ifv6
if [ -n "$HAS_V6" ] && [ -n "$V6_IF" ]; then
	uci set banip.global.ban_protov6=1; uci add_list banip.global.ban_ifv6="$V6_IF"
	[ -n "$VPN" ] && { uci set pbr.config.uplink_interface6="$V6_IF"; uci commit pbr; }
else
	uci set banip.global.ban_protov6=0
fi
uci commit banip
info "after restart: IPv6 $(yes_no "$HAS_V6" 'usable (banIP covers IPv6)' 'not usable')"
/etc/init.d/firewall restart >/dev/null 2>&1
/etc/init.d/uhttpd restart
/etc/init.d/cron enable; /etc/init.d/cron restart
/etc/init.d/banip enable; /etc/init.d/banip restart >/dev/null 2>&1
if [ -n "$VPN" ]; then
	/etc/init.d/pbr enable; /etc/init.d/pbr restart >/dev/null 2>&1
elif [ -x /etc/init.d/pbr ]; then
	/etc/init.d/pbr stop >/dev/null 2>&1; /etc/init.d/pbr disable
fi
[ -n "$APS" ] && wifi reload
if on "${FAMILY_FILTER:-0}"; then
	/usr/sbin/redlib-block && pass "Redlib instance list fetched (allowed: ${REDLIB_ALLOW:-none})" \
		|| fail "Redlib instance list download failed"
fi
/etc/init.d/adblock-lean enable
echo "    adblock-lean: downloading and testing block lists (1-3 min)..."
/etc/init.d/adblock-lean start >/tmp/setup-adblock.log 2>&1
/etc/init.d/adblock-lean upd_cron_job >/dev/null 2>&1

# ---------------------------------------------------------------- verify
step "Verifying"
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }
resolve() { nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/{n=1} n && /^Address/{print $2}' | head -1; }
# Blocked by this router's own list (not just unresolvable upstream).
blocked() {
	{ gzip -dc /var/run/adblock-lean/abl-blocklist.gz; cat /tmp/dnsmasq.*.d/abl-blocklist; } 2>/dev/null \
		| tr '/' '\n' | grep -qxF "$1" && [ -z "$(resolve "$1")" ]
}
pbr_ok() {
	d=$(ubus call service list '{"name":"pbr"}')
	[ -z "$(echo "$d" | jsonfilter -e '@.pbr.instances.main.data.errors[*]')" ] \
		&& echo "$d" | jsonfilter -e '@.pbr.instances.main.data.gateways[*].name' | grep -qx "$VPN"
}
for svc in dnsmasq dnsproxy uhttpd dropbear cron banip sqm adblock-lean; do
	check "service $svc enabled" "/etc/init.d/$svc enabled"
done
check "dnsproxy (encrypted upstream) resolves" "nslookup example.org 127.0.0.1:5354"
check "router DNS resolves example.org" "[ -n \"\$(resolve example.org)\" ]"
check "adblock-lean blocklist loaded" "/etc/init.d/adblock-lean status"
check "adblock-lean list compressed in RAM" "[ -s /var/run/adblock-lean/abl-blocklist.gz ]"
check "DNS hijack rule active" "nft list chain inet fw4 dstnat_lan | grep -q 'dport 53.*redirect'"
if [ -f "$PRIV/blocklist.txt" ]; then
	d=$(grep -vE '^[[:space:]]*(#|$)' "$PRIV/blocklist.txt" | head -1)
	[ -n "$d" ] && check "own blocklist: $d blocked" "blocked \"\$d\""
fi
if on "${FAMILY_FILTER:-0}"; then
	check "family list: mangadex.org blocked" "blocked mangadex.org"
	check "family allowlist: api.mangadex.org resolves" "[ -n \"\$(resolve api.mangadex.org)\" ]"
	check "Redlib: listed instance redlib.catsarch.com blocked" "blocked redlib.catsarch.com"
	for h in ${REDLIB_ALLOW-}; do check "Redlib: $h allowed" "[ -n \"\$(resolve \"\$h\")\" ]"; done
	check "safe search: www.google.com -> forcesafesearch" "[ \"\$(resolve www.google.com)\" = 216.239.38.120 ]"
	check "safe search: duckduckgo.com pinned" "grep -q ' duckduckgo.com' /tmp/hosts/safesearch"
	check "safe search: yandex.com -> 213.180.193.56" "[ \"\$(resolve yandex.com)\" = 213.180.193.56 ]"
	check "DoT (853) blocked" "nft list ruleset | grep -q 'Deny-DoT'"
	check "VPN protocol blocks active" "nft list ruleset | grep -q 'Block-WireGuard-LAN'"
fi
if on "${ENABLE_MANGADEX:-0}"; then
	check "manga.lan -> router" "[ \"\$(resolve manga.lan)\" = \"$LAN_IP\" ]"
	check "MangaDex app served" "wget -qO- http://127.0.0.1/mangadex-safe/ | grep -qi '<html'"
	check "MangaDex CGI returns data" "wget -qO- 'http://127.0.0.1/cgi-bin/md/api/manga?limit=1' | grep -q '\"data\"'"
	check "MangaDex CGI refuses /manga/random" "! wget -qO- http://127.0.0.1/cgi-bin/md/api/manga/random"
fi
if [ -n "$VPN" ]; then
	i=0; while [ $i -lt 10 ] && [ "$(wg show "$VPN" latest-handshakes 2>/dev/null | awk '{print $2}')" = 0 ]; do sleep 3; i=$((i + 1)); done
	check "VPN WireGuard handshake" "[ \"\$(wg show $VPN latest-handshakes | awk '{print \$2}')\" -gt 0 ]"
	check "PBR active (no errors, $VPN gateway)" "pbr_ok"
fi
if [ -n "$REMOTE" ]; then
	check "remote access: WireGuard listens on UDP $REMOTE_PORT" "[ \"\$(wg show remote listen-port)\" = $REMOTE_PORT ]"
	check "remote access: $REMOTE_N devices" "[ \"\$(wg show remote peers | wc -l)\" = $REMOTE_N ]"
	check "remote access: port open on the WAN" "nft list ruleset | grep -q 'Allow-Remote-WireGuard'"
fi
check "banIP running" "/etc/init.d/banip status 2>&1 | grep -qi 'status.*active'"
[ -n "$RATE_DOWN" ] && check "SQM cake active on $WAN_DEV" "tc qdisc show dev $WAN_DEV | grep -q cake"
check "root password set" "! grep -q '^root::' /etc/shadow"
wifi_up() { [ "$(iwinfo | grep -cF "ESSID: \"$WIFI_SSID\"")" -ge "$(echo $APS | wc -w)" ]; }
[ -n "$APS" ] && check "Wi-Fi up on all $(echo $APS | wc -w) radios" wifi_up

# Host keys last, so the running session isn't disturbed earlier.
/etc/init.d/dropbear restart

echo; echo "================ REPORT ================"
cat "$REPORT"
echo "========================================"
grep -q '^FAIL' "$REPORT" && exit 2
exit 0
