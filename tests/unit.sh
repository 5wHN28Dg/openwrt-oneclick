#!/bin/sh
# Laptop-side tests: helpers in lib/laptop.sh and the setup.sh wizard.
# No router needed. Usage: tests/unit.sh

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/lib/laptop.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0 n=0
ok()   { n=$((n + 1)); printf 'ok    %s\n' "$1"; }
bad()  { n=$((n + 1)); fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2], want [$3]"; fi; }

# --- link types (values from the OpenWrt SQM wiki table) ---------------------
eq "link vdsl-pppoe"  "$(link_params vdsl-pppoe)"  "ethernet 34 68"
eq "link vdsl"        "$(link_params vdsl)"        "ethernet 26 68"
eq "link vdsl-100"    "$(link_params vdsl-100)"    "ethernet 42 84"
eq "link adsl"        "$(link_params adsl)"        "atm 44 96"
eq "link docsis"      "$(link_params docsis)"      "ethernet 22 64"
eq "link docsis-fast" "$(link_params docsis-fast)" "ethernet 42 84"
eq "link fiber"       "$(link_params fiber)"       "ethernet 44 84"
eq "link ethernet"    "$(link_params ethernet)"    "ethernet 44 84"
eq "link unsure"      "$(link_params unsure)"      "ethernet 44 96"
if link_params bogus >/dev/null; then bad "unknown link type rejected"; else ok "unknown link type rejected"; fi

# --- quoting and the settings file -------------------------------------------
nasty="it's \"q\" \$HOME \`id\` back\\slash
second line"
eq "shq round trip" "$(eval "printf '%s' $(shq "$nasty")")" "$nasty"
(
	WIFI_SSID="Café 'home'" WIFI_KEY="$nasty" ROOT_PASSWORD_HASH='$5$abc$def/ghi.'
	unset LINK_TYPE
	write_config "$T/c.env"
)
eq "config file mode 600" "$(stat -c %a "$T/c.env")" 600
( . "$T/c.env"; printf '%s' "$WIFI_KEY" ) > "$T/key"
eq "config round trip: Wi-Fi key" "$(cat "$T/key")" "$nasty"
eq "config round trip: SSID"      "$(. "$T/c.env"; printf '%s' "$WIFI_SSID")" "Café 'home'"
eq "config round trip: hash"      "$(. "$T/c.env"; printf '%s' "$ROOT_PASSWORD_HASH")" '$5$abc$def/ghi.'
if grep -q '^LINK_TYPE=' "$T/c.env"; then bad "unset keys not written"; else ok "unset keys not written"; fi

# --- time zones ----------------------------------------------------------------
eq "posix tz Asia/Baghdad" "$(posix_tz Asia/Baghdad)" "<+03>-3"
eq "posix tz Europe/Berlin" "$(posix_tz Europe/Berlin)" "CET-1CEST,M3.5.0,M10.5.0/3"
if posix_tz Not/AZone >/dev/null 2>&1; then bad "unknown zone rejected"; else ok "unknown zone rejected"; fi

# --- WireGuard config parsing ----------------------------------------------------
cat > "$T/proton.conf" <<'EOF'
[Interface]
# Key for test
PrivateKey = cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MDA=
Address = 10.2.0.2/32, 2a07:b944::2:2/128
DNS = 10.2.0.1

[Peer]
# NL-FREE#1
PublicKey = cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5cHViMDA=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 198.51.100.7:51820
EOF
eval "$(parse_wg_conf "$T/proton.conf")"
eq "wg private key" "$WG_PRIVATE_KEY" "cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MDA="
eq "wg addresses"   "$WG_ADDRESSES" "10.2.0.2/32 2a07:b944::2:2/128"
eq "wg dns"         "$WG_DNS" "10.2.0.1"
eq "wg peer key"    "$WG_PEER_PUBLIC_KEY" "cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5cHViMDA="
eq "wg endpoint"    "$WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT" "198.51.100.7:51820"
eq "wg allowed ips" "$WG_ALLOWED_IPS" "0.0.0.0/0 ::/0"
eq "wg keepalive default" "$WG_KEEPALIVE" "25"
printf '[Interface]\nPrivateKey=a\n[Peer]\nPublicKey=b\nPresharedKey=c\nEndpoint=[2001:db8::1]:443\nPersistentKeepalive=15\n' > "$T/v6.conf"
eval "$(parse_wg_conf "$T/v6.conf")"
eq "wg IPv6 endpoint" "$WG_ENDPOINT_HOST|$WG_ENDPOINT_PORT" "2001:db8::1|443"
eq "wg preshared key" "$WG_PRESHARED_KEY" "c"
eq "wg keepalive" "$WG_KEEPALIVE" "15"
printf '[Interface]\nAddress=10.0.0.2/32\n' > "$T/broken.conf"
if parse_wg_conf "$T/broken.conf" >/dev/null; then bad "incomplete wg config rejected"; else ok "incomplete wg config rejected"; fi

# --- wizard (setup.sh --settings-only), answers fed on stdin ---------------------
export HOME="$T/home"; mkdir -p "$HOME/.ssh"
P1=$T/priv1
# Wi-Fi name, Wi-Fi password x2, admin password x2, SSH key path, create key?,
# time zone, PPPoE?, PPPoE user, PPPoE password x2, link type number,
# family filtering?, Redlib allow, VPN?, wg path, VPN iface, domains, subnets,
# MangaDex?, create settings? (first) / save? (last)
printf '%s\n' y "Home Net" "pa'ss word1" "pa'ss word1" adminpw adminpw "$HOME/.ssh/test_key" y \
	Europe/Berlin "" y "user@isp" ppppass ppppass 7 y "safereddit.com" y "$T/proton.conf" protonvpn \
	"archive.org newegg.com" "91.108.4.0/22" y y \
	| ONECLICK_PRIVATE=$P1 "$HERE/setup.sh" --settings-only >"$T/w1.out" 2>&1
eq "wizard (all on) exit" "$?" 0
eq "settings file created" "$(test -f "$P1/config.env" && stat -c %a "$P1/config.env")" 600
(
	. "$P1/config.env"
	eq "w1 ssid" "$WIFI_SSID" "Home Net"
	eq "w1 wifi key" "$WIFI_KEY" "pa'ss word1"
	case $ROOT_PASSWORD_HASH in '$5$'*) ok "w1 root hash is sha256-crypt" ;; *) bad "w1 root hash: $ROOT_PASSWORD_HASH" ;; esac
	eq "w1 hash verifies" "$(openssl passwd -5 -salt "$(echo "$ROOT_PASSWORD_HASH" | cut -d'$' -f3)" adminpw)" "$ROOT_PASSWORD_HASH"
	eq "w1 ssh key created" "$(test -f "$SSH_KEY" && test -f "$SSH_KEY.pub" && echo yes)" yes
	eq "w1 pubkey stored" "$SSH_PUBKEYS" "$(cat "$SSH_KEY.pub")"
	eq "w1 tz" "$TZ_NAME|$TZ_POSIX" "Europe/Berlin|CET-1CEST,M3.5.0,M10.5.0/3"
	eq "w1 Wi-Fi country from time zone" "$WIFI_COUNTRY" DE
	eq "w1 pppoe" "$WAN_PROTO|$PPPOE_USER|$PPPOE_PASS" "pppoe|user@isp|ppppass"
	eq "w1 link type" "$LINK_TYPE" fiber
	eq "w1 family" "$FAMILY_FILTER" 1
	eq "w1 lists" "$ADBLOCK_LISTS" "hagezi:pro hagezi:tif.mini hagezi:nsfw hagezi:nosafesearch hagezi:doh-vpn-proxy-bypass"
	eq "w1 redlib allow" "$REDLIB_ALLOW" "safereddit.com"
	eq "w1 vpn" "$ENABLE_VPN|$VPN_IFACE|$WG_ENDPOINT_HOST" "1|protonvpn|198.51.100.7"
	eq "w1 vpn routes" "$VPN_ROUTE_DOMAINS|$VPN_ROUTE_SUBNETS" "archive.org newegg.com|91.108.4.0/22"
	eq "w1 mangadex" "$ENABLE_MANGADEX" 1
) | tee "$T/w1.res"
fails=$((fails + $(grep -c '^FAIL' "$T/w1.res"))); n=$((n + $(wc -l < "$T/w1.res")))

P2=$T/priv2
# Everything optional off; existing key; save.
printf '%s\n' y "Flat" "longenough" "longenough" pw pw "$HOME/.ssh/test_key" \
	UTC us n 9 n n n y \
	| ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/w2.out" 2>&1
eq "wizard (all off) exit" "$?" 0
(
	. "$P2/config.env"
	eq "w2 dhcp" "$WAN_PROTO" dhcp
	eq "w2 country upper-cased" "$WIFI_COUNTRY" US
	eq "w2 link unsure" "$LINK_TYPE" unsure
	eq "w2 family off" "$FAMILY_FILTER|$ADBLOCK_LISTS|$BANIP_FEEDS|$REDLIB_ALLOW" "0|hagezi:pro hagezi:tif.mini||"
	eq "w2 vpn off" "$ENABLE_VPN" 0
	eq "w2 mangadex off" "$ENABLE_MANGADEX" 0
) | tee "$T/w2.res"
fails=$((fails + $(grep -c '^FAIL' "$T/w2.res"))); n=$((n + $(wc -l < "$T/w2.res")))

# Declining to save keeps nothing on disk.
P3=$T/priv3
printf '%s\n' y "X" "longenough" "longenough" pw pw "$HOME/.ssh/test_key" UTC US n 9 n n n n \
	| ONECLICK_PRIVATE=$P3 "$HERE/setup.sh" --settings-only >"$T/w3.out" 2>&1
eq "decline save: exit" "$?" 0
eq "decline save: nothing written" "$(ls -A "$P3" 2>/dev/null)" ""

# A settings file without LINK_TYPE asks for it and saves it.
grep -v '^LINK_TYPE=' "$P2/config.env" > "$T/nolink" && mv "$T/nolink" "$P2/config.env"
# (it then tries to reach a router; the timeout ends that, the save happened before)
printf '%s\n' 4 | ONECLICK_PRIVATE=$P2 timeout 5 "$HERE/setup.sh" 127.0.0.1 1 >"$T/w4.out" 2>&1 || true
eq "missing link type asked and saved" "$(. "$P2/config.env"; echo "$LINK_TYPE")" adsl

# --- family filtering toggled later (review finding 1) ---------------------------
. "$P2/config.env"   # family off, lists "hagezi:pro hagezi:tif.mini"
ADBLOCK_LISTS="hagezi:pro hagezi:tif.mini oisd:big" BANIP_FEEDS="tiktok"
write_config "$P2/config.env"
# reconfigure: keep Wi-Fi, keep admin pw, key path, tz, pppoe n, link (keep), family y, redlib, vpn n, mangadex n
printf '%s\n' "" n n "" "" "" n "" y "" n n | ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/w5.out" 2>&1
eq "family on later: exit" "$?" 0
eq "family on later: lists" "$(. "$P2/config.env"; echo "$ADBLOCK_LISTS")" "hagezi:pro hagezi:tif.mini oisd:big hagezi:nsfw hagezi:nosafesearch hagezi:doh-vpn-proxy-bypass"
eq "family on later: feeds" "$(. "$P2/config.env"; echo "$BANIP_FEEDS")" "tiktok doh vpn"
printf '%s\n' "" n n "" "" "" n "" n n n | ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/w6.out" 2>&1
eq "family off later: lists" "$(. "$P2/config.env"; echo "$ADBLOCK_LISTS")" "hagezi:pro hagezi:tif.mini oisd:big"
eq "family off later: feeds" "$(. "$P2/config.env"; echo "$BANIP_FEEDS")" "tiktok"

# --- OpenSSL without passwd -5, e.g. macOS LibreSSL (finding 3) -------------------
mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "unknown option -5" >&2; exit 1\n' > "$T/fakebin/openssl"; chmod 755 "$T/fakebin/openssl"
if PATH="$T/fakebin:/usr/bin:/bin" sh -c '. "$1/lib/laptop.sh"; [ "$(command -v openssl)" = "$2/fakebin/openssl" ] && ! find_openssl' _ "$HERE" "$T"; then
	ok "openssl without -5 is not used"; else bad "openssl without -5 is not used"; fi
eq "real openssl found" "$(find_openssl)" openssl

# --- Ctrl-C at a prompt stops the wizard (finding 4) -------------------------------
mkfifo "$T/in"
ONECLICK_PRIVATE=$T/priv-int "$HERE/setup.sh" --settings-only <"$T/in" >"$T/int.out" 2>&1 &
# (a background job ignores SIGINT in a non-interactive shell; TERM uses the same trap)
pid=$!; exec 9>"$T/in"; sleep 1; kill -TERM $pid; wait $pid; rc=$?; exec 9>&-
eq "interrupt exits 130" "$rc" 130
eq "interrupt saves nothing" "$(ls -A "$T/priv-int" 2>/dev/null)" ""

# --- settings validation (finding 12, 10) --------------------------------------------
(
	. "$P1/config.env"
	WIFI_KEY=short; eq "short Wi-Fi key rejected" "$(check_settings | grep -c WIFI_KEY)" 1
	WIFI_KEY=longenough REDLIB_ALLOW='ok.example $(reboot)'; eq "unsafe Redlib entry rejected" "$(check_settings | grep -c REDLIB_ALLOW)" 1
	REDLIB_ALLOW=ok.example; eq "valid settings pass" "$(check_settings)" ""
) | tee "$T/v.res"
fails=$((fails + $(grep -c '^FAIL' "$T/v.res"))); n=$((n + $(wc -l < "$T/v.res")))
printf '%s\n' y "X" "short" "short" pw pw "$HOME/.ssh/test_key" UTC US n 9 n n n y \
	| ONECLICK_PRIVATE=$T/priv-short "$HERE/setup.sh" --settings-only >"$T/short.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q "WIFI_KEY must be" "$T/short.out" && [ -z "$(ls -A "$T/priv-short" 2>/dev/null)" ]; then ok "wizard refuses a short Wi-Fi key, saves nothing"; else bad "wizard refuses a short Wi-Fi key (rc $rc)"; fi

# --- second review: limits in bytes, names, parser, paths -------------------------
(
	. "$P1/config.env"
	WIFI_KEY=$(printf 'ä%.0s' $(seq 38)); eq "Wi-Fi key over 63 bytes rejected (38 x ä = 76 bytes)" "$(check_settings | grep -c WIFI_KEY)" 1
	WIFI_KEY=longenough WIFI_SSID=$(printf 'x%.0s' $(seq 33)); eq "SSID over 32 bytes rejected" "$(check_settings | grep -c WIFI_SSID)" 1
	WIFI_SSID=ok
	for i in lan wan wan6 loopback; do VPN_IFACE=$i; eq "VPN_IFACE '$i' rejected" "$(check_settings | grep -c VPN_IFACE)" 1; done
	VPN_IFACE=protonvpn WG_ENDPOINT_PORT=notaport; eq "non-numeric WireGuard port rejected" "$(check_settings | grep -c WG_ENDPOINT_PORT)" 1
	WG_ENDPOINT_PORT=51820 WIFI_COUNTRY=Germany; eq "bad country rejected" "$(check_settings | grep -c WIFI_COUNTRY)" 1
	WIFI_COUNTRY=DE SQM_FALLBACK_DOWN="1'0"; eq "non-numeric SQM fallback rejected" "$(check_settings | grep -c SQM_FALLBACK)" 1
) | tee "$T/v2.res"
fails=$((fails + $(grep -c '^FAIL' "$T/v2.res"))); n=$((n + $(wc -l < "$T/v2.res")))
printf '[Interface]\nPrivateKey = abc= # my key\nAddress = 10.0.0.2/32 # home\n[Peer]\nPublicKey = def=\nEndpoint = vpn.example.com\n' > "$T/c.conf"
eval "$(parse_wg_conf "$T/c.conf")"
eq "wg inline comment stripped (key)" "$WG_PRIVATE_KEY" "abc="
eq "wg inline comment stripped (address)" "$WG_ADDRESSES" "10.0.0.2/32"
eq "wg endpoint without port" "$WG_ENDPOINT_HOST|$WG_ENDPOINT_PORT" "vpn.example.com|51820"
if posix_tz ../../../etc/passwd >/dev/null 2>&1; then bad "time zone path outside zoneinfo rejected"; else ok "time zone path outside zoneinfo rejected"; fi
eq "country for Asia/Baghdad" "$(country_for_tz Asia/Baghdad)" IQ

# --- changing the SSH key keeps the old one for the next login --------------------
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/new_key"
printf '%s\n' "" n n "$HOME/.ssh/new_key" "" "" n "" n n n | ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/k.out" 2>&1
(
	. "$P2/config.env"
	eq "new key saved" "$SSH_KEY" "$HOME/.ssh/new_key"
	eq "old key kept for login" "$SSH_KEY_OLD" "$HOME/.ssh/test_key"
	eq "old public key kept for replacement" "$SSH_PUBKEYS_OLD" "$(cat "$HOME/.ssh/test_key.pub")"
) | tee "$T/k.res"
fails=$((fails + $(grep -c '^FAIL' "$T/k.res"))); n=$((n + $(wc -l < "$T/k.res")))

# --- older settings without a Wi-Fi country: asked, then saved ---------------------
grep -v '^WIFI_COUNTRY=' "$P2/config.env" > "$T/noc" && mv "$T/noc" "$P2/config.env"
printf '%s\n' "" | ONECLICK_PRIVATE=$P2 timeout 5 "$HERE/setup.sh" 127.0.0.1 1 >"$T/c.out" 2>&1 || true
eq "missing country asked, default from time zone, saved" "$(. "$P2/config.env"; echo "$WIFI_COUNTRY")" "$(country_for_tz UTC)"

# --- kids.sh refuses lists that would cut off the whole LAN ------------------------
for bad_list in "" "|aa:bb:cc:dd:ee:ff|192.168.1.50" "TV|nonsense|192.168.1.50" "TV|aa:bb:cc:dd:ee:ff|300.1.1"; do
	printf '%s\n' "DEVICES=$(shq "$bad_list")" "CUTOFF_START='21:30:00'" "CUTOFF_STOP='05:30:00'" > "$P2/kids.conf"
	out=$(ONECLICK_PRIVATE=$P2 timeout 10 "$HERE/kids.sh" 127.0.0.1 1 2>&1); rc=$?
	case $out in *"kids.conf"*) [ $rc -eq 1 ] && ok "kids.sh refuses list [$bad_list] before contacting the router" || bad "kids.sh list [$bad_list]: rc $rc" ;;
		*) bad "kids.sh list [$bad_list] not refused: $out" ;; esac
done

echo
echo "$((n - fails))/$n passed"
[ $fails -eq 0 ]
