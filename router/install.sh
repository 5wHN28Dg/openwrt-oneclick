#!/bin/sh
# Sets up a fresh OpenWrt router from ../private/config.env (see setup.sh).
# Runs on the router. Hardware-specific values (WAN device, radios) and the
# internet type (IPv4 with NAT, IPv6) are detected here, not assumed.

set -u
umask 022
ROUTER=$(cd "$(dirname "$0")" && pwd)
PRIV=$ROUTER/../private
. "$PRIV/config.env"
. "$ROUTER/sqm-lib.sh"

REPORT=/tmp/setup-report.txt
: > "$REPORT"
pass() { echo "PASS  $1" | tee -a "$REPORT"; }
fail() { echo "FAIL  $1" | tee -a "$REPORT"; }
info() { echo "INFO  $1" | tee -a "$REPORT"; }
step() { echo; echo "==> $1"; }
# Stopping after adblock-lean's installer stopped it: start it again, so the
# router keeps blocking with what it has.
ABL_STOPPED=
die()  {
	fail "$1"
	[ -n "$ABL_STOPPED" ] && [ -s /etc/adblock-lean/config ] && /etc/init.d/adblock-lean start >/dev/null 2>&1
	echo; cat "$REPORT"; exit 1
}
on()   { [ "${1:-0}" = 1 ]; }

VPN=
if on "${ENABLE_VPN:-0}"; then
	VPN=${VPN_IFACE:-vpn}
	case $VPN in *[!a-z0-9_]*|'') echo "VPN_IFACE must be lowercase letters, digits or _"; exit 1 ;; esac
	RESERVED=' lan wan wan6 wan_6 loopback remote redlib '
	case $RESERVED in *" $VPN "*) echo "VPN_IFACE '$VPN' is reserved"; exit 1 ;; esac
	if uci -q get "network.$VPN" >/dev/null && [ "$(uci -q get "network.$VPN.setup")" != 1 ]; then
		echo "VPN_IFACE '$VPN' is an existing interface not made by this tool; pick another name"; exit 1
	fi
fi
LAN_IP=$(uci get network.lan.ipaddr | cut -d/ -f1)
LAN_ZONE=$(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.name='lan'$/\1/p" | head -1)

ip2int() { # a.b.c.d -> integer
	echo "$1" | { IFS=. read -r a b c d; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
}
int2ip() { # integer -> a.b.c.d
	echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}
lan_st=$(ubus call network.interface.lan status)
lan_sub=$(echo "$lan_st" | jsonfilter -e '@["ipv4-address"][0].address')/$(echo "$lan_st" | jsonfilter -e '@["ipv4-address"][0].mask')
case $lan_sub in /*|*/) lan_sub=$LAN_IP/24 ;; esac

# ZeroTier: the network ID goes into uci and a jsonfilter expression.
ZT=''; on "${ENABLE_ZEROTIER:-0}" && ZT=1
if [ -n "$ZT" ]; then
	printf '%s\n' "${ZEROTIER_NETWORK-}" | grep -qxE '[0-9a-f]{16}' || { echo "ZEROTIER_NETWORK must be the 16-character network ID"; exit 1; }
	z=$(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.name='zerotier'$/\1/p" | head -1)
	if [ -n "$z" ] && [ "$(uci -q get "firewall.$z.setup")" != 1 ]; then
		echo "a firewall zone named zerotier exists that this tool did not make; rename it first"; exit 1
	fi
	# ZeroTier goes into its own zone. One put into another zone by hand would
	# keep that zone's access (fw4 uses the first zone that matches): stop.
	# Only a plain zt+ in the lan zone (the usual hand setup) is moved over.
	zt_ifs=$(uci -q show network | sed -n "s/^network\.\([^.]*\)\.device='zt[^']*'$/\1/p" | tr '\n' ' ')
	ztbad=''
	for z in $(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)=zone$/\1/p"); do
		[ "$(uci -q get "firewall.$z.setup")" = 1 ] && continue
		for d in $(uci -q get "firewall.$z.device"); do
			case $d in zt*) [ "$z" = "$LAN_ZONE" ] && [ "$d" = 'zt+' ] || ztbad="$ztbad $z:$d" ;; esac
		done
		for n in $(uci -q get "firewall.$z.network"); do
			case " $zt_ifs " in *" $n "*) ztbad="$ztbad $z:$n" ;; esac
		done
	done
	# ... or bridged into a network device, or named in rules and forwardings
	# this tool didn't make (they would apply to the new zone).
	for d in $(uci -q show network | sed -n "s/^network\.\([^.]*\)\.ports=.*'zt.*/\1/p"); do ztbad="$ztbad bridge:$d"; done
	for r in $(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.\(src\|dest\)='zerotier'$/\1/p"); do
		[ "$(uci -q get "firewall.$r.setup")" = 1 ] || ztbad="$ztbad rule:$r"
	done
	[ -z "$ztbad" ] || { echo "ZeroTier interfaces are in firewall zones, bridges or rules this tool doesn't manage ($ztbad ): take them out there first (the setup gives ZeroTier its own zone)"; exit 1; }
fi
# Tailscale: a trimmed build made on the laptop (lib/tailscale.sh), which
# setup.sh puts in the bundle. Its init script marks it as this tool's.
TS=''; on "${ENABLE_TAILSCALE:-0}" && TS=1
TS_BIN=$ROUTER/../tailscale/tailscaled
TS_NFT=/etc/nftables.d/32-oneclick-tailscale-dns.nft
TS_FILES="/usr/sbin/tailscaled /usr/sbin/tailscale /etc/init.d/tailscale $TS_NFT /etc/tailscale/"
ts_ours() { grep -q 'set up by openwrt-oneclick' /etc/init.d/tailscale 2>/dev/null; }
if [ -n "$TS" ]; then
	[ -s "$TS_BIN" ] || { echo "the Tailscale program is missing from the setup bundle (setup.sh builds it)"; exit 1; }
	if { [ -e /etc/init.d/tailscale ] && ! ts_ours; } \
		|| { command -v apk >/dev/null && apk info -e tailscale >/dev/null 2>&1; } \
		|| { command -v opkg >/dev/null && opkg status tailscale 2>/dev/null | grep -q installed; }; then
		echo "Tailscale is installed already (OpenWrt's package or by hand): remove it first (apk del tailscale); the setup installs its own, smaller build"; exit 1
	fi
	z=$(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.name='tailscale'$/\1/p" | head -1)
	if [ -n "$z" ] && [ "$(uci -q get "firewall.$z.setup")" != 1 ]; then
		echo "a firewall zone named tailscale exists that this tool did not make; rename it first"; exit 1
	fi
	# Its own zone decides what Tailscale devices reach; one in another zone
	# (or in rules and bridges this tool doesn't manage) would keep that access.
	tsbad=''
	ts_ifs=$(uci -q show network | sed -n "s/^network\.\([^.]*\)\.device='tailscale[^']*'$/\1/p" | tr '\n' ' ')
	for z in $(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)=zone$/\1/p"); do
		[ "$(uci -q get "firewall.$z.setup")" = 1 ] && continue
		for d in $(uci -q get "firewall.$z.device"); do case $d in tailscale*) tsbad="$tsbad $z:$d" ;; esac; done
		for n in $(uci -q get "firewall.$z.network"); do case " $ts_ifs " in *" $n "*) tsbad="$tsbad $z:$n" ;; esac; done
	done
	for d in $(uci -q show network | sed -n "s/^network\.\([^.]*\)\.ports=.*'tailscale.*/\1/p"); do tsbad="$tsbad bridge:$d"; done
	for r in $(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.\(src\|dest\)='tailscale'$/\1/p"); do
		[ "$(uci -q get "firewall.$r.setup")" = 1 ] || tsbad="$tsbad rule:$r"
	done
	[ -z "$tsbad" ] || { echo "Tailscale's interface is in firewall zones, bridges or rules this tool doesn't manage ($tsbad ): take it out there first (the setup gives Tailscale its own zone)"; exit 1; }
	# A login: the router's own, the one saved on the laptop, or an auth key.
	if [ ! -s /etc/tailscale/tailscaled.state ] && [ ! -s "$PRIV/tailscale/tailscaled.state" ] && [ ! -s "$PRIV/tailscale-authkey" ]; then
		echo "Tailscale needs an auth key the first time: save one in private/tailscale-authkey (see README, Tailscale)"; exit 1
	fi
fi
# Remote access: everything that can stop it is checked before anything changes.
REMOTE=; on "${ENABLE_REMOTE:-0}" && REMOTE=1
if [ -n "$REMOTE" ]; then
	if uci -q get network.remote >/dev/null && [ "$(uci -q get network.remote.setup_remote)" != 1 ]; then
		echo "an interface 'remote' exists that this tool did not make; rename it first"; exit 1
	fi
	[ -n "$LAN_ZONE" ] || { echo "no firewall zone named lan, needed for remote access"; exit 1; }
	# The tunnel range must not overlap the LAN (compare at the shorter prefix).
	p=${lan_sub#*/}; [ "$p" -gt 24 ] && p=24
	m=$(( (0xffffffff << (32 - p)) & 0xffffffff ))
	if [ $(( $(ip2int "${lan_sub%/*}") & m )) -eq $(( $(ip2int "${REMOTE_NET%/*}") & m )) ]; then
		echo "REMOTE_NET $REMOTE_NET overlaps the LAN $lan_sub; pick another range (./setup.sh --reconfigure)"; exit 1
	fi
fi

# Redlib gets the last address of the LAN as its own (reddit.lan), so it can
# serve on port 80 next to LuCI. Checked before anything changes: it must not
# be the router's address, in the DHCP pool or a fixed lease.
REDLIB=''; on "${ENABLE_REDLIB:-0}" && REDLIB=1
REDLIB_IP=''
if [ -n "$REDLIB" ]; then
	if uci -q get network.redlib >/dev/null && [ "$(uci -q get network.redlib.setup_redlib)" != 1 ]; then
		echo "an interface 'redlib' exists that this tool did not make; rename it first"; exit 1
	fi
	p=${lan_sub#*/}
	[ "$p" -le 30 ] || { echo "the LAN $lan_sub is too small for Redlib's own address"; exit 1; }
	net=$(( $(ip2int "${lan_sub%/*}") & ((0xffffffff << (32 - p)) & 0xffffffff) ))
	last=$(( net + (1 << (32 - p)) - 2 ))
	REDLIB_IP=$(int2ip $last)
	start=$(uci -q get dhcp.lan.start || echo 100) limit=$(uci -q get dhcp.lan.limit || echo 150)
	leased=''   # a fixed lease ("host" entry) on that address
	for s in $(uci -q show dhcp | sed -n "s/^dhcp\.\([^.]*\)=host$/\1/p"); do
		[ "$(uci -q get "dhcp.$s.ip")" = "$REDLIB_IP" ] && leased=1
	done
	if [ "$REDLIB_IP" = "$LAN_IP" ] || { [ $last -ge $((net + start)) ] && [ $last -lt $((net + start + limit)) ]; } || [ -n "$leased" ]; then
		echo "Redlib's address $REDLIB_IP is the router's, in the DHCP pool or a fixed lease; make the pool end before it (LuCI: Network > Interfaces > lan > DHCP Server)"; exit 1
	fi
	# Not ours yet: a device (a second access point, a modem) may have set it itself.
	if ! ip -4 addr show | grep -q " $REDLIB_IP/" \
		&& { ping -c 1 -W 1 "$REDLIB_IP" >/dev/null 2>&1 || ip neigh show "$REDLIB_IP" | grep -q lladdr; }; then
		echo "a device on the LAN already uses $REDLIB_IP, the address Redlib would take; give that device another address"; exit 1
	fi
fi

# curl: SQM speed test (streamed upload); gawk, sed, coreutils-sort: adblock-lean's
# fast list processing; dnsmasq-full: nftset support for pbr and adblock-lean.
PACKAGES="luci luci-ssl luci-app-attendedsysupgrade owut luci-app-banip luci-app-sqm
	dnsmasq-full dnsproxy curl gawk sed coreutils-sort"
[ -n "$VPN$REMOTE" ] && PACKAGES="$PACKAGES luci-proto-wireguard"
[ -n "$VPN" ] && PACKAGES="$PACKAGES luci-app-pbr"
# Telegram proxy for phones (SOCKS5, 7 KB): only with Telegram through the VPN.
TG_PROXY=''; [ -n "$VPN" ] && on "${TELEGRAM_VIA_VPN:-0}" && on "${TELEGRAM_PROXY:-0}" && TG_PROXY=1
[ -n "$TG_PROXY" ] && PACKAGES="$PACKAGES microsocks"
# ZeroTier (about 1 MB, 8 MB of RAM on a Redmi AX6S): remote access where the
# provider's shared address (CGNAT) leaves WireGuard unreachable.
[ -n "$ZT" ] && PACKAGES="$PACKAGES zerotier"
# Tailscale's network device (the program itself comes from the laptop).
[ -n "$TS" ] && PACKAGES="$PACKAGES kmod-tun"
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
# On a re-run (adblock-lean already there), a failed update (GitHub down or
# rate-limited) keeps the installed version and its config instead of stopping.
ABL_OLD=; [ -s /etc/adblock-lean/config ] && [ -x /etc/init.d/adblock-lean ] && ABL_OLD=1
abl_fail() {
	tail -5 /tmp/setup-abl.log
	[ -n "$ABL_OLD" ] || die "$1 (/tmp/setup-abl.log)"
	fail "$1 (/tmp/setup-abl.log); kept the installed adblock-lean and its config"
}
: > /tmp/setup-abl.log
ABL_STOPPED=1   # the installer stops a running adblock-lean
if ! uclient-fetch -q -O /tmp/abl-install.sh "$ABL_INSTALLER"; then
	abl_fail "could not download $ABL_INSTALLER"
elif ! DO_DIALOGS=0 sh /tmp/abl-install.sh -v release >>/tmp/setup-abl.log 2>&1; then
	abl_fail "adblock-lean install failed"
# A fresh default config each run (replaces the old one only if it succeeds).
elif ! DO_DIALOGS=0 luci_preset=auto luci_upd_cron_job=1 luci_cron_schedule='0 5 * * *' \
	/etc/init.d/adblock-lean gen_config >>/tmp/setup-abl.log 2>&1; then
	abl_fail "adblock-lean gen_config failed"
fi
rm -f /tmp/abl-install.sh
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
# Redlib: its own user (created before the firewall rule that names its number).
# Turned off since an earlier run: everything goes, the rule before the user.
REDLIB_NFT=/etc/nftables.d/30-oneclick-redlib-dns.nft
REDLIB_FILES="/etc/init.d/redlib /usr/sbin/redlib-update $REDLIB_NFT /etc/redlib.conf /etc/redlib.rejected"
if [ -n "$REDLIB" ]; then
	# OpenWrt's helpers (in a subshell: they read variables this script's set -u rejects)
	( set +u; . /lib/functions.sh
	  user_exists redlib || user_add redlib '' "$(group_add_next redlib)" Redlib /var/empty /bin/false )
	put_tree "$ROUTER/redlib"
	chmod 755 /etc/init.d/redlib /usr/sbin/redlib-update
	# The DNS rule goes by the user's number: it must be a number, and only
	# redlib's (an unfinished or wrong rule would stop the firewall loading,
	# or let another program's DNS skip the block lists).
	uid=$(id -u redlib 2>/dev/null)
	case $uid in ''|*[!0-9]*) rm -f $REDLIB_NFT; die "could not create the redlib user" ;; esac
	[ "$(awk -F: -v u="$uid" '$3 == u' /etc/passwd | wc -l)" = 1 ] || { rm -f $REDLIB_NFT; die "another user shares the redlib user's number $uid"; }
	sed "s/REDLIB_UID/$uid/" "$ROUTER/redlib-dns.nft" > $REDLIB_NFT.tmp && mv $REDLIB_NFT.tmp $REDLIB_NFT
	SFW=off; on "${FAMILY_FILTER:-0}" && SFW=on
	printf 'ADDRESS=%s\nSFW=%s\n' "$REDLIB_IP" "$SFW" > /etc/redlib.conf
elif [ -e /etc/init.d/redlib ] || grep -q '^redlib:' /etc/passwd; then
	/etc/init.d/redlib stop >/dev/null 2>&1; /etc/init.d/redlib disable >/dev/null 2>&1
	rm -f $REDLIB_FILES $REDLIB_NFT.tmp /usr/sbin/redlib /usr/sbin/redlib.old /usr/sbin/redlib.new /etc/redlib.version /etc/redlib.rejected
	sed -i '/^redlib:/d' /etc/passwd /etc/shadow /etc/group
	for f in $REDLIB_FILES; do sed -i "\#^$f\$#d" /etc/sysupgrade.conf; done
fi
chmod 755 /usr/sbin/safesearch-hosts /usr/sbin/redlib-block /usr/sbin/telegram-ranges /usr/sbin/oneclick-after-upgrade

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
# A cron or boot proton-pick run must not work on the VPN while it changes
# here: take its lock (released below, before anything is started).
exec 9>/var/lock/proton-pick.lock
i=0   # BusyBox flock has no timeout: try every second, for up to 15 minutes
until flock -n 9; do
	i=$((i + 1)); [ $i -ge 900 ] && { info "proton-pick was busy for 15 minutes; going on"; break; }
	sleep 1
done
# The server proton-pick switched to (if still listed) survives a re-run.
PREV_KEY='' PREV_HOST=''
if [ -n "$VPN" ] && on "${PROTON_AUTO:-0}"; then
	PREV_KEY=$(uci -q get "network.@wireguard_${VPN}[0].public_key")
	PREV_HOST=$(uci -q get "network.@wireguard_${VPN}[0].endpoint_host")
	awk -v k="$PREV_KEY" '$4 == k { f = 1 } END { exit !f }' /etc/proton/servers 2>/dev/null || PREV_KEY='' PREV_HOST=''
fi
# VPN interfaces from earlier runs (tagged setup=1) go first, also when the VPN
# is now off or renamed.
for i in $(uci -q show network | sed -n "s/^network\.\([^.]*\)\.setup='1'$/\1/p"); do
	for s in $(uci -q show network | sed -n "s/^network\.\(@wireguard_$i\[[0-9]*\]\)=.*/\1/p" | sort -t'[' -k2 -n -r); do uci delete "network.$s"; done
	uci delete "network.$i"
done
uci commit network
if [ -n "$VPN" ]; then
	step "VPN ($VPN)"
	uci -q delete "network.$VPN"
	for s in $(uci -q show network | sed -n "s/^network\.\(@wireguard_$VPN\[[0-9]*\]\)=.*/\1/p" | sort -t'[' -k2 -n -r); do uci delete "network.$s"; done
	uci set "network.$VPN=interface"
	uci set "network.$VPN.proto=wireguard"
	uci set "network.$VPN.setup=1"
	uci set "network.$VPN.private_key=$WG_PRIVATE_KEY"
	uci set "network.$VPN.multipath=off"
	uci add network "wireguard_$VPN" >/dev/null
	uci set "network.@wireguard_${VPN}[-1].description=VPN peer"
	uci set "network.@wireguard_${VPN}[-1].public_key=${PREV_KEY:-$WG_PEER_PUBLIC_KEY}"
	uci set "network.@wireguard_${VPN}[-1].endpoint_host=${PREV_HOST:-$WG_ENDPOINT_HOST}"
	uci set "network.@wireguard_${VPN}[-1].endpoint_port=$WG_ENDPOINT_PORT"
	ka=${WG_KEEPALIVE:-25}
	# proton-pick tells a dead server by its handshakes: keep the tunnel talking.
	on "${PROTON_AUTO:-0}" && [ "$ka" -eq 0 ] && ka=25
	uci set "network.@wireguard_${VPN}[-1].persistent_keepalive=$ka"
	for a in ${WG_ADDRESSES-}; do uci add_list "network.$VPN.addresses=$a"; done
	for a in ${WG_DNS-}; do uci add_list "network.$VPN.dns=$a"; done
	for a in ${WG_ALLOWED_IPS:-0.0.0.0/0 ::/0}; do uci add_list "network.@wireguard_${VPN}[-1].allowed_ips=$a"; done
	[ -n "${WG_PRESHARED_KEY-}" ] && uci set "network.@wireguard_${VPN}[-1].preshared_key=$WG_PRESHARED_KEY"
	uci commit network

	# PBR: only the chosen domains and ranges go through the VPN
	for s in $(uci -q show pbr | sed -n "s/^pbr\.\([^.]*\)\.setup='1'$/\1/p" | sort -t'[' -k2 -n -r); do uci delete "pbr.$s"; done
	policy() { # name dest
		uci add pbr policy >/dev/null
		uci set pbr.@policy[-1].setup=1
		uci set "pbr.@policy[-1].name=$1"
		uci set "pbr.@policy[-1].dest_addr=$2"
		uci set "pbr.@policy[-1].interface=$VPN"
	}
	[ -n "${VPN_ROUTE_DOMAINS-}" ] && policy 'domains through VPN' "$VPN_ROUTE_DOMAINS"
	[ -n "${VPN_ROUTE_SUBNETS-}" ] && policy 'IP ranges through VPN' "$VPN_ROUTE_SUBNETS"
	# Telegram: its own list of ranges plus web domains, kept current daily by
	# telegram-ranges (it fills every policy marked telegram=1). Starts from
	# the copy in the repo, so it is complete even if the download fails.
	if on "${TELEGRAM_VIA_VPN:-0}"; then
		policy 'Telegram through VPN' 'telegram.org'
		uci set pbr.@policy[-1].telegram=1
	fi
	# The proxy's connections start on the router itself, which the policy
	# above doesn't cover: the same list for the router's own traffic.
	if [ -n "$TG_PROXY" ]; then
		policy 'Telegram from the router (proxy)' 'telegram.org'
		uci set pbr.@policy[-1].telegram=1
		uci set pbr.@policy[-1].chain=output
	fi
	uci commit pbr
	[ -z "${VPN_ROUTE_DOMAINS-}${VPN_ROUTE_SUBNETS-}" ] && ! on "${TELEGRAM_VIA_VPN:-0}" && info "VPN set up, but no domains or ranges are routed through it"
	# IPv6 to the VPN domains must not go around the VPN: route it through the
	# VPN when the VPN has IPv6, otherwise answer their AAAA queries with ::
	# (no address) so devices use IPv4, which pbr sends through the VPN.
	TG_DOMAINS=''   # one list of Telegram's domains: the one in telegram-ranges
	on "${TELEGRAM_VIA_VPN:-0}" && TG_DOMAINS=$(sed -n "s/^DOMAINS='\(.*\)'$/\1/p" /usr/sbin/telegram-ranges)
	if echo "${WG_ADDRESSES-}" | grep -q ':'; then
		uci set pbr.config.ipv6_enabled=1
	else
		uci set pbr.config.ipv6_enabled=0
		for d in ${VPN_ROUTE_DOMAINS-} $TG_DOMAINS; do echo "/$d/::"; done > /etc/oneclick-vpn-aaaa
	fi
	uci commit pbr
	if on "${TELEGRAM_VIA_VPN:-0}"; then
		# The proxy's rules start as "nothing allowed"; telegram-ranges then
		# replaces the file whole with the allow list (fails closed, never open).
		if [ -n "$TG_PROXY" ]; then
			muid=$(id -u microsocks 2>/dev/null)
			case $muid in ''|*[!0-9]*) die "the microsocks package didn't create its user" ;; esac
			f=/etc/nftables.d/31-oneclick-telegram-proxy.nft
			printf 'chain oneclick_telegram_proxy {\n\ttype filter hook output priority filter - 1; policy accept;\n\tmeta skuid %s ct state new counter reject\n}\n' "$muid" > "$f.tmp" && mv "$f.tmp" "$f"
		fi
		TELEGRAM_NO_RELOAD=1 /usr/sbin/telegram-ranges "$ROUTER/lists/telegram-cidr.txt" >/dev/null || die "could not fill the Telegram policy"
	fi
	pass "WireGuard $VPN to ${PREV_HOST:-$WG_ENDPOINT_HOST}; PBR: ${VPN_ROUTE_DOMAINS:-no domains}${VPN_ROUTE_SUBNETS:+ + IP ranges}${TG_DOMAINS:+ + Telegram}"
fi

# ---------------------------------------------------------------- Telegram proxy
# SOCKS5 with a password, for phones: at home and through ZeroTier. Listens on
# every address, but the firewall only lets the LAN and ZeroTier zones
# reach the router; telegram-ranges keeps its user to Telegram's addresses.
TG_PROXY_NFT=/etc/nftables.d/31-oneclick-telegram-proxy.nft
if [ -n "$TG_PROXY" ]; then
	uci batch >/dev/null <<-EOF
		set microsocks.config.oneclick='1'
		set microsocks.config.enabled='1'
		set microsocks.config.listenip='0.0.0.0'
		set microsocks.config.port='${TELEGRAM_PROXY_PORT:-1080}'
		set microsocks.config.user='$TELEGRAM_PROXY_USER'
		set microsocks.config.password='$TELEGRAM_PROXY_PASS'
		set microsocks.config.bindaddr=''
		set microsocks.config.auth_once='0'
		set microsocks.config.quiet='1'
	EOF
	uci commit microsocks
	chmod 600 /etc/config/microsocks   # it holds the password
elif [ "$(uci -q get microsocks.config.oneclick)" = 1 ] || [ -f "$TG_PROXY_NFT" ]; then
	# Turned off since an earlier run: only a proxy this setup made is removed.
	/etc/init.d/microsocks stop >/dev/null 2>&1; /etc/init.d/microsocks disable >/dev/null 2>&1
	rm -f "$TG_PROXY_NFT" "$TG_PROXY_NFT.tmp"; sed -i "\#^$TG_PROXY_NFT\$#d" /etc/sysupgrade.conf
	if [ $PKG = apk ]; then apk del microsocks >/dev/null 2>&1; else opkg remove microsocks >/dev/null 2>&1; fi
	rm -f /etc/config/microsocks   # kept by the package manager, and it holds the password
fi

# Proton VPN server choice (proton-pick): session, settings; off = all removed.
if [ -n "$VPN" ] && on "${PROTON_AUTO:-0}"; then
	mkdir -p /etc/proton; chmod 700 /etc/proton
	uid_of() { sed -n "s/^PROTON_UID='\(.*\)'$/\1/p" "$1" 2>/dev/null; }
	if [ -f "$PRIV/proton-session" ]; then
		# The same session as the router's is an old copy (the router has
		# renewed it since): keep the router's. A new login has a new UID.
		if [ -f /etc/proton/session ] && [ "$(uid_of "$PRIV/proton-session")" = "$(uid_of /etc/proton/session)" ]; then
			info "kept the router's own Proton session (the laptop's copy is older)"
		else
			cp "$PRIV/proton-session" /etc/proton/session; chmod 600 /etc/proton/session
			rm -f /tmp/proton/session-ended
			info "new Proton session installed (from ./proton-login.sh)"
		fi
	fi
	printf "IFACE='%s'\nCOUNTRIES='%s'\nSTALE=300\nAPI='%s'\n" "$VPN" "${PROTON_COUNTRIES-}" \
		"${PROTON_API:-https://vpn-api.proton.me}" > /etc/proton-pick.conf
	chmod 755 /usr/sbin/proton-pick
	[ -f /etc/proton/session ] || info "Proton server choice is on but has no session yet: run ./proton-login.sh, then ./setup.sh"
else
	rm -rf /etc/proton /etc/proton-pick.conf /usr/sbin/proton-pick /usr/share/proton-pick /tmp/proton
	sed -i '\#^/usr/sbin/proton-pick$#d; \#^/usr/share/proton-pick/$#d; \#^/etc/proton/$#d; \#^/etc/proton-pick.conf$#d' /etc/sysupgrade.conf
fi
exec 9>&-   # proton-pick may run again

# ---------------------------------------------------------------- remote access
# WireGuard server: devices outside reach the home network and the router's
# DNS (so manga.lan) through it. The interface joins the lan zone below.
# Earlier runs' interface and peers (tagged setup_remote=1) go first.
if [ "$(uci -q get network.remote.setup_remote)" = 1 ]; then
	for s in $(uci -q show network | sed -n "s/^network\.\(@wireguard_remote\[[0-9]*\]\)=.*/\1/p" | sort -t'[' -k2 -n -r); do uci delete "network.$s"; done
	uci delete network.remote
	uci commit network
fi
if [ -n "$REMOTE" ]; then
	step "Remote access"
	RNET=${REMOTE_NET%.0/24}
	uci batch >/dev/null <<-EOF
		set network.remote=interface
		set network.remote.proto='wireguard'
		set network.remote.setup_remote='1'
		set network.remote.private_key='$REMOTE_SERVER_KEY'
		set network.remote.listen_port='$REMOTE_PORT'
		add_list network.remote.addresses='$RNET.1/24'
	EOF
	# REMOTE_PEERS: name|host number|public key|preshared key (setup.sh sends
	# public keys only)
	printf '%s\n' "$REMOTE_PEERS" | while IFS='|' read -r name n pub psk; do
		[ -n "$name" ] || continue
		uci batch >/dev/null <<-EOF
			add network wireguard_remote
			set network.@wireguard_remote[-1].description='$name'
			set network.@wireguard_remote[-1].public_key='$pub'
			set network.@wireguard_remote[-1].preshared_key='$psk'
			add_list network.@wireguard_remote[-1].allowed_ips='$RNET.$n/32'
		EOF
	done
	uci commit network
	REMOTE_N=$(printf '%s\n' "$REMOTE_PEERS" | grep -c .)
	pass "WireGuard server on UDP $REMOTE_PORT, $REMOTE_N devices in $REMOTE_NET, reaching $lan_sub"
fi

# ---------------------------------------------------------------- ZeroTier
# Remote access behind a provider's shared address: the router and the
# devices both connect out to ZeroTier. Members of the network reach the
# router itself at its ZeroTier address (LuCI, SSH, the MangaDex app, the
# Telegram proxy) and nothing behind it: their own firewall zone (below)
# forwards nowhere, so no member can reach other devices at home or use the
# home line or the VPN, even with a route of their own.
# With the option on, the setup manages ZeroTier on the router: the one
# network from the settings (other networks set up by hand are dropped), the
# identity from private/zerotier/identity.secret (saved by setup.sh after the
# first run, so a reset router stays an approved member), or the router's own.
ZT_REMOVED=''
if [ -n "$ZT" ]; then
	step "ZeroTier"
	touch /etc/config/zerotier; chmod 600 /etc/config/zerotier   # it holds the identity's private key
	if [ -f "$PRIV/zerotier/identity.secret" ]; then
		secret=$(tr -d '\n' < "$PRIV/zerotier/identity.secret")
		if printf '%s\n' "$secret" | grep -qxE '[0-9a-f]{10}:0:[0-9a-f]{128}:[0-9a-f]{128}'; then
			# through stdin: a command line would show the private key in the process list
			printf "set zerotier.global=zerotier\nset zerotier.global.secret='%s'\n" "$secret" | uci batch >/dev/null
		else
			fail "private/zerotier/identity.secret is not a ZeroTier identity: the router keeps its own"
		fi
	fi
	for s in $(uci -q show zerotier | sed -n "s/^zerotier\.\([^.]*\)=network$/\1/p" | sort -t'[' -k2 -n -r); do
		uci delete "zerotier.$s"
	done
	uci batch >/dev/null <<-EOF
		set zerotier.global=zerotier
		set zerotier.global.enabled='1'
		set zerotier.global.setup_oneclick='1'
		set zerotier.oneclick=network
		set zerotier.oneclick.id='$ZEROTIER_NETWORK'
		set zerotier.oneclick.allow_managed='1'
		set zerotier.oneclick.allow_global='0'
		set zerotier.oneclick.allow_default='0'
		set zerotier.oneclick.allow_dns='0'
	EOF
	uci commit zerotier
	pass "ZeroTier: joins network $ZEROTIER_NETWORK; members reach the router only"
elif [ "$(uci -q get zerotier.global.setup_oneclick)" = 1 ]; then
	# Turned off since an earlier run: ZeroTier goes.
	/etc/init.d/zerotier stop >/dev/null 2>&1; /etc/init.d/zerotier disable >/dev/null 2>&1
	if [ $PKG = apk ]; then apk del zerotier >/dev/null 2>&1; else opkg remove zerotier >/dev/null 2>&1; fi
	rm -f /etc/config/zerotier   # kept by the package manager, and it holds the private key
	ZT_REMOVED=1
fi

# ---------------------------------------------------------------- Tailscale
# Remote access behind a provider's shared address (CGNAT), like ZeroTier, and
# the way to send a phone's Telegram (calls too) through the VPN when away:
# with Telegram through the VPN on, the router offers Telegram's ranges to the
# tailnet (approved once in Tailscale's admin console), and the phone's
# Telegram traffic arrives here and leaves through the VPN. Tailscale devices
# reach the router itself (its own zone, below), and through it only the VPN.
# With the option on, the setup manages Tailscale on the router; the state
# (identity and login) from private/tailscale/tailscaled.state, saved by
# setup.sh after the first login, so a reset router stays the same device.
if [ -n "$TS" ]; then
	step "Tailscale"
	( set +u; . /lib/functions.sh; group_exists tailscale || group_add_next tailscale >/dev/null )
	gid=$(sed -n 's/^tailscale:[^:]*:\([0-9]*\):.*/\1/p' /etc/group)
	case $gid in ''|*[!0-9]*) die "could not create the tailscale group" ;; esac
	[ "$(awk -F: -v g="$gid" '$3 == g' /etc/group | wc -l)" = 1 ] || die "another group shares the tailscale group's number $gid"
	# Users whose main group it is would share the DNS exception.
	[ -z "$(awk -F: -v g="$gid" '$4 == g' /etc/passwd)" ] || die "a user has the tailscale group as its own"
	[ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale stop >/dev/null 2>&1
	put_tree "$ROUTER/tailscale"
	cp "$TS_BIN" /usr/sbin/tailscaled.new && chmod 755 /usr/sbin/tailscaled.new && mv /usr/sbin/tailscaled.new /usr/sbin/tailscaled
	ln -sf tailscaled /usr/sbin/tailscale   # one program: run as "tailscale" it is the command-line tool
	chmod 755 /etc/init.d/tailscale
	sed "s/TAILSCALE_GID/$gid/" "$ROUTER/tailscale-dns.nft" > $TS_NFT.tmp && mv $TS_NFT.tmp $TS_NFT
	mkdir -p /etc/tailscale; chmod 700 /etc/tailscale   # the state holds the router's private keys
	if [ ! -s /etc/tailscale/tailscaled.state ] && [ -s "$PRIV/tailscale/tailscaled.state" ]; then
		(umask 077; cp "$PRIV/tailscale/tailscaled.state" /etc/tailscale/tailscaled.state)
		info "Tailscale: the router's saved identity put back (private/tailscale)"
	fi
	pass "Tailscale $(/usr/sbin/tailscaled --version 2>/dev/null | head -1) (trimmed build from the laptop)"
elif ts_ours || [ -f $TS_NFT ]; then
	# Turned off since an earlier run: everything goes (the device logs out,
	# so it leaves the tailnet).
	/usr/sbin/tailscale logout >/dev/null 2>&1
	/etc/init.d/tailscale stop >/dev/null 2>&1; /etc/init.d/tailscale disable >/dev/null 2>&1
	/usr/sbin/tailscaled --cleanup >/dev/null 2>&1
	rm -rf $TS_FILES $TS_NFT.tmp /usr/sbin/tailscaled.new
	sed -i '/^tailscale:/d' /etc/group
	for f in $TS_FILES; do sed -i "\#^$f\$#d" /etc/sysupgrade.conf; done
fi

# ---------------------------------------------------------------- Redlib address
# A /32 address on the LAN bridge: devices reach it directly, and DHCP keeps
# handing out the router's main address (dnsmasq only uses addresses whose
# network contains the pool).
if [ "$(uci -q get network.redlib.setup_redlib)" = 1 ]; then
	uci delete network.redlib; uci commit network
fi
if [ -n "$REDLIB" ]; then
	uci batch >/dev/null <<-EOF
		set network.redlib=interface
		set network.redlib.setup_redlib='1'
		set network.redlib.device='$(uci get network.lan.device)'
		set network.redlib.proto='static'
		set network.redlib.ipaddr='$REDLIB_IP/32'
	EOF
	uci commit network
fi

# ---------------------------------------------------------------- firewall
step "Firewall"
# Remove what this script added before, so re-runs don't duplicate.
for s in $(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.setup='1'$/\1/p" | sort -t'[' -k2 -n -r); do uci delete "firewall.$s"; done
uci -q delete firewall.dns_int
uci -q delete firewall.dot_fwd
[ -n "$LAN_ZONE" ] && uci -q del_list "firewall.$LAN_ZONE.network=remote"
# ZeroTier: its own zone (made again below while the option is on). A zt+
# put in the lan zone by hand moves there (an interface matches one zone).
# (as a list entry or a single option: fw4 reads both)
if [ -n "$LAN_ZONE" ] && [ -n "$ZT$ZT_REMOVED" ]; then
	uci -q del_list "firewall.$LAN_ZONE.device=zt+"
	[ "$(uci -q get "firewall.$LAN_ZONE.device")" = 'zt+' ] && uci -q delete "firewall.$LAN_ZONE.device"
	uci -q get "firewall.$LAN_ZONE.device" | grep -qw 'zt+' && die "could not take zt+ out of the lan zone"
fi
if [ -n "$TS" ]; then
	# Input accepted (the router's own services, as from the LAN). Forwarded
	# only into the VPN, and only what the VPN rules send there (Telegram's
	# ranges, the VPN domains): with the VPN down or for anything else, the
	# route is the WAN, where Tailscale devices may not go.
	uci batch >/dev/null <<-EOF
		add firewall zone
		set firewall.@zone[-1].setup='1'
		set firewall.@zone[-1].name='tailscale'
		set firewall.@zone[-1].input='ACCEPT'
		set firewall.@zone[-1].output='ACCEPT'
		set firewall.@zone[-1].forward='REJECT'
		add_list firewall.@zone[-1].device='tailscale0'
	EOF
	if [ -n "$VPN" ]; then
		uci batch >/dev/null <<-EOF
			add firewall forwarding
			set firewall.@forwarding[-1].setup='1'
			set firewall.@forwarding[-1].src='tailscale'
			set firewall.@forwarding[-1].dest='$VPN'
		EOF
	fi
fi
if [ -n "$ZT" ]; then
	# Input accepted (the router's own services, as from the LAN); no
	# forwarding anywhere: other devices, the internet and the VPN stay out.
	uci batch >/dev/null <<-EOF
		add firewall zone
		set firewall.@zone[-1].setup='1'
		set firewall.@zone[-1].name='zerotier'
		set firewall.@zone[-1].input='ACCEPT'
		set firewall.@zone[-1].output='ACCEPT'
		set firewall.@zone[-1].forward='REJECT'
		add_list firewall.@zone[-1].device='zt+'
	EOF
fi
# Software flow offloading works with SQM; hardware offloading moves packets
# past the queues SQM shapes, so it is switched to software.
uci batch >/dev/null <<-EOF
	set firewall.@defaults[0].flow_offloading='1'
	set firewall.@defaults[0].flow_offloading_hw='0'
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
if [ -n "$REDLIB" ]; then
	# Port 80 on Redlib's address goes to 8080, where it listens as "redlib"
	# (an unprivileged user can't open port 80 itself).
	uci batch >/dev/null <<-EOF
		add firewall redirect
		set firewall.@redirect[-1].setup='1'
		set firewall.@redirect[-1].name='Redlib'
		set firewall.@redirect[-1].src='lan'
		set firewall.@redirect[-1].proto='tcp'
		set firewall.@redirect[-1].src_dip='$REDLIB_IP'
		set firewall.@redirect[-1].src_dport='80'
		set firewall.@redirect[-1].dest_ip='$REDLIB_IP'
		set firewall.@redirect[-1].dest_port='8080'
		set firewall.@redirect[-1].target='DNAT'
	EOF
fi
# Telegram's IPv6 ranges, when the VPN has no IPv6: rejected from the LAN so
# apps fall back to IPv4 (through the VPN) at once (telegram-ranges keeps
# the list current).
if [ -n "$VPN" ] && on "${TELEGRAM_VIA_VPN:-0}" && ! echo "${WG_ADDRESSES-}" | grep -q ':'; then
	uci batch >/dev/null <<-EOF
		add firewall rule
		set firewall.@rule[-1].setup='1'
		set firewall.@rule[-1].telegram='1'
		set firewall.@rule[-1].name='Telegram-IPv6-not-through-VPN'
		set firewall.@rule[-1].src='lan'
		set firewall.@rule[-1].dest='wan'
		set firewall.@rule[-1].family='ipv6'
		set firewall.@rule[-1].proto='all'
		set firewall.@rule[-1].target='REJECT'
	EOF
	# The same checks and order as telegram-ranges, so its next run finds nothing to change.
	for a in $(/usr/sbin/telegram-ranges --check "$ROUTER/lists/telegram-cidr.txt" | grep ':'); do uci add_list "firewall.@rule[-1].dest_ip=$a"; done
	uci set firewall.@rule[-1].enabled='1'
fi
uci commit firewall
pass "software flow offloading (hardware offloading off: it bypasses SQM), DNS hijack${FAMILY_FILTER:+$(on "$FAMILY_FILTER" && echo ', DoT and VPN-protocol blocks')}${VPN:+, $VPN zone}${REMOTE:+, remote access in the lan zone}"

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
for s in $(uci -q show dhcp | sed -n "s/^dhcp\.\([^.]*\)\.setup='1'$/\1/p" | sort -t'[' -k2 -n -r); do uci delete "dhcp.$s"; done
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
[ -n "$REDLIB" ] && domain reddit.lan "$REDLIB_IP"
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
	if /usr/sbin/oneclick-after-upgrade manga; then   # also after firmware upgrades (LuCI's index.html)
		pass "MangaDex reader at http://manga.lan (uhttpd max_requests 6)"
	else
		fail "MangaDex reader installed, but manga.lan can't open it: LuCI's /www/index.html is missing or has no <head> (use http://$LAN_IP/mangadex-safe/)"
	fi
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
sed -i '/safesearch-hosts\|redlib-block\|redlib-update\|proton-pick\|telegram-ranges/d' /etc/crontabs/root
# Telegram's list, daily (the policy only exists with the VPN and the option on).
[ -n "$VPN" ] && on "${TELEGRAM_VIA_VPN:-0}" && echo "20 4 * * * /usr/sbin/telegram-ranges" >> /etc/crontabs/root
# Redlib updates at 03:40, apart from adblock-lean's 05:00 run (both need memory).
[ -n "$REDLIB" ] && echo "40 3 * * * /usr/sbin/redlib-update" >> /etc/crontabs/root
sed -i '/safesearch-hosts\|proton-pick\|oneclick-after-upgrade/d' /etc/rc.local
# After a firmware upgrade: the manga.lan redirect back, adblock-lean and
# Redlib on again (see the script). Does nothing on other boots.
sed -i 's|^exit 0$|(sleep 60; /usr/sbin/oneclick-after-upgrade boot) \&\nexit 0|' /etc/rc.local
/usr/sbin/oneclick-after-upgrade mark
grep -q 'oneclick-after-upgrade boot' /etc/rc.local \
	|| fail "/etc/rc.local has no 'exit 0' line: after a firmware upgrade, adblock-lean and Redlib stay off until their nightly jobs"
if [ -f /etc/proton-pick.conf ]; then
	echo "*/5 * * * * /usr/sbin/proton-pick check" >> /etc/crontabs/root
	echo "17 4 * * * /usr/sbin/proton-pick refresh" >> /etc/crontabs/root
	sed -i 's|^exit 0$|(sleep 90; /usr/sbin/proton-pick refresh) \&\nexit 0|' /etc/rc.local
fi
if on "${FAMILY_FILTER:-0}"; then
	echo "*/30 * * * * /usr/sbin/safesearch-hosts" >> /etc/crontabs/root
	# Before adblock-lean's 05:00 update, which loads the refreshed Redlib section.
	echo "50 4 * * * /usr/sbin/redlib-block" >> /etc/crontabs/root
	sed -i 's|^exit 0$|(sleep 30; /usr/sbin/safesearch-hosts) \&\nexit 0|' /etc/rc.local
fi
# Not the Redlib program (11 MB in every upgrade backup): the updater
# (oneclick-after-upgrade) reinstalls it after a firmware upgrade.
[ -n "$REDLIB" ] && for f in $REDLIB_FILES; do
	grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
# Tailscale: the program too (5 MB compressed in the upgrade backup): the
# router can't build it, and without it remote access would be gone.
[ -n "$TS" ] && for f in $TS_FILES; do
	grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
[ -f /etc/proton-pick.conf ] && for f in /usr/sbin/proton-pick /usr/share/proton-pick/ /etc/proton/ /etc/proton-pick.conf; do
	grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
for f in /usr/sbin/safesearch-hosts /etc/safesearch/google.domains /usr/sbin/redlib-block /usr/sbin/telegram-ranges /usr/sbin/oneclick-after-upgrade /etc/oneclick-vpn-aaaa.applied /etc/redlib-block.allow /etc/init.d/adblock-lean /usr/lib/adblock-lean/ /etc/adblock-lean/ /www/mangadex-safe/ /www/cgi-bin/md; do
	grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
pass "custom files kept across firmware upgrades${FAMILY_FILTER:+$(on "$FAMILY_FILTER" && echo '; safe search every 30 min, Redlib list daily 04:50')}"

# ---------------------------------------------------------------- SQM (OpenWrt wiki method)
# https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm
# 90% of the measured line, cake + piece_of_cake, link-layer values for the
# chosen link type, plus per-host fairness. cake's "nat" keyword (find the real
# LAN host behind NAT) is only used when there is IPv4 NAT. Then the guide's
# last step: check the latency under load.
#
# Measuring: four streams load the line while the WAN device's byte counter is
# read every second. The counter sees everything on the line, so other traffic
# doesn't lower the result, and the rate is the median after a warm-up, so
# neither TCP's ramp-up nor short dips set it. Cable providers often give about
# 10 s of extra speed at the start (the guide warns about it): cable lines are
# measured longer and those seconds are left out.
/etc/init.d/sqm stop >/dev/null 2>&1
SPEED_URL=${SPEEDTEST_URL:-https://speed.cloudflare.com}
# ("Not sure" may be cable too.)
case $LINK_TYPE in docsis*|unsure) SPEED_DUR=25 SPEED_WARM=10 ;; *) SPEED_DUR=12 SPEED_WARM=3 ;; esac
# Eight streams of just under 100 MB each (the most Cloudflare serves in one
# request): on a 1 Gbit/s line a stream then runs for seconds, not fractions of
# one, so reconnecting doesn't show in the samples. A stream that is refused or
# fails at once (rate limit, no DNS) waits and gives up after three tries
# instead of asking again and again.
load() { # down|up SECONDS -> eight streams; one "bytes http-code" line per transfer
	end=$(( $(date +%s) + $2 ))
	for _ in 1 2 3 4 5 6 7 8; do (
		refused=0
		while [ "$(date +%s)" -lt $end ] && [ $refused -lt 3 ]; do
			left=$(( end - $(date +%s) )); [ $left -lt 1 ] && break
			if [ "$1" = down ]; then
				r=$(curl -s -o /dev/null --max-time $left -w '%{size_download} %{http_code}\n' "$SPEED_URL/__down?bytes=99999999")
			else
				r=$(head -c 99999999 /dev/zero | curl -s -o /dev/null --max-time $left -X POST -H 'Expect:' -T - -w '%{size_upload} %{http_code}\n' "$SPEED_URL/__up")
			fi
			echo "${r:-0 000}"
			if [ "$(echo "${r:-0}" | cut -d' ' -f1)" -lt 100000 ]; then refused=$((refused + 1)); sleep 2; else refused=0; fi
		done ) &
	done
	wait
}
wan_bytes() { cat "/sys/class/net/$WAN_DEV/statistics/$1" 2>/dev/null || echo 0; }
moved_kbit() { # FILE SECONDS -> kbit/s the transfers in FILE moved themselves
	awk -v d="$2" '{ s += $1 } END { printf "%d", s * 8 / d / 1000 }' "$1"
}
measure() { # down|up -> sustained kbit/s on the WAN device; 0 if the test server gave nothing
	out=/tmp/setup-speed.$$; smp=/tmp/setup-speed-samples.$$; : > $smp
	case $1 in down) ctr=rx_bytes ;; *) ctr=tx_bytes ;; esac
	load "$1" $SPEED_DUR > $out &
	i=0 cpu0='' cpu1=''
	while [ $i -le $SPEED_DUR ]; do
		echo "$(cut -d' ' -f1 /proc/uptime) $(wan_bytes $ctr)" >> $smp
		# CPU use while the load is in full swing (not its start or the idle end)
		[ $i -eq 2 ] && cpu0=$(cpu_snapshot)
		[ $i -eq $((SPEED_DUR - 1)) ] && cpu1=$(cpu_snapshot)
		sleep 1; i=$((i + 1))
	done
	wait
	busy_percent "$cpu0" "$cpu1" > "/tmp/setup-speed.cpu-$1"
	awk '$2 !~ /^(2|000)/ { print $2 }' $out >> /tmp/setup-speed.codes
	moved=$(moved_kbit $out $SPEED_DUR)
	if [ "$moved" -gt 500 ]; then
		rate=$(sustained_kbit $SPEED_WARM < $smp)
		# No usable counter (device gone): what the transfers moved themselves.
		[ "${rate:-0}" -gt 0 ] || rate=$moved
		echo "$rate"
	else
		echo 0
	fi
	rm -f $out $smp
}
# Link-layer values for LINK_TYPE, computed by setup.sh from lib/laptop.sh.
LL=${LINK_LL:-ethernet} OVH=${LINK_OVERHEAD:-44} MPU=${LINK_MPU:-96}
NAT=; [ -n "$HAS_V4" ] && NAT="nat "
rm -f /tmp/setup-speed.codes
if [ -n "${SQM_DOWN-}" ] && [ -n "${SQM_UP-}" ] && ! echo "$SQM_DOWN$SQM_UP" | grep -q '[^0-9]'; then
	# Rates tuned by hand: used as they are, nothing measured.
	step "SQM: fixed rates from the settings"
	RATE_DOWN=$SQM_DOWN RATE_UP=$SQM_UP SQM_OK=1
	SQM_MSG="SQM fixed rates from the settings: $RATE_DOWN / $RATE_UP kbit/s"
else
	step "SQM: measuring line speed (about $((SPEED_DUR * 2)) s)"
	DOWN=$(measure down); UP=$(measure up)
	CPU_DOWN=$(cat /tmp/setup-speed.cpu-down 2>/dev/null) CPU_UP=$(cat /tmp/setup-speed.cpu-up 2>/dev/null)
	rm -f /tmp/setup-speed.cpu-down /tmp/setup-speed.cpu-up
	codes=$(sort -u /tmp/setup-speed.codes 2>/dev/null | tr '\n' ' '); codes=${codes:-none}
	rm -f /tmp/setup-speed.codes
	if [ "${DOWN:-0}" -gt 1000 ] && [ "${UP:-0}" -gt 1000 ]; then
		RATE_DOWN=$((DOWN * 90 / 100)) RATE_UP=$((UP * 90 / 100)) SQM_OK=1
		SQM_MSG="SQM measured ${DOWN} down / ${UP} up kbit/s (sustained, after ${SPEED_WARM} s warm-up), shaping at 90%: $RATE_DOWN / $RATE_UP kbit/s"
		# The test runs on this router: a core with nothing to spare was the limit, not the line.
		if [ "${CPU_DOWN:-0}" -ge 90 ] || [ "${CPU_UP:-0}" -ge 90 ]; then
			info "a CPU core of the router was fully busy during the speed test (download ${CPU_DOWN:-?}%, upload ${CPU_UP:-?}%), so the line may be faster than measured; if so, set SQM_DOWN/SQM_UP in private/config.env"
		fi
	elif [ -n "${SQM_FALLBACK_DOWN-}" ] && [ -n "${SQM_FALLBACK_UP-}" ] \
		&& ! echo "$SQM_FALLBACK_DOWN$SQM_FALLBACK_UP" | grep -q '[^0-9]' \
		&& [ "$SQM_FALLBACK_DOWN" -ge 100 ] && [ "$SQM_FALLBACK_UP" -ge 100 ]; then
		RATE_DOWN=$SQM_FALLBACK_DOWN RATE_UP=$SQM_FALLBACK_UP SQM_OK=
		SQM_MSG="SQM speed test failed (down=${DOWN:-0} up=${UP:-0} kbit/s, speed test HTTP codes: $codes); using saved rates $RATE_DOWN / $RATE_UP kbit/s"
	else
		RATE_DOWN='' SQM_OK=''
		SQM_MSG="SQM speed test failed (down=${DOWN:-0} up=${UP:-0} kbit/s, speed test HTTP codes: $codes) and no saved rates; SQM left off, re-run setup later"
	fi
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

# The guide's check that the rates are right: ping while the line is loaded in
# both directions. Up to 30 ms more than idle is fine (the "A" grade of the
# Waveform bufferbloat test); more means the rates are above what the line
# really carries.
# The pings start after the warm-up, so a cable line's extra speed at the
# start is used up before they count. Whether the line was really loaded is
# read from the WAN device's counters over the time of the pings (they include
# the download's acknowledgements, which fill a small upload direction).
if [ -n "$RATE_DOWN" ] && [ -z "$SQM_OK" ]; then
	info "SQM latency under load not checked: the speed test server is not usable right now"
elif [ -n "$RATE_DOWN" ]; then
	LOAD_DUR=$((SPEED_WARM + 8))
	step "SQM: latency under load (about $((LOAD_DUR + 6)) s)"
	PING_TO=1.1.1.1; [ -n "$HAS_V4" ] || PING_TO=2606:4700:4700::1111
	RTT_IDLE=$(ping -c 5 -W 2 $PING_TO 2>/dev/null | rtt_median)
	load down $LOAD_DUR > /tmp/setup-load-down.$$ &
	load up $LOAD_DUR > /tmp/setup-load-up.$$ &
	sleep $SPEED_WARM
	c0="$(cut -d' ' -f1 /proc/uptime) $(wan_bytes rx_bytes) $(wan_bytes tx_bytes)"
	PINGS=$(ping -c 7 -W 2 $PING_TO 2>/dev/null)
	c1="$(cut -d' ' -f1 /proc/uptime) $(wan_bytes rx_bytes) $(wan_bytes tx_bytes)"
	wait
	RTT_LOAD=$(echo "$PINGS" | rtt_median) RTT_GOT=$(echo "$PINGS" | rtt_replies)
	LOAD_DOWN=$(printf '%s\n%s\n' "$c0" "$c1" | cut -d' ' -f1,2 | sustained_kbit -1)
	LOAD_UP=$(printf '%s\n%s\n' "$c0" "$c1" | cut -d' ' -f1,3 | sustained_kbit -1)
	codes=$(cat /tmp/setup-load-down.$$ /tmp/setup-load-up.$$ | awk '$2 !~ /^(2|000)/ { print $2 }' | sort -u | tr '\n' ' ')
	rm -f /tmp/setup-load-down.$$ /tmp/setup-load-up.$$
	LOAD_MSG="load ${LOAD_DOWN:-0} down / ${LOAD_UP:-0} up kbit/s"
	if [ -z "$RTT_IDLE" ]; then
		info "SQM latency under load not checked: no ping replies from $PING_TO"
	elif [ $((${LOAD_DOWN:-0} * 2)) -lt "$RATE_DOWN" ] || [ $((${LOAD_UP:-0} * 2)) -lt "$RATE_UP" ]; then
		# Not loaded in both directions: a good result would mean nothing.
		info "SQM latency under load not checked: the $LOAD_MSG was under half the shaped $RATE_DOWN / $RATE_UP in a direction${codes:+ (speed test HTTP codes: $codes)}; the speed test server gave too little, or the rates are far above what the line carries"
	elif [ "$RTT_GOT" -lt 4 ]; then
		fail "SQM latency under load: only $RTT_GOT of 7 pings answered ($LOAD_MSG); lower the rates: set SQM_DOWN/SQM_UP in private/config.env below $RATE_DOWN / $RATE_UP"
	else
		RTT_ADD=$((RTT_LOAD - RTT_IDLE)); [ $RTT_ADD -lt 0 ] && RTT_ADD=0
		RTT_MSG="SQM latency under load: +$RTT_ADD ms (idle $RTT_IDLE ms, loaded $RTT_LOAD ms, $RTT_GOT of 7 pings answered, $LOAD_MSG)"
		if [ $RTT_ADD -le 30 ]; then pass "$RTT_MSG"
		else fail "$RTT_MSG; lower the rates: set SQM_DOWN/SQM_UP in private/config.env below $RATE_DOWN / $RATE_UP"; fi
	fi
fi

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
if [ -n "$REDLIB" ]; then
	/etc/init.d/redlib enable
	if /usr/sbin/redlib-update >/tmp/setup-redlib.log 2>&1; then
		/etc/init.d/redlib restart   # also when it was current: settings may have changed
		pass "Redlib $(cat /etc/redlib.version) at http://reddit.lan ($REDLIB_IP), adult content $( [ "$SFW" = on ] && echo 'locked off' || echo 'off by default'); updates daily 03:40 to releases 3+ days old"
	elif [ -x /usr/sbin/redlib ]; then
		# The installed one keeps running; only the update check failed.
		/etc/init.d/redlib restart
		info "Redlib $(cat /etc/redlib.version 2>/dev/null) kept at http://reddit.lan: $(tail -1 /tmp/setup-redlib.log); checked again daily at 03:40"
	else
		fail "Redlib not installed: $(tail -1 /tmp/setup-redlib.log); tried again daily at 03:40"
	fi
fi
/etc/init.d/cron enable; /etc/init.d/cron restart
if [ -n "$ZT" ]; then
	/etc/init.d/zerotier enable; /etc/init.d/zerotier restart >/dev/null 2>&1
	zt_net() { zerotier-cli -j listnetworks 2>/dev/null | jsonfilter -e "@[@.id='$ZEROTIER_NETWORK'].$1"; }
	online() { [ "$(zerotier-cli -j info 2>/dev/null | jsonfilter -e @.online)" = true ]; }
	i=0; until online || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
	i=0; until case $(zt_net status) in ''|REQUESTING_CONFIGURATION) false ;; esac || [ $i -ge 20 ]; do sleep 1; i=$((i + 1)); done
	node=$(zerotier-cli -j info 2>/dev/null | jsonfilter -e @.address)
	st=$(zt_net status); online || st=offline
	# A public network lets anyone with its ID in: leave it.
	if [ "$(zt_net type)" = PUBLIC ]; then
		zerotier-cli leave "$ZEROTIER_NETWORK" >/dev/null 2>&1
		uci -q delete zerotier.oneclick; uci commit zerotier
		st=public
	fi
	case $st in
		public) fail "ZeroTier: network $ZEROTIER_NETWORK is public (anyone with its ID could reach the router): left it; set Access Control to Private at my.zerotier.com and run the setup again" ;;
		offline) fail "ZeroTier: the router can't reach ZeroTier's servers (UDP 9993 out; see: logread -e zerotier)" ;;
		OK) a=$(zt_net 'assignedAddresses[*]' | grep -v : | head -1 | cut -d/ -f1)
			pass "ZeroTier: router $node is in network $ZEROTIER_NETWORK${a:+ at $a}${a:-, without an IPv4 address (turn on IPv4 auto-assign for the network)}" ;;
		ACCESS_DENIED|REQUESTING_CONFIGURATION)
			info "ZeroTier: router $node waits for approval in network $ZEROTIER_NETWORK (my.zerotier.com > Members)" ;;
		NOT_FOUND) fail "ZeroTier: network $ZEROTIER_NETWORK does not exist (check the ID at my.zerotier.com)" ;;
		'') fail "ZeroTier: network $ZEROTIER_NETWORK not joined (see: logread -e zerotier)" ;;
		*) info "ZeroTier: network $ZEROTIER_NETWORK: $(zt_net status)" ;;
	esac
fi
/etc/init.d/banip enable; /etc/init.d/banip restart >/dev/null 2>&1
if [ -n "$VPN" ]; then
	/etc/init.d/pbr enable; /etc/init.d/pbr restart >/dev/null 2>&1
	if on "${TELEGRAM_VIA_VPN:-0}"; then
		if r=$(/usr/sbin/telegram-ranges 2>&1); then
			pass "Telegram through $VPN: Telegram's own list ($(echo "$r" | sed -n 's/.*: \([0-9]*\) IPv4 ranges.*/\1/p') ranges) and its web domains, refreshed daily 04:20"
		else
			info "Telegram through $VPN: list not updated (${r#telegram-ranges: }); the copy from the setup is in use, tried again daily 04:20"
		fi
	fi
	if [ -n "$TG_PROXY" ]; then
		/etc/init.d/microsocks enable; /etc/init.d/microsocks restart >/dev/null 2>&1
		grep -qxF "$TG_PROXY_NFT" /etc/sysupgrade.conf || echo "$TG_PROXY_NFT" >> /etc/sysupgrade.conf
		pass "Telegram proxy: SOCKS5 on $LAN_IP port ${TELEGRAM_PROXY_PORT:-1080} (and the router's ZeroTier address), Telegram only, through $VPN"
	fi
	if [ -f /etc/proton-pick.conf ] && [ -f /etc/proton/session ]; then
		rm -f /tmp/proton/loads   # a PASS below must come from this refresh
		/usr/sbin/proton-pick refresh >/dev/null 2>&1
		if [ -f /tmp/proton/session-ended ]; then
			fail "Proton ended the session: run ./proton-login.sh, then ./setup.sh"
		elif [ -s /tmp/proton/loads ]; then
			pass "Proton server list: $(wc -l < /tmp/proton/loads) servers ${PROTON_COUNTRIES:+in $PROTON_COUNTRIES }(refreshed daily, tunnel checked every 5 min)"
		else
			fail "Proton server list could not be fetched (see: logread -e proton-pick)"
		fi
	fi
elif [ -x /etc/init.d/pbr ]; then
	/etc/init.d/pbr stop >/dev/null 2>&1; /etc/init.d/pbr disable
fi
if [ -n "$TS" ]; then
	/etc/init.d/tailscale enable; /etc/init.d/tailscale restart >/dev/null 2>&1
	ts_state() { /usr/sbin/tailscale status --json 2>/dev/null | jsonfilter -e @.BackendState; }
	i=0; until [ -n "$(ts_state)" ] || [ $i -ge 30 ]; do sleep 1; i=$((i + 1)); done
	# Offered to the tailnet: Telegram's IPv4 ranges, as the VPN rules have
	# them now (telegram-ranges keeps them current, also here).
	routes=''
	if [ -n "$VPN" ] && on "${TELEGRAM_VIA_VPN:-0}"; then
		p=$(uci -q show pbr | sed -n "s/^pbr\.\([^.]*\)\.name='Telegram through VPN'$/\1/p" | head -1)
		routes=$(uci -q get "pbr.$p.dest_addr" | tr ' ' '\n' | grep -E '^[0-9.]+/[0-9]+$' | tr '\n' ',' | sed 's/,$//')
	fi
	# No DNS or routes from the tailnet; no firewall rules of its own (the zone above).
	flags="--accept-dns=false --accept-routes=false --netfilter-mode=off --advertise-routes=$routes"
	if [ "$(ts_state)" = NeedsLogin ] && [ -s "$PRIV/tailscale-authkey" ]; then
		# The key goes in a file: a command line would show it in the process list.
		(umask 077; tr -d ' \r\n' < "$PRIV/tailscale-authkey" > /tmp/setup-ts-key)
		# shellcheck disable=SC2086
		ts_out=$(/usr/sbin/tailscale up --auth-key=file:/tmp/setup-ts-key --timeout=90s $flags 2>&1); ts_rc=$?
		rm -f /tmp/setup-ts-key
	else
		# shellcheck disable=SC2086
		ts_out=$(/usr/sbin/tailscale set $flags 2>&1); ts_rc=$?
	fi
	if [ $ts_rc = 0 ] && [ -n "$routes" ]; then echo "$routes" > /etc/tailscale/oneclick-routes; else rm -f /etc/tailscale/oneclick-routes; fi
	i=0; until case $(ts_state) in Running|NeedsMachineAuth) true ;; *) false ;; esac || [ $i -ge 20 ]; do sleep 1; i=$((i + 1)); done
	ts_self() { /usr/sbin/tailscale status --json 2>/dev/null | jsonfilter -e "@.Self.$1"; }
	case $(ts_state) in
		Running)
			TS_IP=$(/usr/sbin/tailscale ip -4 2>/dev/null | head -1)
			pass "Tailscale: the router is $TS_IP in your tailnet ($(ts_self HostName)); devices there reach LuCI, SSH${ENABLE_MANGADEX:+$(on "$ENABLE_MANGADEX" && echo ", the MangaDex app (http://$TS_IP/mangadex-safe/)")}"
			if [ -n "$routes" ]; then
				if ts_self 'PrimaryRoutes[*]' | grep -qx 149.154.160.0/20; then
					pass "Tailscale: Telegram's ranges offered and approved: phones with Tailscale on send Telegram (calls too) through $VPN"
				else
					info "Tailscale: approve the router's routes (Telegram's ranges) at https://login.tailscale.com/admin/machines > $(ts_self HostName) > Edit route settings"
				fi
			fi
			[ -n "$(ts_self KeyExpiry)" ] && info "Tailscale: the router's login expires on $(ts_self KeyExpiry | cut -c1-10); turn that off at https://login.tailscale.com/admin/machines > $(ts_self HostName) > Disable key expiry"
			;;
		NeedsMachineAuth) info "Tailscale: approve the router at https://login.tailscale.com/admin/machines" ;;
		NeedsLogin) fail "Tailscale: not logged in ($(echo "$ts_out" | grep -v -i 'warning\|ethtool\|^$' | tail -1 | cut -c1-200)); put a new auth key in private/tailscale-authkey and run the setup again" ;;
		*) fail "Tailscale: $(ts_state) ($(echo "$ts_out" | tail -1 | cut -c1-200))" ;;
	esac
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
	# An instance from the list itself (the list changes; a fixed name went stale).
	ri=$(awk '/^# >>> redlib$/{s=1; next} /^# <<< redlib$/{s=0} s' /etc/adblock-lean/blocklist \
		| awk 'FILENAME == ARGV[1] { allow[$0] = 1; next } !($0 in allow)' /etc/redlib-block.allow - | head -1)
	if [ -n "$ri" ]; then check "Redlib: listed instance $ri blocked" "blocked $ri"
	else fail "Redlib: no listed instance in the block list"; fi
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
if [ -n "$REDLIB" ] && [ -x /usr/sbin/redlib ]; then
	i=0; until uclient-fetch -qO /dev/null "http://$REDLIB_IP:8080/settings" 2>/dev/null || [ $i -ge 15 ]; do sleep 1; i=$((i + 1)); done
	rpid=$(pidof redlib)
	check "Redlib runs as its own user, first to go if memory runs out" "[ -n '$rpid' ] && [ \"\$(awk '/^Uid:/ { print \$2 }' /proc/$rpid/status)\" = \"\$(id -u redlib)\" ] && [ \"\$(cat /proc/$rpid/oom_score_adj)\" = 1000 ]"
	check "Redlib answers on $REDLIB_IP" "uclient-fetch -qO- http://$REDLIB_IP:8080/settings | grep -q 'Redlib'"
	check "reddit.lan -> $REDLIB_IP" "[ \"\$(resolve reddit.lan)\" = $REDLIB_IP ]"
	check "Redlib: port 80 mapped, its DNS skips the block lists" "nft list chain inet fw4 dstnat_lan | grep -q '$REDLIB_IP.*dnat' && nft list chain inet fw4 oneclick_redlib_dns | grep -q 'redirect to :5354'"
	[ -n "$rpid" ] && info "Redlib uses $(awk '/^VmRSS/ { printf "%d MB", $2 / 1024 }' /proc/$rpid/status) of memory"
	if uclient-fetch -T 30 -qO /dev/null "http://$REDLIB_IP:8080/r/popular" 2>/dev/null; then
		info "Redlib fetched a page from Reddit"
	else
		info "Redlib could not fetch a page from Reddit right now (Reddit may be refusing it; see http://reddit.lan)"
	fi
fi
if [ -n "$VPN" ]; then
	i=0; while [ $i -lt 10 ] && [ "$(wg show "$VPN" latest-handshakes 2>/dev/null | awk '{print $2}')" = 0 ]; do sleep 3; i=$((i + 1)); done
	check "VPN WireGuard handshake" "[ \"\$(wg show $VPN latest-handshakes | awk '{print \$2}')\" -gt 0 ]"
	check "PBR active (no errors, $VPN gateway)" "pbr_ok"
	if [ -n "$TG_PROXY" ]; then
		# The password goes to curl on stdin, not on its command line (ps shows those).
		viaproxy() { # PASSWORD URL -> curl's exit code (97: the proxy refused)
			printf 'proxy = "socks5h://%s:%s@127.0.0.1:%s"\n' "$TELEGRAM_PROXY_USER" "$1" "${TELEGRAM_PROXY_PORT:-1080}" \
				| curl -K - -s -m 15 -o /dev/null "$2"
		}
		mpid=$(pidof microsocks)
		check "Telegram proxy runs as its own user" "[ -n '$mpid' ] && [ \"\$(awk '/^Uid:/ { print \$2 }' /proc/$mpid/status)\" = \"\$(id -u microsocks)\" ]"
		check "Telegram proxy refuses other addresses (1.1.1.1)" "viaproxy \"\$TELEGRAM_PROXY_PASS\" http://1.1.1.1/; [ \$? = 97 ]"
		check "Telegram proxy refuses the router's unfiltered DNS (127.0.0.1:5354)" "viaproxy \"\$TELEGRAM_PROXY_PASS\" http://127.0.0.1:5354/; [ \$? = 97 ]"
		check "Telegram proxy refuses a wrong password" "viaproxy wrong https://core.telegram.org/; [ \$? = 97 ]"
		if viaproxy "$TELEGRAM_PROXY_PASS" https://core.telegram.org/resources/cidr.txt; then
			info "Telegram proxy reaches Telegram (through $VPN)"
		else
			info "Telegram proxy could not reach Telegram right now (is $VPN up?)"
		fi
	fi
	on "${TELEGRAM_VIA_VPN:-0}" && check "Telegram's ranges routed through $VPN (149.154.160.0/20 in pbr)" \
		"nft list chain inet fw4 pbr_prerouting | grep -q '149.154.160.0/20.*Telegram through VPN'"
fi
if [ -n "$TS" ]; then
	tpid=$(pidof tailscaled)
	check "Tailscale runs in its own group (its DNS skips the block lists)" "[ -n '$tpid' ] && [ \"\$(awk '/^Gid:/ { print \$2 }' /proc/$tpid/status)\" = \"\$(sed -n 's/^tailscale:[^:]*:\([0-9]*\):.*/\1/p' /etc/group)\" ] && nft list chain inet fw4 oneclick_tailscale_dns | grep -q 'redirect to :5354'"
	[ -n "$tpid" ] && info "Tailscale uses $(awk '/^VmRSS/ { printf "%d MB", $2 / 1024 }' /proc/$tpid/status) of memory"
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
