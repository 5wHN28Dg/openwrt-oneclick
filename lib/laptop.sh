# Helpers for setup.sh and kids.sh (POSIX sh, sourced). Kept free of side
# effects so tests/unit.sh can exercise them without a router.

# Every setting setup.sh stores in private/config.env, in file order.
CONFIG_KEYS='WIFI_SSID WIFI_KEY WIFI_ENCRYPTION WIFI_COUNTRY ROOT_PASSWORD_HASH SSH_KEY SSH_PUBKEYS
SSH_KEY_OLD SSH_PUBKEYS_OLD
TZ_NAME TZ_POSIX WAN_PROTO PPPOE_USER PPPOE_PASS LINK_TYPE SQM_FALLBACK_DOWN SQM_FALLBACK_UP
FAMILY_FILTER ADBLOCK_EXTRA_LISTS BANIP_FEEDS REDLIB_ALLOW
ENABLE_VPN VPN_IFACE WG_PRIVATE_KEY WG_ADDRESSES WG_DNS WG_PEER_PUBLIC_KEY WG_PRESHARED_KEY
WG_ENDPOINT_HOST WG_ENDPOINT_PORT WG_ALLOWED_IPS WG_KEEPALIVE VPN_ROUTE_DOMAINS VPN_ROUTE_SUBNETS
ENABLE_MANGADEX ULA_PREFIX
ENABLE_REMOTE REMOTE_HOST REMOTE_PORT REMOTE_NET REMOTE_SERVER_KEY REMOTE_PEERS'

# Link types from https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm
# (Link Layer Adaptation table): id|description|linklayer|overhead|mpu
LINK_TYPES='vdsl-pppoe|VDSL2 with PPPoE|ethernet|34|68
vdsl|VDSL2 without PPPoE|ethernet|26|68
vdsl-100|VDSL2 behind a 100 Mbit/s Ethernet modem|ethernet|42|84
adsl|ADSL or other ATM-based DSL|atm|44|96
docsis|Cable (DOCSIS), plan under 760 Mbit/s|ethernet|22|64
docsis-fast|Cable (DOCSIS), plan 760 Mbit/s or more|ethernet|42|84
fiber|Fibre (FTTH/GPON)|ethernet|44|84
ethernet|Ethernet to the provider (e.g. apartment LAN)|ethernet|44|84
unsure|Not sure|ethernet|44|96'

# link_params ID -> "linklayer overhead mpu"; fails for an unknown id
link_params() {
	printf '%s\n' "$LINK_TYPES" | awk -F'|' -v id="$1" '$1 == id { print $3, $4, $5; f = 1 } END { exit !f }'
}

# Block lists and banIP feeds that belong to family filtering.
# shellcheck disable=SC2034  # used by setup.sh
FAMILY_LISTS='hagezi:nsfw hagezi:nosafesearch hagezi:doh-vpn-proxy-bypass'
# shellcheck disable=SC2034  # used by setup.sh
FAMILY_FEEDS='doh vpn'

# adblock-lean picks its base lists itself from the router's memory (its
# presets); ADBLOCK_EXTRA_LISTS only holds what comes on top of them.
PRESET_LISTS='hagezi:pro.mini hagezi:pro hagezi:tif.mini hagezi:tif'

# migrate_adblock_lists: older settings kept the full list, base lists included,
# in ADBLOCK_LISTS; keep only the additions. Status 0 if something changed.
migrate_adblock_lists() {
	[ -n "${ADBLOCK_LISTS+x}" ] || return 1
	[ -n "${ADBLOCK_EXTRA_LISTS+x}" ] || ADBLOCK_EXTRA_LISTS=$(words_without "$ADBLOCK_LISTS" "$PRESET_LISTS")
	unset ADBLOCK_LISTS
}

# words_with LIST ADD -> LIST plus the words of ADD it lacks (order kept)
words_with() {
	out=$1
	for w in $2; do case " $out " in *" $w "*) ;; *) out="${out:+$out }$w" ;; esac; done
	printf '%s\n' "$out"
}

# words_without LIST REMOVE -> LIST minus the words of REMOVE
words_without() {
	out=
	for w in $1; do case " $2 " in *" $w "*) ;; *) out="${out:+$out }$w" ;; esac; done
	printf '%s\n' "$out"
}

# find_openssl -> an openssl that can make SHA-256 crypt hashes (passwd -5).
# macOS ships LibreSSL without -5; Homebrew's OpenSSL is keg-only.
find_openssl() {
	for o in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
		command -v "$o" >/dev/null 2>&1 || continue
		h=$(printf x | "$o" passwd -5 -stdin 2>/dev/null) || continue
		case $h in '$5$'*) printf '%s\n' "$o"; return 0 ;; esac
	done
	return 1
}

# bytes VALUE -> length in bytes (not characters: Wi-Fi limits are in bytes)
bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }

# country_for_tz ZONE -> ISO country code from the zone database, if known
country_for_tz() {
	awk -F'\t' -v z="$1" '$3 == z { print $1; exit }' "${ZONEINFO:-/usr/share/zoneinfo}/zone.tab" 2>/dev/null
}

# Interface names the VPN must never take (they would replace core interfaces
# or the remote-access interface).
RESERVED_IFACES='lan wan wan6 wan_6 loopback remote'

# check_settings -> complaints about required settings, one per line (empty = fine)
check_settings() {
	_b=$(bytes "${WIFI_SSID-}"); [ "$_b" -ge 1 ] && [ "$_b" -le 32 ] || echo "WIFI_SSID must be 1-32 bytes"
	_b=$(bytes "${WIFI_KEY-}"); [ "$_b" -ge 8 ] && [ "$_b" -le 63 ] || echo "WIFI_KEY must be 8-63 bytes"
	case ${WIFI_COUNTRY-} in [A-Z][A-Z]) ;; *) echo "WIFI_COUNTRY must be a two-letter country code (e.g. DE)" ;; esac
	case ${ROOT_PASSWORD_HASH-} in '$5$'*|'$6$'*|'$1$'*) ;; *) echo "ROOT_PASSWORD_HASH is not a crypt hash" ;; esac
	[ -n "${SSH_KEY-}" ] || echo "SSH_KEY is empty"
	[ -n "${SSH_PUBKEYS-}" ] || echo "SSH_PUBKEYS is empty"
	[ -n "${TZ_POSIX-}" ] || echo "TZ_POSIX is empty"
	link_params "${LINK_TYPE-}" >/dev/null || echo "LINK_TYPE '${LINK_TYPE-}' is not one of: $(printf '%s\n' "$LINK_TYPES" | cut -d'|' -f1 | tr '\n' ' ')"
	if [ "${WAN_PROTO-}" = pppoe ]; then [ -n "${PPPOE_USER-}" ] || echo "PPPOE_USER is empty"; fi
	for h in ${REDLIB_ALLOW-}; do
		case $h in *[!A-Za-z0-9.-]*) echo "REDLIB_ALLOW entry '$h' is not a host name" ;; esac
	done
	if [ "${ENABLE_VPN-}" = 1 ]; then
		for k in WG_PRIVATE_KEY WG_PEER_PUBLIC_KEY WG_ENDPOINT_HOST WG_ENDPOINT_PORT; do
			eval "[ -n \"\${$k-}\" ]" || echo "$k is empty (VPN is on)"
		done
		case ${VPN_IFACE:-vpn} in *[!a-z0-9_]*|[!a-z]*) echo "VPN_IFACE must start with a letter and use lowercase letters, digits or _" ;; esac
		case " $RESERVED_IFACES " in *" ${VPN_IFACE:-vpn} "*) echo "VPN_IFACE '${VPN_IFACE-}' is reserved for the router's own interfaces" ;; esac
		case ${WG_ENDPOINT_PORT-} in ''|*[!0-9]*) echo "WG_ENDPOINT_PORT must be a number" ;; *)
			[ "$WG_ENDPOINT_PORT" -ge 1 ] && [ "$WG_ENDPOINT_PORT" -le 65535 ] || echo "WG_ENDPOINT_PORT must be 1-65535" ;; esac
		case ${WG_ENDPOINT_HOST-} in *[!A-Za-z0-9.:-]*) echo "WG_ENDPOINT_HOST is not a host name or address" ;; esac
		for h in ${VPN_ROUTE_DOMAINS-}; do
			case $h in *[!A-Za-z0-9.-]*) echo "VPN_ROUTE_DOMAINS entry '$h' is not a domain" ;; esac
		done
		case ${VPN_ROUTE_SUBNETS-} in *[!0-9A-Fa-f:./\ ]*) echo "VPN_ROUTE_SUBNETS must be IP ranges like 91.108.4.0/22" ;; esac
	fi
	for k in SQM_FALLBACK_DOWN SQM_FALLBACK_UP; do
		_v=''; eval "_v=\${$k-}"; case $_v in *[!0-9]*) echo "$k must be a number (kbit/s)" ;; esac
	done
	case ${ULA_PREFIX-} in *[!0-9A-Fa-f:/]*) echo "ULA_PREFIX must look like fdxx:xxxx:xxxx::/48" ;; esac
	case ${BANIP_FEEDS-} in *[!a-z0-9_\ -]*) echo "BANIP_FEEDS has unexpected characters" ;; esac
	case ${ADBLOCK_EXTRA_LISTS-} in *[!A-Za-z0-9:._/\ -]*) echo "ADBLOCK_EXTRA_LISTS has unexpected characters" ;; esac
	if [ "${ENABLE_REMOTE-}" = 1 ]; then
		case ${REMOTE_HOST-} in
			*:*) case $REMOTE_HOST in *[!0-9A-Fa-f:]*) echo "REMOTE_HOST is not a host name or address (no port: that is REMOTE_PORT)" ;; esac ;;
			*[!A-Za-z0-9.-]*) echo "REMOTE_HOST is not a host name or address" ;;
		esac
		case ${REMOTE_PORT-} in ''|*[!0-9]*) echo "REMOTE_PORT must be a number" ;; *)
			[ "$REMOTE_PORT" -ge 1 ] && [ "$REMOTE_PORT" -le 65535 ] || echo "REMOTE_PORT must be 1-65535" ;; esac
		remote_net_ok "${REMOTE_NET-}" || echo "REMOTE_NET must be a private x.y.z.0/24 range, e.g. 10.77.0.0/24"
		is_wg_key "${REMOTE_SERVER_KEY-}" || echo "REMOTE_SERVER_KEY is not a WireGuard key"
		[ -n "${REMOTE_PEERS-}" ] || echo "REMOTE_PEERS is empty (remote access is on)"
		printf '%s\n' "${REMOTE_PEERS-}" | awk -F'|' 'NF {
			if (NF != 4 || $1 !~ /^[A-Za-z0-9_-]+$/ || length($1) > 15 || $2 !~ /^[0-9]+$/ || $2 < 2 || $2 > 254 || length($3) != 44 || length($4) != 44 || ($3 $4) !~ /^[A-Za-z0-9+\/=]+$/ || seen[$1]++ || used[$2]++)
				print "REMOTE_PEERS line " NR " is not name (letters, digits, _ or -, up to 15)|2-254|private key|preshared key, or repeats a name or number"
		}'
	fi
	return 0
}

# --- remote access (WireGuard server on the router) ---------------------------
# Keys are made here with OpenSSL (X25519 is WireGuard's key type), so neither
# this computer nor the router needs WireGuard's own tools for it.

# is_wg_key VALUE -> status 0 for a base64 32-byte key
is_wg_key() {
	case $1 in *[!A-Za-z0-9+/=]*) return 1 ;; esac
	[ ${#1} -eq 44 ] && [ "${1#"${1%?}"}" = = ]
}

# wg_genkey -> a new private key
wg_genkey() {
	"${OPENSSL:-openssl}" genpkey -algorithm X25519 -outform DER | tail -c 32 | "${OPENSSL:-openssl}" base64 -A; echo
}

# wg_psk -> a new preshared key
wg_psk() { "${OPENSSL:-openssl}" rand -base64 32; }

# wg_pubkey PRIVATE -> its public key (the private key wrapped in the PKCS#8
# header for X25519, then OpenSSL derives the public half); fails if OpenSSL
# can't (e.g. macOS LibreSSL without X25519)
wg_pubkey() {
	_k=$({ printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040'; printf '%s' "$1" | "${OPENSSL:-openssl}" base64 -d -A; } \
		| "${OPENSSL:-openssl}" pkey -inform DER -pubout -outform DER | tail -c 32 | "${OPENSSL:-openssl}" base64 -A)
	is_wg_key "$_k" && printf '%s\n' "$_k"
}

# remote_peers_public -> REMOTE_PEERS with each device's public key in place of
# its private key: what the router needs (private keys stay on this computer)
remote_peers_public() {
	printf '%s\n' "${REMOTE_PEERS-}" | while IFS='|' read -r _n _i _k _p; do
		[ -n "$_n" ] || continue
		_pub=$(wg_pubkey "$_k") || exit 1
		printf '%s|%s|%s|%s\n' "$_n" "$_i" "$_pub" "$_p"
	done
}

# remote_net_ok NET -> status 0 for a private x.y.z.0/24 range
remote_net_ok() {
	printf '%s\n' "$1" | awk -F'[./]' 'NF == 5 && $4 == "0" && $5 == "24" && ($1 "." $2 "." $3) ~ /^([1-9][0-9]*|0)\.([1-9][0-9]*|0)\.([1-9][0-9]*|0)$/ && $2 < 256 && $3 < 256 \
		&& ($1 == 10 || ($1 == 172 && $2 >= 16 && $2 < 32) || ($1 == 192 && $2 == 168)) { ok = 1 } END { exit !ok }'
}

# remote_devices -> the device names in REMOTE_PEERS, space separated
remote_devices() {
	printf '%s\n' "${REMOTE_PEERS-}" | awk -F'|' 'NF { printf "%s%s", sep, $1; sep = " " } END { print "" }'
}

# remote_peers_for NAMES -> REMOTE_PEERS for exactly NAMES: known devices keep
# their keys and address, new ones get new keys and the lowest free address.
remote_peers_for() {
	set -f   # a * typed in the list is a name, not a file pattern
	_keep=$(printf '%s\n' "${REMOTE_PEERS-}" | awk -F'|' -v names=" $1 " 'NF && index(names, " " $1 " ") && !seen[$1]++')
	_out=$_keep
	for _d in $1; do
		printf '%s\n' "$_out" | cut -d'|' -f1 | grep -qxF "$_d" && continue
		_n=$(printf '%s\n' "$_out" | awk -F'|' 'NF { used[$2] = 1 } END { for (i = 2; i <= 254; i++) if (!used[i]) { print i; exit } }')
		[ -n "$_n" ] || { set +f; return 1; }
		_out="${_out:+$_out
}$_d|$_n|$(wg_genkey)|$(wg_psk)"
	done
	set +f
	printf '%s\n' "$_out"
}

# remote_client_conf NAME LAN_NET ENDPOINT -> wg-quick config for that device:
# only the tunnel and the home network go through it, DNS is the router's.
remote_client_conf() {
	_l=$(printf '%s\n' "$REMOTE_PEERS" | awk -F'|' -v n="$1" '$1 == n' | head -1)
	[ -n "$_l" ] || return 1
	_pub=$(wg_pubkey "$REMOTE_SERVER_KEY") || return 1
	_p=${REMOTE_NET%.0/24}
	_e=$3; case $_e in *:*) _e="[$_e]" ;; esac
	cat <<-EOF
		# $1: remote access to the home network (openwrt-oneclick)
		[Interface]
		PrivateKey = $(printf '%s' "$_l" | cut -d'|' -f3)
		Address = $_p.$(printf '%s' "$_l" | cut -d'|' -f2)/32
		DNS = $_p.1

		[Peer]
		PublicKey = $_pub
		PresharedKey = $(printf '%s' "$_l" | cut -d'|' -f4)
		AllowedIPs = $REMOTE_NET, $2
		Endpoint = $_e:$REMOTE_PORT
		PersistentKeepalive = 25
	EOF
}

# behind_nat_v4 ADDRESS -> status 0 if it is a private or carrier-grade NAT address
behind_nat_v4() {
	printf '%s\n' "$1" | awk -F. '($1 == 10) || ($1 == 172 && $2 >= 16 && $2 < 32) || ($1 == 192 && $2 == 168) \
		|| ($1 == 100 && $2 >= 64 && $2 < 128) { f = 1 } END { exit !f }'
}

# shq VALUE -> VALUE single-quoted for sh (safe for any content)
shq() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# write_config FILE: writes every CONFIG_KEYS variable that is set, mode 600
write_config() {
	(
		umask 077
		{
			echo "# Private router settings for setup.sh. Never commit or share this file."
			for k in $CONFIG_KEYS; do
				isset='' v=''; eval "isset=\${$k+x} v=\${$k-}"
				if [ -n "$isset" ]; then printf '%s=%s\n' "$k" "$(shq "$v")"; fi
			done
		} > "$1.tmp" && mv "$1.tmp" "$1"
	)
}

# posix_tz ZONE -> POSIX TZ string from the zoneinfo footer (e.g. "<+03>-3")
posix_tz() {
	case $1 in ''|/*|*..*) return 1 ;; esac
	f=${ZONEINFO:-/usr/share/zoneinfo}/$1
	[ -f "$f" ] || return 1
	tail -n 1 "$f" | grep -E '^[A-Za-z<]' || return 1
}

# laptop_tz -> the laptop's zone name (e.g. Asia/Baghdad)
laptop_tz() {
	z=$(timedatectl show -p Timezone --value 2>/dev/null)
	[ -n "$z" ] || z=$(readlink /etc/localtime 2>/dev/null | sed -n 's|.*zoneinfo/||p')
	printf '%s\n' "${z:-UTC}"
}

# parse_wg_conf FILE -> sh assignments for the WG_* settings of a wg-quick
# config (as downloaded from Proton VPN and most other providers).
parse_wg_conf() {
	awk -F '=' '
		function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
		function val() { v = $0; sub(/^[^=]*=/, "", v); sub(/[ \t]+#.*$/, "", v); return trim(v) }
		function add(k, v) { gsub(/[ \t]*,[ \t]*/, " ", v); out[k] = (out[k] == "" ? v : out[k] " " v) }
		/^[ \t]*\[Interface\]/ { sec = "i"; next }
		/^[ \t]*\[Peer\]/      { sec = "p"; peers++; next }
		/^[ \t]*(#|$)/         { next }
		{
			k = tolower(trim($1))
			if (sec == "i" && k == "privatekey") out["WG_PRIVATE_KEY"] = val()
			if (sec == "i" && k == "address") add("WG_ADDRESSES", val())
			if (sec == "i" && k == "dns") add("WG_DNS", val())
			if (sec == "p" && peers == 1) {
				if (k == "publickey") out["WG_PEER_PUBLIC_KEY"] = val()
				if (k == "presharedkey") out["WG_PRESHARED_KEY"] = val()
				if (k == "allowedips") add("WG_ALLOWED_IPS", val())
				if (k == "persistentkeepalive") out["WG_KEEPALIVE"] = val()
				if (k == "endpoint") {
					e = val()
					if (e ~ /^\[/) { h = e; sub(/^\[/, "", h); sub(/\].*/, "", h); p = e; if (p ~ /\]:/) sub(/.*\]:/, "", p); else p = "" }
					else if (e ~ /:/) { h = e; sub(/:[^:]*$/, "", h); p = e; sub(/.*:/, "", p) }
					else { h = e; p = "" }
					out["WG_ENDPOINT_HOST"] = h; out["WG_ENDPOINT_PORT"] = p
				}
			}
		}
		END {
			if (out["WG_PRIVATE_KEY"] == "" || out["WG_PEER_PUBLIC_KEY"] == "" || out["WG_ENDPOINT_HOST"] == "") exit 1
			if (out["WG_ALLOWED_IPS"] == "") out["WG_ALLOWED_IPS"] = "0.0.0.0/0 ::/0"
			if (out["WG_KEEPALIVE"] == "") out["WG_KEEPALIVE"] = "25"
			if (out["WG_ENDPOINT_PORT"] == "") out["WG_ENDPOINT_PORT"] = "51820"
			n = split("WG_PRIVATE_KEY WG_ADDRESSES WG_DNS WG_PEER_PUBLIC_KEY WG_PRESHARED_KEY WG_ENDPOINT_HOST WG_ENDPOINT_PORT WG_ALLOWED_IPS WG_KEEPALIVE", ks, " ")
			for (i = 1; i <= n; i++) { v = out[ks[i]]; gsub(/\047/, "\047\\\047\047", v); printf "%s=\047%s\047\n", ks[i], v }
		}
	' "$1"
}

# --- prompts (read from stdin, so tests can feed answers) -------------------

say() { printf '%s\n' "$*" >&2; }

# ask VAR "Question" [default]
ask() {
	if [ -n "${3-}" ]; then printf '%s [%s]: ' "$2" "$3" >&2; else printf '%s: ' "$2" >&2; fi
	IFS= read -r _a || _a=
	[ -z "$_a" ] && _a=${3-}
	eval "$1=\$_a"
}

# ask_secret VAR "Question" -> asks twice without echo, must match and be non-empty
ask_secret() {
	while :; do
		_t=; [ -t 0 ] && _t=1 && stty -echo
		printf '%s: ' "$2" >&2; IFS= read -r _s1 || _s1=; printf '\n' >&2
		printf 'Again: ' >&2; IFS= read -r _s2 || _s2=; printf '\n' >&2
		[ -n "$_t" ] && stty echo
		[ -n "$_s1" ] && [ "$_s1" = "$_s2" ] && break
		say "  Empty or not the same, try again."
		[ -t 0 ] || return 1
	done
	eval "$1=\$_s1"
}

# yn 1|0 -> y|n (default for ask_yn from a stored 1/0 setting)
yn() { [ "${1-}" = 1 ] && echo y || echo n; }

# ask_yn "Question" y|n -> exit status 0 for yes
ask_yn() {
	while :; do
		_yn=''; ask _yn "$1 (y/n)" "$2"
		case $_yn in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
		[ -t 0 ] || return 1
	done
}

# ask_link_type VAR [default] -> numbered menu over LINK_TYPES
ask_link_type() {
	say "How does your internet reach the house? (sets SQM's per-packet overhead)"
	printf '%s\n' "$LINK_TYPES" | awk -F'|' '{ printf "  %d) %s\n", NR, $2 }' >&2
	n=$(printf '%s\n' "$LINK_TYPES" | wc -l)
	d=; [ -n "${2-}" ] && d=$(printf '%s\n' "$LINK_TYPES" | awk -F'|' -v id="$2" '$1 == id { print NR }')
	while :; do
		ask _n "Number" "$d"
		case $_n in *[!0-9]*|'') ;; *)
			if [ "$_n" -ge 1 ] && [ "$_n" -le "$n" ]; then
				eval "$1=\$(printf '%s\n' \"\$LINK_TYPES\" | sed -n \"\${_n}p\" | cut -d'|' -f1)"
				return 0
			fi ;;
		esac
		say "  Pick 1-$n."
		[ -t 0 ] || return 1
	done
}
