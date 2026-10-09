# openwrt-oneclick

Turn a freshly installed OpenWrt router into a filtered, encrypted-DNS,
low-latency home router with one command, and get a PASS/FAIL report at the
end. Run it again after a reset or on a new router and you get the same setup.

```
./setup.sh
```

The first run asks a few questions (Wi-Fi, passwords, your type of internet
line, which optional parts you want) and offers to save the answers in
`private/`, which git ignores. Later runs don't ask anything.

## What you need

- A router with a fresh OpenWrt 25.12 or later (older releases with `opkg`
  should work but are untested).
- A Linux or macOS computer with `ssh`, `tar` and OpenSSL 1.1.1 or later
  (`openssl passwd -5`; on macOS `brew install openssl`), plugged into a LAN
  port. The router's WAN port goes into your internet box.

## What it sets up

Always:

| Part | What |
|---|---|
| Encrypted DNS | `dnsproxy` on 127.0.0.1:5354 using Cloudflare (HTTP/3), NextDNS and Quad9, with Quad9 DoT as fallback. `dnsmasq` only forwards there. |
| DNS hijack | Devices that use their own DNS server on port 53 are redirected to the router. |
| Ad and tracker blocking | [adblock-lean](https://github.com/lynxthecat/adblock-lean) 0.8.1 (bundled) with Hagezi Pro and Threat Intelligence (mini), plus your own list. |
| banIP | Blocks incoming scans and brute force on the WAN; extra feeds from your settings. |
| SQM (bufferbloat) | Measures your line (Cloudflare, 4 streams, 10 s each way) and shapes at 90% with cake, following the [OpenWrt SQM guide](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm). Link-layer values come from the link type you pick. Per-device fairness (`dual-srchost`/`dual-dsthost`), plus cake's `nat` lookup only when the router does IPv4 NAT. |
| System | Your admin password, SSH key login (keys you added yourself are kept), time zone, NTP servers by IP address (works before DNS does), packet steering on all CPUs, Wi-Fi name, password and country on every radio (WPA3-only on 6 GHz). On routers with less than about 200 MB of RAM the DNS caches are kept small. |

Optional (asked on the first run):

| Option | What |
|---|---|
| Family filtering | Safe search forced on Google (all its country domains, from Google's own list), Bing, DuckDuckGo, Brave, Startpage and Yandex (refreshed every 30 minutes); Hagezi NSFW, "no safe search" and DoH/VPN/proxy bypass lists; anime/manga NSFW sites from [safe-otaku](https://github.com/5wHN28Dg/safe-otaku); every [listed Redlib instance](https://github.com/redlib-org/redlib-instances) except the ones you allow (refreshed daily); DoT and common VPN protocols blocked from the LAN; banIP `doh` and `vpn` feeds. |
| VPN for chosen sites | Any WireGuard provider (Proton VPN, Mullvad, ...): give it the provider's `.conf` file. Only the domains and IP ranges you list go through the VPN (policy-based routing with `pbr`). IPv6 to those domains never goes around the VPN: it is routed through the VPN when the provider's config has an IPv6 address, otherwise their IPv6 answers are suppressed so devices use IPv4 through the VPN. |
| MangaDex safe-mode reader | The [safe-otaku](https://github.com/5wHN28Dg/safe-otaku) reader at `http://manga.lan`. |

Separately, `./kids.sh` gives chosen devices fixed addresses and turns their
internet off at night, matched by MAC address so IPv6 and self-chosen
addresses are covered too (asks for the devices and times on first use;
`./kids.sh --remove` takes the rules off).

## Your internet line

SQM needs to know how many bytes your line adds to each packet. Pick the
closest from the menu; the values are from the OpenWrt SQM guide:

| Link type | Link layer | Overhead | MPU |
|---|---|---|---|
| VDSL2 with PPPoE | Ethernet | 34 | 68 |
| VDSL2 without PPPoE | Ethernet | 26 | 68 |
| VDSL2 behind a 100 Mbit/s Ethernet modem | Ethernet | 42 | 84 |
| ADSL or other ATM-based DSL | ATM | 44 | 96 |
| Cable (DOCSIS), plan under 760 Mbit/s | Ethernet | 22 | 64 |
| Cable (DOCSIS), plan 760 Mbit/s or more | Ethernet | 42 | 84 |
| Fibre (FTTH/GPON) | Ethernet | 44 | 84 |
| Ethernet to the provider | Ethernet | 44 | 84 |
| Not sure | Ethernet | 44 | 96 |

If your provider needs a PPPoE login, the setup asks for it.

IPv4 and IPv6 are detected on the router, not assumed. With IPv4 behind the
router's NAT, cake looks up the real device behind NAT so fairness works per
device. Without IPv4 (IPv6-only lines) that lookup is skipped. With usable
IPv6, banIP also covers IPv6.

## Packet steering

When a packet arrives, the CPU core that gets the network card's interrupt
normally does all the work for it, so on a multi-core router one core can max
out while another idles, especially with cake at high speeds. Packet steering
spreads that work: OpenWrt's `1` moves it to the least busy core, `2` spreads
it across all cores. The SQM guide recommends all cores, so the setup uses `2`.

## Private files

Everything personal lives in `private/` (gitignored, mode 700):

| File | What |
|---|---|
| `config.env` | All answers, including passwords (the admin password is stored hashed), Wi-Fi key and WireGuard keys. |
| `host_keys/` | The router's SSH host keys, saved after the first successful run and restored on re-install, so `ssh` keeps trusting it. |
| `blocklist.txt`, `allowlist.txt` | Your own domains to block or always allow, one per line (optional). |
| `kids.conf` | Devices and times for `kids.sh`. |

`./setup.sh --reconfigure` changes the saved answers before running;
`./setup.sh --settings-only` changes them without touching a router. Keep a
backup of `private/` somewhere safe and encrypted.

## How it runs

`setup.sh` copies `router/` and your private files to the router's RAM
(`/tmp`), starts `router/install.sh` there in the background (it restarts the
network and SSH while it works), follows its log, and deletes the copy at the
end. Hardware differences (WAN port name, which Wi-Fi radios exist, 5 GHz
802.11ax support) are detected on the router, so other models work too.

Running it again on a router it already set up is safe: it replaces its own
rules instead of adding new ones, and removes parts you switched off (VPN,
MangaDex reader, PPPoE, family filtering). It also resets the files it manages
(`/etc/config/dnsproxy`, `pbr`, `banip`, adblock-lean's config, dnsmasq's
upstream servers) to its own settings, so change those through
`private/config.env`, not by hand.

## Tests

- `tests/unit.sh`: the laptop-side helpers and the question flow, no router
  needed.
- `tests/vm.sh`: the whole setup on a throwaway OpenWrt virtual machine
  (qemu): every option on, then re-runs that switch parts off, change the SSH
  key and present a different host key; and every option off. It never touches a
  real router. If your own network blocks DNS-over-HTTPS for its devices, run
  it with `TEST_DNS_UPSTREAM=10.0.2.3:53`.

## Limits

- Not configured: static WAN addresses, VLAN-tagged WAN (some DSL/fibre
  providers need a VLAN ID), DS-Lite/MAP-E. Set those in LuCI first; the
  setup leaves them alone apart from PPPoE.
- The kids' cut-off stops new connections at the start time; a video or game
  stream that is already open can keep running until it ends.
- IPv6 routing through the VPN (provider config with an IPv6 address) is not
  covered by the automated tests, which have no IPv6 internet.
- Redlib blocking covers the instances in the public list, not unlisted ones.
- Cloudflare rate-limits repeated speed tests from one address for about an
  hour; the setup then uses the rates saved in `SQM_FALLBACK_DOWN/UP`, or
  leaves SQM off and says so.

## Licences

The scripts are under the GNU AGPL v3 (`LICENSE`). Bundled third-party code
keeps its own licence: adblock-lean (GPL-2.0, `router/vendor/adblock-lean/LICENCE.md`)
and the safe-otaku reader (AGPL-3.0, `router/vendor/safe-otaku/LICENSE`).
Versions are in `router/vendor/VERSIONS`.
