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
| Ad and tracker blocking | [adblock-lean](https://github.com/lynxthecat/adblock-lean), installed from its project on every run with its own installer (`abl-install.sh -v release`), so it is always the current release. The Hagezi lists come from adblock-lean's preset for the router's memory, chosen the way its own setup does it (Hagezi Pro mini on the smallest routers, Pro, then Threat Intelligence added as memory allows), plus your own list. |
| banIP | Blocks incoming scans and brute force on the WAN; extra feeds from your settings. |
| SQM (bufferbloat) | Measures your line, shapes at 90% with cake, then checks the latency under load, following the [OpenWrt SQM guide](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm); see [SQM](#sqm). Link-layer values come from the link type you pick. Per-device fairness (`dual-srchost`/`dual-dsthost`), plus cake's `nat` lookup only when the router does IPv4 NAT. Flow offloading is set to software (hardware offloading bypasses SQM). |
| System | Your admin password, SSH key login (keys you added yourself are kept), time zone, NTP servers by IP address (works before DNS does), packet steering on all CPUs, Wi-Fi name, password and country on every radio (WPA3-only on 6 GHz). On routers with less than about 200 MB of RAM the DNS caches are kept small. |

Optional (asked on the first run):

| Option | What |
|---|---|
| Family filtering | Safe search forced on Google (all its country domains, from Google's own list), Bing, DuckDuckGo, Brave, Startpage and Yandex (refreshed every 30 minutes); Hagezi NSFW, "no safe search" and DoH/VPN/proxy bypass lists; anime/manga NSFW sites from [safe-otaku](https://github.com/5wHN28Dg/safe-otaku); every [listed Redlib instance](https://github.com/redlib-org/redlib-instances) except the ones you allow (refreshed daily); DoT and common VPN protocols blocked from the LAN; banIP `doh` and `vpn` feeds. |
| VPN for chosen sites | Any WireGuard provider (Proton VPN, Mullvad, ...): give it the provider's `.conf` file. Only the domains and IP ranges you list go through the VPN (policy-based routing with `pbr`). IPv6 to those domains never goes around the VPN: it is routed through the VPN when the provider's config has an IPv6 address, otherwise their IPv6 answers are suppressed so devices use IPv4 through the VPN. |
| Telegram through the VPN | With the VPN on: Telegram's own list of address ranges ([core.telegram.org/resources/cidr.txt](https://core.telegram.org/resources/cidr.txt)) and its web domains (`t.me`, `telegram.org`, `telegram.me`, `telegram.dog`, `telesco.pe`, `telegra.ph`, `graph.org`, `tdesktop.com`, `fragment.com`) go through the VPN. `telegram-ranges` refreshes the list daily at 04:20, downloading it through the VPN (where Telegram is blocked, telegram.org is too) and directly only as a fallback. Every range is checked strictly; a failed or odd download keeps the previous list, and if pbr refuses a new list the previous one comes back. When the VPN has no IPv6, Telegram's IPv6 ranges are rejected from the LAN, so apps switch to IPv4 through the VPN at once. The setup starts from a copy of the list in the repo. No proxy or extra program: pbr already routes by address. |
| Telegram proxy | With Telegram through the VPN: a SOCKS5 proxy on the router ([microsocks](https://github.com/rofl0r/microsocks), 7 KB) for phones, set once in Telegram (Settings > Data and Storage > Proxy). It answers on the router's LAN address and any ZeroTier address (the firewall keeps it off the internet), needs a password (made by the setup, in `private/config.env`), runs as its own user, and that user can only reach Telegram's addresses (kept current with the list). The router sends its Telegram traffic through the VPN too. Useful away from home where routes into the home network aren't possible, such as ZeroTier's free plan; with the [ZeroTier](#zerotier) option the proxy also answers on the router's ZeroTier address. New connections from the proxy are allowed only to Telegram's IPv4 ranges, and only leaving through the VPN (checked after routing), plus the router's filtered DNS: with the VPN or pbr down it doesn't work rather than going around it, and it can't reach the router's other services or other devices. Telegram's web pages (`t.me` and the like) are not proxied, only the app's connections. |
| MangaDex safe-mode reader | The [safe-otaku](https://github.com/5wHN28Dg/safe-otaku) reader at `http://manga.lan`. |
| Private Redlib | [Redlib](https://github.com/redlib-org/redlib) (Reddit without ads, tracking or the app) at `http://reddit.lan`, from [Nachtalb's fork](https://github.com/Nachtalb/redlib), which gets past Reddit's blocking, for the LAN and remote-access devices. Adult posts are hidden (Redlib's SFW-only mode) while family filtering is on, and off by default otherwise. If your own block list blocks Reddit, devices stay blocked: only Redlib fetches it. See [Redlib](#redlib). |
| Remote access | Reach your home network and `manga.lan` from anywhere through a WireGuard tunnel to the router. Each device you name (e.g. `phone laptop`) gets its own key; its config file lands in `private/remote/` for the WireGuard app (`qrencode -t ansiutf8 < private/remote/phone.conf` shows it as a QR code for phones). Only the tunnel and your home network go through it, and the device uses the router's DNS, so blocking and family filtering apply. See [Remote access](#remote-access) for what your line needs. |
| ZeroTier | Remote access that also works when your provider shares one public address among many customers (carrier-grade NAT), where the WireGuard option can't be reached: the router joins your ZeroTier network (free plan) and devices reach the router itself at its ZeroTier address: LuCI, the MangaDex app (`http://<address>/mangadex-safe/`) and the Telegram proxy (nothing behind it: ZeroTier gets its own firewall zone that forwards nowhere). About 1 MB of storage and 8 MB of RAM (measured on a Redmi AX6S). See [ZeroTier](#zerotier). |
| Tailscale | Remote access behind a shared address too, in the same app many phones already run: devices in your tailnet reach the router itself (LuCI, SSH, the MangaDex app). With Telegram through the VPN on, the router also offers Telegram's address ranges to your tailnet, so a phone away from home sends Telegram, calls and group voice chats included, through the router's VPN (no proxy can carry calls). A trimmed Tailscale built on your computer: about 5 MB of flash and 21-26 MB of RAM (measured on the test VM; the stock build uses about 50 MB). See [Tailscale](#tailscale). |

Separately, `./kids.sh` gives chosen devices fixed addresses and turns their
internet off at night, along with the router's own pages (`reddit.lan`,
`manga.lan`, LuCI), matched by MAC address so IPv6 and self-chosen
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

## SQM

The guide's method is: measure the idle line, set 90% of it, test for
bufferbloat, adjust. The setup does this on each run:

1. **Measure.** Eight streams to Cloudflare's speed test load the line, 12 s
   each way, while the router reads its WAN port's byte counter every second.
   The counter sees all traffic, so what somebody else is using at that moment
   counts toward the result instead of being missed. The rate is the median
   after a 3 s warm-up, so neither the ramp-up nor a short dip sets it. Cable lines often get about 10 s of extra
   speed at the start: they (and "Not sure") are measured for 25 s and the
   first 10 s are left out. If your router sits behind a cable modem, pick a
   cable link type so this applies.
2. **Shape** at 90% of that.
3. **Check.** It pings while the line is loaded in both directions. Up to
   30 ms more than idle passes (the "A" grade of the
   [Waveform test](https://www.waveform.com/tools/bufferbloat)); more, or most
   pings lost, is a FAIL that tells you to lower the rates. If the load
   stays under half the shaped rate in a direction, or the speed test failed
   on this run, the report says the check was not done instead of passing it.

To tune by hand, as the guide describes (raise the rates until latency
appears, then back off), put the rates in `private/config.env`:

```
SQM_DOWN='95000'   # kbit/s, used as they are; the line is no longer measured
SQM_UP='19000'
```

The check in step 3 still runs with fixed rates. Set them too if the report
says the router's CPU was the limit during the speed test (a fast line on a
small router measures low), or on a line whose speed changes during the day.
`SQM_FALLBACK_DOWN/UP`, if you set them, are only used when the speed test
fails.

The test moves real data: the line runs at full speed for about 40 s per run
(about 85 s on cable and "Not sure"), which is roughly 5 GB per 1 Gbit/s of
line speed (10 GB on cable). On a metered line, set fixed rates; then only
the latency check loads the line (about 11 s, or 18 s on cable).

## Remote access

New to this? [docs/remote-access.md](docs/remote-access.md) walks through
it from zero: checking your connection, the provider's box, a DuckDNS name,
and getting the configs onto your phone and laptop.

The router listens for WireGuard on UDP 51820 (changeable) and puts tunnel
devices (10.77.0.0/24 unless you set `REMOTE_NET`) in the LAN zone. The keys
are made on your computer with OpenSSL and kept in `private/config.env`, so a
re-install keeps every device working; removing a name from the device list
revokes it. Device names are letters, digits, `_` or `-`, up to 15 characters
(the WireGuard apps use the file name as the tunnel name). The router only
ever gets the devices' public keys. Turning remote access off deletes the
configs in `private/remote/`; the keys stay in the settings for next time.

Devices outside need to find your home:

- Give a dynamic-DNS name (e.g. from DuckDNS) when asked, if your provider
  changes your address. Without one, the configs point at the router's current
  address and need re-running `./setup.sh` when it changes (answer `-` in
  `./setup.sh --reconfigure` to go back from a name to the router's address).
- If the router's internet address is private or carrier-grade NAT (100.64.x.x;
  common on mobile and some fibre lines, or with a modem that routes), it
  can't be reached from outside: forward UDP 51820 to the router on the modem,
  or ask your provider for a public IPv4 address. The setup warns about this.
- On a network that uses the same address range as your home (often
  192.168.1.x), the device can't tell the two apart: give your router's LAN an
  uncommon range in LuCI (e.g. 192.168.47.1) if you use remote access a lot.

## ZeroTier

For lines where the router can't be reached from outside (the provider gives
it a shared, carrier-grade NAT address such as 100.64.x.x), WireGuard remote
access can't work; ZeroTier does, because the router and your devices both
connect out to ZeroTier's servers.

1. Create a network at [my.zerotier.com](https://my.zerotier.com) (free
   plan). With family filtering on, that site is blocked at home (the
   VPN-bypass list blocks ZeroTier for devices): use mobile data. Keep its
   access control on Private.
2. Run `./setup.sh --reconfigure` and give the 16-character network ID.
3. Approve the router under Members (the setup prints its node ID), then
   install the ZeroTier One app on your phone, join the same network and
   approve the phone too.

Away from home, with the app on, the phone reaches the router at its
ZeroTier address (the setup prints it once approved). ZeroTier's free plan
has no managed routes or DNS, so `manga.lan`, `reddit.lan` and the other
devices at home aren't reachable that way: use the router's ZeroTier address.

ZeroTier gets its own firewall zone: members reach the router's own services
(LuCI, SSH, the MangaDex app, the Telegram proxy, its filtered DNS) and
nothing behind it, so even a member that adds its own route can't reach other
devices at home or use your line or VPN. The setup refuses a network whose
access control is Public (anyone with its ID could join); keep it Private
(a network switched to Public later is only caught on the next setup run). The kids' night
rules match devices at home by MAC address, not ZeroTier members: approve
only your own devices.

With the option on, the setup manages ZeroTier on the router: it joins the
one network from the settings and drops other networks set up there by hand;
a `zt+` put in the lan zone by hand moves to the ZeroTier zone. If ZeroTier
interfaces sit in a firewall zone in another form (for example a network
interface added to the lan zone in LuCI), in a bridge, or in firewall rules
it didn't make, the setup stops before changing
anything, since that zone would keep giving them its access. The setup saves the router's ZeroTier identity in
`private/zerotier/identity.secret` and gives it back on re-installs, so a
reset router doesn't need approving again (one `private/` folder is for one
router: two routers with the same identity clash). Turning the option off
removes the package and its settings (the identity stays in `private/`).

## Tailscale

Like [ZeroTier](#zerotier), Tailscale works where the router can't be reached
from outside, because the router and your devices both connect out. It also
gets a phone's Telegram calls through the VPN when away from home: Telegram
never sends calls through a proxy (its call code uses UDP, which it doesn't
pass to a SOCKS5 proxy), so the [Telegram proxy](#what-it-sets-up) carries
messages only. With Tailscale the phone's Telegram traffic itself travels to
the router, which sends it through the VPN like a device at home.

1. In the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys),
   generate an auth key (not reusable, not ephemeral). With family filtering
   on, tailscale.com is blocked at home (the VPN-bypass list): use mobile data.
2. Run `./setup.sh --reconfigure`, say yes to Tailscale and paste the key (it
   goes to `private/tailscale-authkey`; used once).
3. In the admin console under Machines, for the router: Edit route settings
   and approve its routes (Telegram's ranges), and Disable key expiry (or it
   logs out after 180 days). The setup's report says when either is needed.
4. On the phone, turn Tailscale on (Android: Use Tailscale subnets stays on).

Away from home, with Tailscale on, the phone reaches the router at its
Tailscale address (100.x.y.z, printed by the setup) and Telegram goes through
the router's VPN. `manga.lan` and the other devices at home aren't reachable
that way (no routes into the home network): use the router's address.

**Why a trimmed build.** OpenWrt's `tailscale` package is the full program:
26 MB of storage and about 50 MB of memory, a fifth of a 256 MB router.
Tailscale can leave features out when it is built; `setup.sh` builds
[Tailscale's release](https://github.com/tailscale/tailscale) (pinned version
and commit, in `lib/tailscale.sh`) with only routing, NAT traversal, direct
UDP, route advertising and the command-line tool, using Tailscale's own Go
toolchain (downloaded into `~/.cache` the first time, about 500 MB; needs
git and curl). It runs with Go's memory settings tuned (`GOGC=50`,
`GOMEMLIMIT=12MiB`). Measured on the 256 MB test VM, logged in and carrying
traffic:

| Build | Program | Memory |
|---|---|---|
| Stock | 40 MB | 49-52 MB |
| Trimmed (this setup) | 13 MB (about 5 MB compressed on flash) | 21-26 MB |

The catch: updates are yours. OpenWrt doesn't update this build: for a new
Tailscale release, change `TS_VERSION` and `TS_COMMIT` in `lib/tailscale.sh`
and run the setup again.

**What it can reach.** Tailscale gets its own firewall zone: devices in your
tailnet reach the router's own services (LuCI, SSH, the MangaDex app, the
Telegram proxy) and are forwarded only into the VPN. What goes into the VPN
is decided by the VPN rules (Telegram's ranges, your VPN domains and ranges);
anything else, and everything while the VPN rules are down, would leave
through your line and is refused. The router takes no DNS or routes from the
tailnet. The block lists block tailscale.com for every device at home; the
router's own Tailscale runs in its own group, whose DNS lookups (and only
those) go to the encrypted resolver behind the lists, as Redlib's do.

With the option on, the setup manages Tailscale on the router. It stops
before changing anything if OpenWrt's `tailscale` package is installed
(remove it first) or Tailscale's device sits in a firewall zone, bridge or
rule it didn't make. It saves the router's Tailscale state (identity and
login) in `private/tailscale/` and gives it back on re-installs, so a reset
router comes back as the same device without a new key (one `private/`
folder is for one router). The program and state are kept across firmware
upgrades, and `oneclick-after-upgrade` switches Tailscale on again after
one. A new login (a new key after the option was off, or after the login
expired) replaces the saved state. Turning the option off logs the router
out and removes the program, its state (on the router and in `private/`),
group, zone and rules; `kmod-tun` stays (40 KB, ZeroTier uses it too).

## Proton VPN server choice

With Proton VPN as the VPN, the router can keep the tunnel on a working, fast
server by itself, like the "fastest server" button in Proton's apps. Answer
yes to "Is this Proton VPN, and should the router pick the server?", then log
in once:

```
python3 -m venv .venv && .venv/bin/pip install 'git+https://github.com/ProtonVPN/python-proton-core.git@9bd4662ddde2d439e4e8c900f0431e23958bd512'
./proton-login.sh      # password, CAPTCHA in your browser, 2FA code
./setup.sh             # hands the session to the router
```

Proton's own client library does the login (it is not on PyPI under its own
name, so it is installed from Proton's repository at a fixed version). Your
password goes only to Proton; the router gets the session, which it renews
itself from then on, and the laptop copy is deleted.

On the router, `proton-pick` (in `/usr/sbin`):

- once a day fetches Proton's server list and keeps the servers your plan can
  use (no Secure Core or Tor), in the countries you chose or all of them;
- every 5 minutes reads how long ago the tunnel last had a handshake. If that
  is more than 5 minutes, or its server dropped off the list, and the
  internet line itself works, it switches: for each country the least loaded
  server, then whichever of those answers ping fastest from your router (on
  load alone if none answer). Your WireGuard key works on every Proton
  server, so a switch only changes the peer: nothing restarts and routing is
  not disturbed. The new server is saved (so a reboot keeps it) only once it
  has answered a handshake. If none answers (the key was revoked, or your
  provider blocks WireGuard), each server is tried once and then it waits for
  the next day's list instead of switching back and forth.

Why ping and not distance: from the network this was built on, the nearest
country (Romania) answered in 125 ms and two farther ones in 87-89 ms.

Cost: about 0.4 MB downloaded and 0.3 s of CPU once a day; the check is a
file read. Flash is written when Proton renews the session (about once a
day, ~150 bytes), when the list of servers changes, and when a new server
has proven itself; never while the line or the servers are down.
`proton-pick status` shows the current server, handshake age and session. If
Proton ever ends the session, the router keeps switching within the last
list and the status and system log say to run `./proton-login.sh` and
`./setup.sh` again.

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
| `redlib-sessions.txt` | Reddit sessions of throwaway accounts for Redlib (optional, see [Redlib](#redlib)). |
| `remote/` | WireGuard configs for your remote-access devices (written after each run). |
| `zerotier/identity.secret` | The router's ZeroTier identity (saved after the first run). |
| `tailscale-authkey`, `tailscale/` | The Tailscale auth key you give once, then the router's Tailscale state (saved after the first login). |
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
`private/config.env`, not by hand. Block lists beyond adblock-lean's preset
go in `ADBLOCK_EXTRA_LISTS` (family filtering adds its lists there).
adblock-lean is downloaded from GitHub and run as root on the router, like its
own install instructions do; the setup trusts that project.

Firmware upgrades (LuCI's Attended Sysupgrade or `owut`, which build the new
firmware with your installed packages) keep everything the setup made: its
files are listed in `/etc/sysupgrade.conf`. A minute after the first boot of
the new firmware, `oneclick-after-upgrade` (started from `/etc/rc.local`)
puts back what an upgrade can't keep: the `manga.lan` redirect in LuCI's
start page, adblock-lean and Tailscale switched on, and the Redlib program
(left out of the backup: 11 MB). A plain sysupgrade with a stock image loses the packages
(pbr, dnsmasq-full, microsocks, ...): run `setup.sh` again after one.

## Tests

- `tests/lint.sh`: [ShellCheck](https://www.shellcheck.net) on every script
  (errors and warnings).
- `tests/unit.sh`: the laptop-side helpers and the question flow, no router
  needed.
- `tests/vm.sh`: the whole setup on a throwaway OpenWrt virtual machine
  (qemu), measuring a stand-in line of known speed (`tests/speedsrv.py`,
  needs python3): every option on, then re-runs that switch parts off, change the SSH
  key and present a different host key; and every option off. It never touches a
  real router. If your own network blocks DNS-over-HTTPS for its devices, run
  it with `TEST_DNS_UPSTREAM=10.0.2.3:53`.

## Redlib

What it costs and why each part is there:

| Part | Why |
|---|---|
| The program: 14-17 MB of flash, depending on your router's CPU type | The build for the router's CPU from [Nachtalb's fork](https://github.com/Nachtalb/redlib) (its `latest` release, rebuilt on every change). Upstream [redlib-org/redlib](https://github.com/redlib-org/redlib) stopped working when Reddit blocked it in October 2026; the fork gets past the blocking, shows the last good copy of a page while Reddit refuses (kept at 4 MB of RAM here; the fork's default is 32 MB), and adds many fixes ([its list](https://github.com/Nachtalb/redlib/blob/main/FORK.md)). Not kept in firmware-upgrade backups (they live in RAM during the upgrade); the updater puts it back and starts Redlib again a minute after the first boot of the new firmware. |
| Its own address (the last one of the LAN, e.g. `192.168.1.254`) and `reddit.lan` | So it can serve on port 80 next to LuCI. DHCP keeps handing out the router's main address. The setup stops if that address is in the DHCP pool or a fixed lease. |
| A firewall rule, port 80 → 8080 on that address | Redlib runs as its own user, not root, and such a user can't open port 80. |
| A firewall rule for its DNS | That user's lookups go to the encrypted resolver behind the block lists, so a Reddit block in your list keeps applying to every device but not to Redlib. |
| First to go when memory runs out | The kernel kills Redlib before anything else (DNS, the firewall), and procd restarts it; if procd gives up, the nightly updater starts it again. |
| `redlib-update`, daily at 03:40 | Takes the fork's build once it is at least 3 days old (broken builds have been replaced by then). The fork often changes daily, so with nothing from the fork installed yet, or the installed build over 14 days old, it takes the newest at once. It takes the file only from the fork's own release address, checks it against the SHA-256 GitHub publishes for it, and puts the previous version back if the new one doesn't answer within two minutes (that build is then skipped, and no other is tried for 7 days). New downloads are checked as the `redlib` user, never as root. |
| Reddit sessions (optional), `private/redlib-sessions.txt` | Reddit serves full post pages only to logged-in visitors. Put the `reddit_session` cookie of a **throwaway** Reddit account in this file (one per line, `#` for comments; from a logged-in reddit.com browser: DevTools > Application > Cookies) and run the setup: it goes to `/etc/redlib/sessions`, owned by root and readable only by Redlib's group. Turn off "Show mature content" in that account's Reddit settings. Without it, listings work and post pages show Reddit's first batch of comments. The session lasts about six months; logging out on reddit.com ends it. Reddit may ban an account used this way, so never use your own. |

Redlib works only as long as Reddit lets it in. Reddit announced in October
2026 that it is moving to a logged-in-only site and started blocking Redlib;
the fork keeps up with that, with sessions as its fallback. The fork is one
person's project: the setup trusts its builds as it trusts upstream's. If it
stops working, `./setup.sh --reconfigure` with Redlib off removes all of the
above.

Redlib's SFW-only mode blocks adult communities and adult post pages. Two
gaps remain, in Redlib itself (upstream and the fork alike):
- Listings and search hide adult posts through the visitor's own "Show NSFW
  posts" setting, which SFW-only mode hides from the settings page but
  doesn't force off. Someone who sets it through its address, and adds the
  right option to a search, sees adult posts and thumbnails in listings and
  search results (opening one is still blocked). The block lists and safe
  search on the other sites don't cover this.
- Its image and video pages (`/img/...`, `/vid/...`) still load media for
  anyone who already has the exact address of a file.

## Limits

- Not configured: static WAN addresses, VLAN-tagged WAN (some DSL/fibre
  providers need a VLAN ID), DS-Lite/MAP-E. Set those in LuCI first; the
  setup leaves them alone apart from PPPoE.
- The kids' cut-off stops new connections at the start time; a video or game
  stream that is already open can keep running until it ends.
- IPv6 routing through the VPN (provider config with an IPv6 address) is not
  covered by the automated tests, which have no IPv6 internet.
- Redlib blocking covers the instances in the public list, not unlisted ones.
- The private Redlib follows official releases, which can be months apart:
  a fix for a Reddit change may wait in Redlib's code until the next one.
- Proton server choice uses Proton's API as its own apps do, but this tool is not
  made or endorsed by Proton; a login may ask for a CAPTCHA.
- Remote access is IPv4 inside the tunnel, and dynamic DNS is not set up on
  the router (give a name you keep updated elsewhere, or use the router's address).
- adblock-lean's preset sizes its limits for its own lists. Family filtering
  raises the size limit for its lists; other extra lists must fit in what's left.
- Cloudflare rate-limits repeated speed tests from one address for about an
  hour; the setup then uses the rates you put in `SQM_FALLBACK_DOWN/UP`, or
  leaves SQM off and says so. Fixed rates (`SQM_DOWN/UP`) need no speed test.
- The speed test opens a new connection for each ~100 MB, so above roughly
  1 Gbit/s (or upload above a few hundred Mbit/s on a small router) it can
  measure low. The report notes when a CPU core was the limit; set fixed
  rates then.
- SQM rates are fixed numbers: on lines whose speed varies a lot (mobile,
  Starlink) no single rate is right all day.
- The latency check loads the line from the router itself, which is close to,
  but not the same as, a test from a device behind it.

## Licences

The scripts are under the GNU AGPL v3 (`LICENSE`). Bundled third-party code
keeps its own licence: the safe-otaku reader (AGPL-3.0,
`router/vendor/safe-otaku/LICENSE`). adblock-lean (GPL-2.0) is not bundled; it
is fetched from its project.
Versions are in `router/vendor/VERSIONS`.
