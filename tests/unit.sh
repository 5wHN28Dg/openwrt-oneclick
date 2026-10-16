#!/bin/sh
# Laptop-side tests: helpers in lib/laptop.sh and the setup.sh wizard.
# No router needed. Usage: tests/unit.sh

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/lib/laptop.sh"
. "$HERE/router/sqm-lib.sh"
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

# --- SQM numbers (router/sqm-lib.sh) --------------------------------------------
eq "median, odd count"  "$(printf '5\n1\n9\n' | median)" 5
eq "median, even count" "$(printf '4\n2\n' | median)" 3
eq "median of nothing is empty" "$(printf '' | median)" ""
# A cable line: 10 s of boost at 200 Mbit/s, then 100 Mbit/s with one dip.
boost=$(awk 'BEGIN { c = 0; for (t = 0; t <= 25; t++) { printf "%d.00 %d\n", 100 + t, c; c += (t < 10 ? 25000000 : (t == 17 ? 2000000 : 12500000)) } }')
eq "sustained rate leaves out the boost and a dip" "$(echo "$boost" | sustained_kbit 10)" 100000
# Where the boost is most of the samples, only the warm-up keeps it out.
eq "boost is most of the test: the warm-up leaves it out" "$(echo "$boost" | head -n 17 | sustained_kbit 10)" 100000
eq "boost is most of the test: counted without a warm-up" "$(echo "$boost" | head -n 17 | sustained_kbit 0)" 200000
eq "sustained rate with uneven sample times" "$(printf '10.00 0\n11.50 1500000\n12.00 2000000\n14.00 4000000\n' | sustained_kbit 0)" 8000
eq "rate between two samples (warm-up -1 counts from the first)" "$(printf '10.00 1000\n17.00 8751000\n' | sustained_kbit -1)" 10000
# Bursts with pauses (5 Mbyte every third second): the median would be 0.
eq "bursty delivery: the average, not a median of pauses" "$(awk 'BEGIN { c = 0; for (t = 0; t <= 12; t++) { printf "%d.00 %d\n", t, c; if (t % 3 == 2) c += 5000000 } }' | sustained_kbit 0)" 13333
eq "no samples after the warm-up: empty" "$(printf '10.00 0\n11.00 5\n' | sustained_kbit 5)" ""
eq "ping median" "$(printf 'PING 1.1.1.1\n64 bytes from 1.1.1.1: seq=0 ttl=55 time=12.345 ms\n64 bytes from 1.1.1.1: seq=1 ttl=55 time=80.1 ms\n64 bytes from 1.1.1.1: seq=2 ttl=55 time=15.0 ms\n3 packets transmitted\n' | rtt_median)" 15
eq "ping without replies: empty" "$(printf 'PING 1.1.1.1\n5 packets transmitted, 0 packets received\n' | rtt_median)" ""
eq "ping replies counted" "$(printf 'PING 1.1.1.1\n64 bytes: seq=0 time=12.3 ms\n64 bytes: seq=4 time=15 ms\n7 packets transmitted, 2 packets received\n' | rtt_replies)" 2
eq "CPU busy share of one core" "$(busy_percent 'cpu0 100 0 100 800 0 0 0 0' 'cpu0 150 0 150 900 0 0 0 0')" 50
eq "CPU: waiting on I/O is not busy" "$(busy_percent 'cpu0 0 0 0 100 100 0 0 0' 'cpu0 0 0 0 150 150 0 0 0')" 0
# One of four cores does all the network work: that core counts, not the average.
before='cpu0 0 0 0 1000 0 0 0 0
cpu1 0 0 0 1000 0 0 0 0
cpu2 0 0 0 1000 0 0 0 0
cpu3 0 0 0 1000 0 0 0 0'
after='cpu0 0 0 0 2000 0 0 0 0
cpu1 0 0 50 1050 0 0 900 0
cpu2 0 0 0 2000 0 0 0 0
cpu3 100 0 0 1900 0 0 0 0'
eq "CPU: the busiest core counts" "$(busy_percent "$before" "$after")" 95

# A server that refuses (HTTP 429): the installer's load() backs off and gives
# up, instead of asking thousands of times (8 streams x 3 tries = 24 requests).
if command -v python3 >/dev/null && command -v curl >/dev/null; then
	python3 -I "$HERE/tests/speedsrv.py" 18081 1000 1000 refuse > "$T/refused" & spid=$!
	sleep 1
	(
		# shellcheck disable=SC2034  # read by load(), defined through eval below
		SPEED_URL=http://127.0.0.1:18081
		eval "$(sed -n '/^load() {/,/^}/p' "$HERE/router/install.sh")"
		load down 20 > "$T/load.out"
	)
	kill $spid 2>/dev/null; wait $spid 2>/dev/null
	eq "refused speed test: 8 streams give up after 3 tries each" "$(wc -l < "$T/refused" | tr -d ' ')" 24
	eq "refused speed test: HTTP code recorded" "$(cut -d' ' -f2 "$T/load.out" | sort -u)" 429
else
	echo "skip  refused speed test (needs python3 and curl)"
fi

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
# Proton picks the server?, Proton countries, MangaDex?, remote access?, public name, port, devices,
# create settings? (first) / save? (last)
printf '%s\n' y "Home Net" "pa'ss word1" "pa'ss word1" adminpw adminpw "$HOME/.ssh/test_key" y \
	Europe/Berlin "" y "user@isp" ppppass ppppass 7 y "safereddit.com" y "$T/proton.conf" protonvpn \
	"archive.org newegg.com" "91.108.4.0/22" y "pl ch" y y home.example.org "" "phone tablet" y \
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
	eq "w1 extra lists" "$ADBLOCK_EXTRA_LISTS" "hagezi:nsfw hagezi:nosafesearch hagezi:doh-vpn-proxy-bypass"
	eq "w1 redlib allow" "$REDLIB_ALLOW" "safereddit.com"
	eq "w1 vpn" "$ENABLE_VPN|$VPN_IFACE|$WG_ENDPOINT_HOST" "1|protonvpn|198.51.100.7"
	eq "w1 vpn routes" "$VPN_ROUTE_DOMAINS|$VPN_ROUTE_SUBNETS" "archive.org newegg.com|91.108.4.0/22"
	eq "w1 mangadex" "$ENABLE_MANGADEX" 1
	eq "w1 Proton server choice" "$PROTON_AUTO|$PROTON_COUNTRIES" "1|PL CH"
	PROTON_COUNTRIES='PL; reboot'; eq "bad Proton countries rejected" "$(check_settings | grep -c PROTON_COUNTRIES)" 1
	PROTON_COUNTRIES=PL PROTON_API='ftp://x'; eq "bad Proton API rejected" "$(check_settings | grep -c PROTON_API)" 1
	PROTON_API='http://10.0.2.2:1'; eq "plain-http Proton API rejected outside tests" "$(check_settings | grep -c PROTON_API)" 1
	eq "plain-http Proton API allowed in tests" "$(ONECLICK_TEST=1 check_settings | grep -c PROTON_API)" 0
	PROTON_API='' ENABLE_VPN=0; eq "Proton server choice is ignored without the VPN" "$(check_settings | grep -c PROTON)" 0
	eq "w1 remote" "$ENABLE_REMOTE|$REMOTE_HOST|$REMOTE_PORT|$REMOTE_NET" "1|home.example.org|51820|10.77.0.0/24"
	eq "w1 remote devices" "$(remote_devices)" "phone tablet"
	eq "w1 remote addresses" "$(printf '%s\n' "$REMOTE_PEERS" | cut -d'|' -f2 | tr '\n' ' ')" "2 3 "
	is_wg_key "$REMOTE_SERVER_KEY" && ok "w1 remote server key" || bad "w1 remote server key: $REMOTE_SERVER_KEY"
) | tee "$T/w1.res"
fails=$((fails + $(grep -c '^FAIL' "$T/w1.res"))); n=$((n + $(wc -l < "$T/w1.res")))

P2=$T/priv2
# Everything optional off; existing key; save.
printf '%s\n' y "Flat" "longenough" "longenough" pw pw "$HOME/.ssh/test_key" \
	UTC us n 9 n n n n y \
	| ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/w2.out" 2>&1
eq "wizard (all off) exit" "$?" 0
(
	. "$P2/config.env"
	eq "w2 dhcp" "$WAN_PROTO" dhcp
	eq "w2 country upper-cased" "$WIFI_COUNTRY" US
	eq "w2 link unsure" "$LINK_TYPE" unsure
	eq "w2 family off" "$FAMILY_FILTER|$ADBLOCK_EXTRA_LISTS|$BANIP_FEEDS|$REDLIB_ALLOW" "0|||"
	eq "w2 vpn off" "$ENABLE_VPN" 0
	eq "w2 mangadex off" "$ENABLE_MANGADEX" 0
	eq "w2 remote off" "$ENABLE_REMOTE|${REMOTE_PEERS-}" "0|"
) | tee "$T/w2.res"
fails=$((fails + $(grep -c '^FAIL' "$T/w2.res"))); n=$((n + $(wc -l < "$T/w2.res")))

# Declining to save keeps nothing on disk.
P3=$T/priv3
printf '%s\n' y "X" "longenough" "longenough" pw pw "$HOME/.ssh/test_key" UTC US n 9 n n n n n \
	| ONECLICK_PRIVATE=$P3 "$HERE/setup.sh" --settings-only >"$T/w3.out" 2>&1
eq "decline save: exit" "$?" 0
eq "decline save: nothing written" "$(ls -A "$P3" 2>/dev/null)" ""

# A settings file without LINK_TYPE asks for it and saves it.
grep -v '^LINK_TYPE=' "$P2/config.env" > "$T/nolink" && mv "$T/nolink" "$P2/config.env"
# (it then tries to reach a router; the timeout ends that, the save happened before)
printf '%s\n' 4 | ONECLICK_PRIVATE=$P2 timeout 5 "$HERE/setup.sh" 127.0.0.1 1 >"$T/w4.out" 2>&1 || true
eq "missing link type asked and saved" "$(. "$P2/config.env"; echo "$LINK_TYPE")" adsl

# --- family filtering toggled later (review finding 1) ---------------------------
. "$P2/config.env"   # family off, no extra lists
ADBLOCK_EXTRA_LISTS="oisd:big" BANIP_FEEDS="tiktok"
write_config "$P2/config.env"
# reconfigure: keep Wi-Fi, keep admin pw, key path, tz, pppoe n, link (keep), family y, redlib, vpn n, mangadex n, remote n
printf '%s\n' "" n n "" "" "" n "" y "" n n n | ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/w5.out" 2>&1
eq "family on later: exit" "$?" 0
eq "family on later: lists" "$(. "$P2/config.env"; echo "$ADBLOCK_EXTRA_LISTS")" "oisd:big hagezi:nsfw hagezi:nosafesearch hagezi:doh-vpn-proxy-bypass"
eq "family on later: feeds" "$(. "$P2/config.env"; echo "$BANIP_FEEDS")" "tiktok doh vpn"
printf '%s\n' "" n n "" "" "" n "" n n n n | ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/w6.out" 2>&1
eq "family off later: lists" "$(. "$P2/config.env"; echo "$ADBLOCK_EXTRA_LISTS")" "oisd:big"
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
printf '%s\n' y "X" "short" "short" pw pw "$HOME/.ssh/test_key" UTC US n 9 n n n n y \
	| ONECLICK_PRIVATE=$T/priv-short "$HERE/setup.sh" --settings-only >"$T/short.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q "WIFI_KEY must be" "$T/short.out" && [ -z "$(ls -A "$T/priv-short" 2>/dev/null)" ]; then ok "wizard refuses a short Wi-Fi key, saves nothing"; else bad "wizard refuses a short Wi-Fi key (rc $rc)"; fi

# --- second review: limits in bytes, names, parser, paths -------------------------
# shellcheck disable=SC2034  # check_settings reads the settings through eval
(
	. "$P1/config.env"
	WIFI_KEY=$(printf 'ä%.0s' $(seq 38)); eq "Wi-Fi key over 63 bytes rejected (38 x ä = 76 bytes)" "$(check_settings | grep -c WIFI_KEY)" 1
	WIFI_KEY=longenough WIFI_SSID=$(printf 'x%.0s' $(seq 33)); eq "SSID over 32 bytes rejected" "$(check_settings | grep -c WIFI_SSID)" 1
	WIFI_SSID=ok
	for i in lan wan wan6 loopback; do VPN_IFACE=$i; eq "VPN_IFACE '$i' rejected" "$(check_settings | grep -c VPN_IFACE)" 1; done
	VPN_IFACE=protonvpn WG_ENDPOINT_PORT=notaport; eq "non-numeric WireGuard port rejected" "$(check_settings | grep -c WG_ENDPOINT_PORT)" 1
	WG_ENDPOINT_PORT=51820 WIFI_COUNTRY=Germany; eq "bad country rejected" "$(check_settings | grep -c WIFI_COUNTRY)" 1
	WIFI_COUNTRY=DE SQM_FALLBACK_DOWN="1'0"; eq "non-numeric SQM fallback rejected" "$(check_settings | grep -c SQM_FALLBACK)" 1
	SQM_FALLBACK_DOWN=1000 SQM_DOWN=50000 SQM_UP=10000; eq "fixed SQM rates accepted" "$(check_settings)" ""
	SQM_UP=''; eq "fixed SQM rate for one direction only rejected" "$(check_settings | grep -c SQM_DOWN)" 1
	SQM_UP=50; eq "fixed SQM rate that looks like Mbit/s rejected" "$(check_settings | grep -c 'at least 100')" 1
	SQM_UP=99999999999999999999; r=$(check_settings 2>&1); eq "absurdly large fixed SQM rate rejected, no shell error" "$(echo "$r" | grep -c 'SQM_UP must be a number')|$(echo "$r" | grep -ci 'out of range')" "1|0"
	SQM_UP='10000; reboot'; eq "non-numeric fixed SQM rate rejected" "$(check_settings | grep -c 'SQM_UP must be a number')" 1
	SQM_DOWN='' SQM_UP='' SPEEDTEST_URL='http://10.0.2.2:18080'; eq "speed test server accepted" "$(check_settings)" ""
	SPEEDTEST_URL='http://'; eq "speed test server without a host rejected" "$(check_settings | grep -c SPEEDTEST_URL)" 1
	SPEEDTEST_URL='' SQM_FALLBACK_DOWN=0 SQM_FALLBACK_UP=0; eq "fallback rates of 0 rejected" "$(check_settings | grep -c 'at least 100')" 2
	SQM_FALLBACK_DOWN=100000 SQM_FALLBACK_UP=20000
	SPEEDTEST_URL='speed.example'; eq "speed test server without http(s) rejected" "$(check_settings | grep -c SPEEDTEST_URL)" 1
	SPEEDTEST_URL='http://x/$(reboot)'; eq "speed test server with shell characters rejected" "$(check_settings | grep -c SPEEDTEST_URL)" 1
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
printf '%s\n' "" n n "$HOME/.ssh/new_key" "" "" n "" n n n n | ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/k.out" 2>&1
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

# --- adblock-lean lists: older settings keep only their additions ------------------
grep -v '^ADBLOCK_EXTRA_LISTS=' "$P2/config.env" > "$T/old" && mv "$T/old" "$P2/config.env"
echo "ADBLOCK_LISTS='hagezi:pro hagezi:tif.mini oisd:big hagezi:nsfw'" >> "$P2/config.env"
ONECLICK_PRIVATE=$P2 timeout 5 "$HERE/setup.sh" 127.0.0.1 1 >"$T/m.out" 2>&1 || true
eq "old ADBLOCK_LISTS: base lists dropped, additions kept" "$(. "$P2/config.env"; echo "${ADBLOCK_EXTRA_LISTS-unset}|${ADBLOCK_LISTS-gone}")" "oisd:big hagezi:nsfw|gone"

# --- remote access ------------------------------------------------------------------
# Turned on later with a name, then "-" goes back to the router's own address.
printf '%s\n' "" n n "" "" "" n "" n n n y home.example.org "" "tv" | ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/r1.out" 2>&1
eq "remote on later" "$(. "$P2/config.env"; echo "$ENABLE_REMOTE|$REMOTE_HOST|$(remote_devices)")" "1|home.example.org|tv"
printf '%s\n' "" n n "" "" "" n "" n n n y - "" "" | ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only >"$T/r2.out" 2>&1
eq "remote host cleared with -" "$(. "$P2/config.env"; echo "$REMOTE_HOST|$(remote_devices)")" "|tv"
# A * in the device list is a name (then refused), not the files here.
mkdir -p "$T/globdir/afile.d" "$T/globdir/bfile"
printf '%s\n' "" n n "" "" "" n "" n n n y "" "" "tv *" | (cd "$T/globdir" && ONECLICK_PRIVATE=$P2 "$HERE/setup.sh" --settings-only) >"$T/r3.out" 2>&1
case $(. "$P2/config.env"; remote_devices) in *bfile*) bad "device list * expanded to file names" ;; *) ok "device list * not expanded to file names" ;; esac
# RFC 7748 X25519 test vector (Alice): private 77076d0a..., public 8520f009...
eq "WireGuard public key from private (RFC 7748)" "$(wg_pubkey dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=)" "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo="
k=$(wg_genkey); is_wg_key "$k" && is_wg_key "$(wg_pubkey "$k")" && ok "new WireGuard key pair" || bad "new WireGuard key pair: $k"
if is_wg_key 'abc='; then bad "short key rejected"; else ok "short key rejected"; fi
(
	REMOTE_PEERS=
	REMOTE_PEERS=$(remote_peers_for "phone tablet laptop")
	first=$REMOTE_PEERS
	REMOTE_PEERS=$(remote_peers_for "laptop tv")
	eq "devices: removed dropped, new added" "$(remote_devices)" "laptop tv"
	eq "devices: kept device keeps key and address" "$(printf '%s\n' "$REMOTE_PEERS" | grep '^laptop|')" "$(printf '%s\n' "$first" | grep '^laptop|')"
	eq "devices: new device gets lowest free address" "$(printf '%s\n' "$REMOTE_PEERS" | grep '^tv|' | cut -d'|' -f2)" 2
	REMOTE_PEERS=$(remote_peers_for "laptop laptop")
	eq "devices: repeated name counted once" "$(remote_devices)" "laptop"

	REMOTE_NET=10.77.0.0/24 REMOTE_PORT=51820 REMOTE_SERVER_KEY=dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=
	REMOTE_PEERS="phone|5|$(wg_genkey)|$(wg_psk)"
	c=$(remote_client_conf phone 192.168.1.0/24 home.example.org)
	eq "client conf: address" "$(echo "$c" | sed -n 's/^Address = //p')" 10.77.0.5/32
	eq "client conf: router DNS" "$(echo "$c" | sed -n 's/^DNS = //p')" 10.77.0.1
	eq "client conf: server key" "$(echo "$c" | sed -n 's/^PublicKey = //p')" "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo="
	eq "client conf: tunnel and home network only" "$(echo "$c" | sed -n 's/^AllowedIPs = //p')" "10.77.0.0/24, 192.168.1.0/24"
	eq "client conf: endpoint" "$(echo "$c" | sed -n 's/^Endpoint = //p')" home.example.org:51820
	eq "client conf: IPv6 endpoint in brackets" "$(remote_client_conf phone 192.168.1.0/24 2001:db8::1 | sed -n 's/^Endpoint = //p')" "[2001:db8::1]:51820"
	if remote_client_conf nobody 192.168.1.0/24 x >/dev/null; then bad "client conf: unknown device refused"; else ok "client conf: unknown device refused"; fi
	p=$(remote_peers_public); dk=$(printf '%s' "$REMOTE_PEERS" | cut -d'|' -f3)
	eq "router gets the device's public key, not its private key" "$p" "phone|5|$(wg_pubkey "$dk")|$(printf '%s' "$REMOTE_PEERS" | cut -d'|' -f4)"
	# An OpenSSL that can't do X25519 (macOS LibreSSL): no config with an empty key.
	mkdir -p "$T/nox"; printf '#!/bin/sh\ncase $1 in pkey) exit 1 ;; esac\nexec openssl "$@"\n' > "$T/nox/fakessl"; chmod 755 "$T/nox/fakessl"
	OPENSSL=$T/nox/fakessl
	if wg_pubkey "$dk" >/dev/null 2>&1; then bad "public key fails without X25519"; else ok "public key fails without X25519"; fi
	if remote_client_conf phone 192.168.1.0/24 x >/dev/null 2>&1; then bad "client conf refused without X25519"; else ok "client conf refused without X25519"; fi
	if remote_peers_public >/dev/null 2>&1; then bad "router keys refused without X25519"; else ok "router keys refused without X25519"; fi
) | tee "$T/r.res"
fails=$((fails + $(grep -c '^FAIL' "$T/r.res"))); n=$((n + $(wc -l < "$T/r.res")))
for a in 10.77.0.0/24 172.16.5.0/24 192.168.200.0/24; do remote_net_ok "$a" && ok "tunnel range $a accepted" || bad "tunnel range $a accepted"; done
for a in 10.077.0.0/24 010.77.0.0/24 8.8.8.0/24 10.77.0.1/24 10.77.0.0/16 172.32.0.0/24 10.300.0.0/24 'x'; do
	if remote_net_ok "$a"; then bad "tunnel range $a rejected"; else ok "tunnel range $a rejected"; fi
done
for a in 100.64.1.2 100.127.0.1 10.0.2.15 192.168.0.5 172.20.1.1; do behind_nat_v4 "$a" && ok "$a is behind NAT" || bad "$a is behind NAT"; done
for a in 100.128.0.1 81.2.3.4 172.32.1.1; do if behind_nat_v4 "$a"; then bad "$a is public"; else ok "$a is public"; fi; done
(
	. "$P1/config.env"
	eq "remote settings pass" "$(check_settings)" ""
	REMOTE_PORT=70000; eq "remote port out of range rejected" "$(check_settings | grep -c REMOTE_PORT)" 1
	REMOTE_PORT=51820 REMOTE_HOST='x;reboot'; eq "remote host with shell characters rejected" "$(check_settings | grep -c REMOTE_HOST)" 1
	REMOTE_HOST='' REMOTE_PEERS="$REMOTE_PEERS
$(printf '%s\n' "$REMOTE_PEERS" | head -1)"; eq "repeated remote device rejected" "$(check_settings | grep -c REMOTE_PEERS)" 1
	k=$(wg_genkey); REMOTE_PEERS="phone|2|${k%??}'=|$k"; eq "remote key with a quote rejected" "$(check_settings | grep -c REMOTE_PEERS)" 1
	REMOTE_PEERS="a b|2|k|p"; eq "bad remote device line rejected" "$(check_settings | grep -c REMOTE_PEERS)" 1
	REMOTE_PEERS=; eq "remote on without devices rejected" "$(check_settings | grep -c REMOTE_PEERS)" 1
	VPN_IFACE=remote; eq "VPN_IFACE 'remote' rejected" "$(check_settings | grep -c VPN_IFACE)" 1
	REMOTE_HOST=home.example.org:51820; eq "remote host with a port rejected" "$(check_settings | grep -c REMOTE_HOST)" 1
	REMOTE_HOST=2001:db8::1; eq "remote host IPv6 address accepted" "$(check_settings | grep -c REMOTE_HOST)" 0
	REMOTE_HOST='' REMOTE_PEERS="living-room-ipad|2|$(wg_genkey)|$(wg_psk)"; eq "device name over 15 characters rejected" "$(check_settings | grep -c REMOTE_PEERS)" 1
) | tee "$T/r2.res"
fails=$((fails + $(grep -c '^FAIL' "$T/r2.res"))); n=$((n + $(wc -l < "$T/r2.res")))

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
