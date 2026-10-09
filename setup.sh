#!/bin/sh
# One-click OpenWrt setup. Run on a computer plugged into a freshly installed
# OpenWrt router (router's WAN port in the internet box):
#
#   ./setup.sh                      # router at 192.168.1.1
#   ./setup.sh HOST [PORT]          # another address
#   ./setup.sh --reconfigure [...]  # change the saved answers first
#   ./setup.sh --settings-only      # only create/change the saved answers
#
# First run: asks for your settings and offers to save them in
# private/config.env (gitignored). Then it copies router/ plus your private
# files to the router's RAM, runs router/install.sh there, prints its report
# and deletes the copy (it holds secrets).

set -eu
exec 3>&2   # the terminal, for questions asked while stderr is redirected
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/laptop.sh"

RECONF='' ONLY=''
case ${1-} in
	--reconfigure) RECONF=1; shift ;;
	--settings-only) RECONF=1 ONLY=1; shift ;;
esac
HOST=${1:-192.168.1.1}
PORT=${2:-22}
PRIV=${ONECLICK_PRIVATE:-$HERE/private}   # override for tests
CONF=$PRIV/config.env
STAGE=$(mktemp -d)
cleanup() { [ -t 0 ] && stty echo 2>/dev/null; rm -rf "$STAGE"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------ settings
wizard() {
	say ""
	say "Router settings. Press Enter to accept the value in [brackets]."
	ask WIFI_SSID "Wi-Fi name" "${WIFI_SSID:-OpenWrt}"
	if [ -z "${WIFI_KEY-}" ] || ask_yn "Change the Wi-Fi password?" n; then
		while ask_secret WIFI_KEY "Wi-Fi password (8+ characters)"; do
			[ ${#WIFI_KEY} -ge 8 ] && break; say "  Too short."
			[ -t 0 ] || break   # no terminal: don't eat the next answers; validation reports it
		done
	fi
	WIFI_ENCRYPTION=${WIFI_ENCRYPTION:-sae-mixed}
	if [ -z "${ROOT_PASSWORD_HASH-}" ] || ask_yn "Change the router admin (root) password?" n; then
		OPENSSL=$(find_openssl) || { say "Need OpenSSL 1.1.1+ for 'openssl passwd -5' (macOS: brew install openssl@3)."; exit 1; }
		_pw=''; ask_secret _pw "Router admin password"
		ROOT_PASSWORD_HASH=$(printf '%s' "$_pw" | "$OPENSSL" passwd -5 -stdin); unset _pw
	fi

	d=${SSH_KEY:-$HOME/.ssh/id_ed25519}
	_prev_key=${SSH_KEY-} _prev_pub=${SSH_PUBKEYS-}
	ask SSH_KEY "SSH key this computer logs in with" "$d"
	if [ ! -f "$SSH_KEY" ]; then
		ask_yn "$SSH_KEY doesn't exist. Create it?" y || { say "Need an SSH key."; exit 1; }
		ssh-keygen -q -t ed25519 -N '' -C openwrt-oneclick -f "$SSH_KEY"
	fi
	SSH_PUBKEYS=$(cat "$SSH_KEY.pub")
	# A changed key: log in with the old one until the router has the new one.
	if [ -n "$_prev_key" ] && [ "$_prev_pub" != "$SSH_PUBKEYS" ]; then
		# shellcheck disable=SC2034  # saved by write_config
		SSH_KEY_OLD=$_prev_key SSH_PUBKEYS_OLD=$_prev_pub
	fi

	ask TZ_NAME "Time zone" "${TZ_NAME:-$(laptop_tz)}"
	TZ_POSIX=$(posix_tz "$TZ_NAME") || { say "Unknown time zone $TZ_NAME, using UTC."; TZ_NAME=UTC TZ_POSIX=UTC0; }
	ask WIFI_COUNTRY "Wi-Fi country code (sets legal channels and power)" "${WIFI_COUNTRY:-$(country_for_tz "$TZ_NAME")}"
	WIFI_COUNTRY=$(printf '%s' "$WIFI_COUNTRY" | tr 'a-z' 'A-Z')

	if ask_yn "Does your provider need a PPPoE username and password?" "$( [ "${WAN_PROTO-}" = pppoe ] && echo y || echo n)"; then
		WAN_PROTO=pppoe
		ask PPPOE_USER "PPPoE username" "${PPPOE_USER-}"
		ask_secret PPPOE_PASS "PPPoE password"
	else
		# shellcheck disable=SC2034  # saved by write_config
		WAN_PROTO=dhcp PPPOE_USER='' PPPOE_PASS=''
	fi
	ask_link_type LINK_TYPE "${LINK_TYPE-}"

	say ""
	say "Family filtering: safe search on Google/Bing/DuckDuckGo/Brave/Startpage/Yandex,"
	say "adult and anime-NSFW block lists, and blocking of DNS/VPN tricks that get around them."
	if ask_yn "Turn on family filtering?" "$(yn "${FAMILY_FILTER:-1}")"; then
		FAMILY_FILTER=1
		ADBLOCK_EXTRA_LISTS=$(words_with "${ADBLOCK_EXTRA_LISTS-}" "$FAMILY_LISTS")
		BANIP_FEEDS=$(words_with "${BANIP_FEEDS-}" "$FAMILY_FEEDS")
		ask REDLIB_ALLOW "Redlib (Reddit viewer) instances to keep reachable, space separated (Enter = block all)" "${REDLIB_ALLOW-}"
	else
		FAMILY_FILTER=0 REDLIB_ALLOW=
		ADBLOCK_EXTRA_LISTS=$(words_without "${ADBLOCK_EXTRA_LISTS-}" "$FAMILY_LISTS")
		BANIP_FEEDS=$(words_without "${BANIP_FEEDS-}" "$FAMILY_FEEDS")
	fi

	say ""
	if ask_yn "Send chosen sites through a WireGuard VPN (Proton VPN or any provider)?" "$(yn "${ENABLE_VPN:-0}")"; then
		ENABLE_VPN=1
		if [ -z "${WG_PRIVATE_KEY-}" ] || ask_yn "Load a new WireGuard config file?" n; then
			while :; do
				ask _wg "Path to the provider's WireGuard .conf file"
				case $_wg in \~/*) _wg=$HOME/${_wg#\~/} ;; esac
				if [ -f "$_wg" ] && _p=$(parse_wg_conf "$_wg"); then eval "$_p"; break; fi
				say "  Can't read a WireGuard config from that file."
				[ -t 0 ] || exit 1
			done
		fi
		ask VPN_IFACE "Name for the VPN interface" "${VPN_IFACE:-vpn}"
		ask VPN_ROUTE_DOMAINS "Domains to send through the VPN, space separated" "${VPN_ROUTE_DOMAINS-}"
		ask VPN_ROUTE_SUBNETS "IP ranges to send through the VPN, space separated (optional)" "${VPN_ROUTE_SUBNETS-}"
	else
		ENABLE_VPN=0
	fi
	if ask_yn "Install the MangaDex safe-mode reader (opens at http://manga.lan)?" "$(yn "${ENABLE_MANGADEX:-0}")"; then
		ENABLE_MANGADEX=1
	else
		ENABLE_MANGADEX=0
	fi

	say ""
	say "Remote access: reach your home network (and manga.lan) from anywhere through"
	say "a WireGuard tunnel to the router. Each device gets its own key."
	if ask_yn "Turn on remote access?" "$(yn "${ENABLE_REMOTE:-0}")"; then
		ENABLE_REMOTE=1
		say "  A dynamic-DNS name (e.g. myhome.duckdns.org) keeps working when your provider"
		say "  changes your address; without one, the router's current address is used."
		ask REMOTE_HOST "Public name or address of your home (Enter = the router's current one)" "${REMOTE_HOST-}"
		ask REMOTE_PORT "UDP port for the tunnel" "${REMOTE_PORT:-51820}"
		_d=$(remote_devices)
		ask _d "Devices that may connect, space separated" "${_d:-phone laptop}"
		OPENSSL=$(find_openssl) || { say "Need OpenSSL 1.1.1+ to make WireGuard keys (macOS: brew install openssl@3)."; exit 1; }
		REMOTE_NET=${REMOTE_NET:-10.77.0.0/24}
		[ -n "${REMOTE_SERVER_KEY-}" ] || REMOTE_SERVER_KEY=$(wg_genkey)
		REMOTE_PEERS=$(remote_peers_for "$_d") || { say "Too many devices (at most 253)."; exit 1; }
	else
		ENABLE_REMOTE=0
	fi
}

validate() { # stop before saving or using broken settings
	problems=$(check_settings)
	[ -z "$problems" ] && return 0
	say "Settings problems:"; printf '%s\n' "$problems" | sed 's/^/  /' >&2
	say "Fix them with ./setup.sh --reconfigure (or edit $CONF)."
	exit 1
}

if [ -f "$CONF" ]; then
	# shellcheck source=/dev/null
	. "$CONF"
	if migrate_adblock_lists; then   # older settings: base lists now come from adblock-lean
		write_config "$CONF"; say "Moved the block lists in $CONF to ADBLOCK_EXTRA_LISTS (base lists now fit the router)"
	fi
	[ -n "$RECONF" ] && wizard
	if [ -z "${LINK_TYPE-}" ]; then   # older settings files: ask, then save
		ask_link_type LINK_TYPE || exit 1
		write_config "$CONF"; say "Saved the link type in $CONF"
	fi
	if [ -z "${WIFI_COUNTRY-}" ]; then
		ask WIFI_COUNTRY "Wi-Fi country code (sets legal channels and power)" "$(country_for_tz "${TZ_NAME-}")"
		WIFI_COUNTRY=$(printf '%s' "$WIFI_COUNTRY" | tr 'a-z' 'A-Z')
		write_config "$CONF"; say "Saved the Wi-Fi country in $CONF"
	fi
	[ -n "$RECONF" ] && { validate; mkdir -p "$PRIV"; write_config "$CONF"; say "Saved $CONF"; }
	USED=$CONF
else
	say "No private settings yet ($CONF)."
	ask_yn "Answer a few questions to create them now?" y || exit 1
	wizard
	validate
	if ask_yn "Save these settings in $CONF for next time (kept off git)?" y; then
		mkdir -p "$PRIV"; chmod 700 "$PRIV"
		write_config "$CONF"; USED=$CONF; say "Saved $CONF"
	else
		USED=$STAGE/config.env; write_config "$USED"
	fi
fi
validate
[ -n "$ONLY" ] && exit 0

# ------------------------------------------------------------------ connect
KEY=$SSH_KEY
# A fresh router has a new host key; a router this tool set up before has the
# saved one (private/host_keys). Trust the saved key strictly and a fresh one
# on first use, without touching ~/.ssh/known_hosts.
KNOWN_OLD=$STAGE/known_hosts.saved
KNOWN_NEW=$STAGE/known_hosts.fresh
target=$HOST; [ "$PORT" = 22 ] || target="[$HOST]:$PORT"
: > "$KNOWN_OLD"
[ -f "$PRIV/host_keys/host_keys.pub" ] && sed "s|^|$target |" "$PRIV/host_keys/host_keys.pub" > "$KNOWN_OLD"

ssh_with() { # known_hosts-file strictness command...
	f=$1 strict=$2; shift 2
	ssh -p "$PORT" -i "$KEY" ${SSH_KEY_OLD:+-i "$SSH_KEY_OLD"} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
		-o UserKnownHostsFile="$f" -o StrictHostKeyChecking="$strict" "root@$HOST" "$@"
}
# Without saved keys: trust on first use. With saved keys: a different key is
# only accepted after a person confirms this is a freshly installed router;
# otherwise settings (passwords, keys) could go to whatever answers at $HOST.
TRUST_NEW=; [ -s "$KNOWN_OLD" ] || TRUST_NEW=1
ssh_r() { # 255 = could not connect/authenticate; the command never ran
	s_rc=0; ssh_with "$KNOWN_OLD" yes "$@" 2>"$STAGE/ssh.err" || s_rc=$?
	[ $s_rc -eq 255 ] || return $s_rc
	if [ -z "$TRUST_NEW" ] && grep -qE 'Host key verification failed|HOST IDENTIFICATION HAS CHANGED' "$STAGE/ssh.err"; then
		say "The router at $HOST has a different SSH key than the one saved in private/host_keys." 2>&3
		say "That is expected right after a fresh OpenWrt install, and a warning sign otherwise." 2>&3
		if [ -t 0 ] && ask_yn "Is this a freshly installed router?" n 2>&3; then TRUST_NEW=1; else exit 1; fi
	fi
	[ -n "$TRUST_NEW" ] || return 255
	ssh_with "$KNOWN_NEW" accept-new "$@"
}

say "Connecting to $HOST:$PORT ..."
i=0
until ssh_r true 2>/dev/null; do
	i=$((i + 1))
	[ $i -ge 20 ] && { say "Cannot log in to root@$HOST:$PORT. Is it a fresh OpenWrt (no root password) or one set up with this tool and key?"; exit 1; }
	sleep 3
done

# ------------------------------------------------------------------ bundle
mkdir -p "$STAGE/b/private"
cp -R "$HERE/router" "$STAGE/b/router"
cp "$USED" "$STAGE/b/private/config.env"
link_params "$LINK_TYPE" | awk '{ printf "LINK_LL=%s\nLINK_OVERHEAD=%s\nLINK_MPU=%s\n", $1, $2, $3 }' >> "$STAGE/b/private/config.env"
for f in blocklist.txt allowlist.txt; do [ -f "$PRIV/$f" ] && cp "$PRIV/$f" "$STAGE/b/private/"; done
[ -d "$PRIV/host_keys" ] && cp -R "$PRIV/host_keys" "$STAGE/b/private/host_keys"

say "Copying settings to the router's RAM ..."
tar -C "$STAGE/b" -czf - router private \
	| ssh_r 'rm -rf /tmp/setup && mkdir -m 700 /tmp/setup && tar -C /tmp/setup -xzf -'

say "Running the installer on the router (5-10 minutes) ..."
ssh_r 'rm -f /tmp/setup.log /tmp/setup.rc
	( setsid sh -c "sh /tmp/setup/router/install.sh > /tmp/setup.log 2>&1; echo \$? > /tmp/setup.rc; rm -rf /tmp/setup" </dev/null >/dev/null 2>&1 & )'

# Follow the log. The installer restarts the network and SSH, so reconnect as needed.
shown=0 started=$(date +%s)
while :; do
	sleep 5
	if [ $(( $(date +%s) - started )) -gt 2400 ]; then
		say "No result after 40 minutes; check /tmp/setup.log on the router."; exit 1
	fi
	chunk=$(ssh_r "awk -v s=$shown 'NR > s' /tmp/setup.log 2>/dev/null; echo \"@@RC=\$(cat /tmp/setup.rc 2>/dev/null)\"" 2>/dev/null) || continue
	rc=${chunk##*@@RC=}
	body=$(printf '%s\n' "$chunk" | sed '/^@@RC=/d')
	if [ -n "$body" ]; then
		printf '%s\n' "$body"
		shown=$((shown + $(printf '%s\n' "$body" | wc -l)))
	fi
	[ -n "$rc" ] && break
done
ssh_r 'rm -rf /tmp/setup' 2>/dev/null || true

# Keep this router's SSH identity for future re-installs (only if settings are saved).
if [ "$USED" = "$CONF" ] && [ ! -f "$PRIV/host_keys/host_keys.pub" ] && [ "$rc" != 1 ]; then
	mkdir -p "$PRIV/host_keys"; chmod 700 "$PRIV/host_keys"
	if ssh_r 'tar -C /etc/dropbear -cf - dropbear_ed25519_host_key dropbear_rsa_host_key' | (umask 077; tar -C "$PRIV/host_keys" -xf -) \
		&& ssh_r 'for k in /etc/dropbear/dropbear_*_host_key; do dropbearkey -y -f $k | grep "^ssh-" | cut -d" " -f1,2; done' > "$PRIV/host_keys/host_keys.pub"; then
		say "Saved the router's SSH host keys in private/host_keys (reused on re-install)."
	else
		rm -rf "$PRIV/host_keys"
	fi
fi

if [ -n "${SSH_KEY_OLD-}" ] && [ "$USED" = "$CONF" ] && [ "$rc" != 1 ]; then
	unset SSH_KEY_OLD SSH_PUBKEYS_OLD
	write_config "$CONF"
fi

# Remote access: one WireGuard config per device, for the home network the
# router actually has and its current address unless a name was given.
if [ "${ENABLE_REMOTE-}" = 1 ] && [ "$rc" != 1 ]; then
	info=$(ssh_r '. /lib/functions/network.sh; network_get_subnet s lan; eval "$(ipcalc.sh "$s")"; echo "$NETWORK/$PREFIX"
		network_get_ipaddr a wan; [ -n "$a" ] || network_get_ipaddr6 a wan6; echo "$a"' 2>/dev/null) || info=
	lan_net=$(printf '%s\n' "$info" | sed -n 1p) wan_ip=$(printf '%s\n' "$info" | sed -n 2p)
	endpoint=${REMOTE_HOST:-$wan_ip}
	if [ -z "$lan_net" ] || [ -z "$endpoint" ]; then
		say "Could not read the router's network or address; remote-access configs not written."
	else
		mkdir -p "$PRIV/remote"; chmod 700 "$PRIV/remote"
		for d in $(remote_devices); do
			(umask 077; remote_client_conf "$d" "$lan_net" "$endpoint" > "$PRIV/remote/$d.conf")
		done
		say ""
		say "Remote access: WireGuard configs for $(remote_devices) are in $PRIV/remote/."
		say "  Import one into the WireGuard app on that device (phones: qrencode -t ansiutf8 < FILE shows a QR code)."
		if [ -z "${REMOTE_HOST-}" ]; then
			say "  They point at the router's current address $endpoint; set a dynamic-DNS name"
			say "  (./setup.sh --reconfigure) if your provider changes it."
		fi
		if [ -z "${REMOTE_HOST-}" ] && behind_nat_v4 "$wan_ip"; then
			say "  Warning: $wan_ip is a private or carrier-grade NAT address, so the router can't be"
			say "  reached from outside. Forward UDP port $REMOTE_PORT to it on your modem, or ask your"
			say "  provider for a public IPv4 address."
		fi
	fi
fi

case $rc in
	0) say ""; say "Done: everything passed." ;;
	2) say ""; say "Done, but some checks FAILED (see the report above). Full log: /tmp/setup.log on the router." ;;
	*) say ""; say "Setup stopped early (exit $rc). Full log: /tmp/setup.log on the router." ;;
esac
exit "$rc"
