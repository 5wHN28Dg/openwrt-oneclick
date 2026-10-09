# Helpers for setup.sh and kids.sh (POSIX sh, sourced). Kept free of side
# effects so tests/unit.sh can exercise them without a router.

# Every setting setup.sh stores in private/config.env, in file order.
CONFIG_KEYS='WIFI_SSID WIFI_KEY WIFI_ENCRYPTION ROOT_PASSWORD_HASH SSH_KEY SSH_PUBKEYS
TZ_NAME TZ_POSIX WAN_PROTO PPPOE_USER PPPOE_PASS LINK_TYPE SQM_FALLBACK_DOWN SQM_FALLBACK_UP
FAMILY_FILTER ADBLOCK_LISTS BANIP_FEEDS REDLIB_ALLOW
ENABLE_VPN VPN_IFACE WG_PRIVATE_KEY WG_ADDRESSES WG_DNS WG_PEER_PUBLIC_KEY WG_PRESHARED_KEY
WG_ENDPOINT_HOST WG_ENDPOINT_PORT WG_ALLOWED_IPS WG_KEEPALIVE VPN_ROUTE_DOMAINS VPN_ROUTE_SUBNETS
ENABLE_MANGADEX ULA_PREFIX'

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
				eval "isset=\${$k+x} v=\${$k-}"
				if [ -n "$isset" ]; then printf '%s=%s\n' "$k" "$(shq "$v")"; fi
			done
		} > "$1.tmp" && mv "$1.tmp" "$1"
	)
}

# posix_tz ZONE -> POSIX TZ string from the zoneinfo footer (e.g. "<+03>-3")
posix_tz() {
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
		function val() { v = $0; sub(/^[^=]*=/, "", v); return trim(v) }
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
					if (e ~ /^\[/) { h = e; sub(/^\[/, "", h); sub(/\].*/, "", h); p = e; sub(/.*\]:/, "", p) }
					else { h = e; sub(/:[^:]*$/, "", h); p = e; sub(/.*:/, "", p) }
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
		ask _yn "$1 (y/n)" "$2"
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
