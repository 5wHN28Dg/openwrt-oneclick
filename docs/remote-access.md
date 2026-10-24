# Remote access, step by step

How to reach your home network and `http://manga.lan` from anywhere, from
zero. Do it at home, on the router's network. Every step says why it's needed.

## The idea in one paragraph

Your phone, out on mobile data, has to find your home on the internet and
then get through the router's firewall. Three things make that work:

1. **An address.** Your home has a public internet address, but your provider
   can change it. DuckDNS gives you a fixed name (like `myhome.duckdns.org`)
   that always points to the current address.
2. **An open door.** WireGuard listens on UDP port 51820 on the router. If
   another box from your provider sits in front of your router, that box must
   pass the port through.
3. **A key per device.** Each device gets its own config file containing its
   key. Only devices with a key can get in, and removing a device's name later
   locks that device out.

## Step 1: Find out what kind of connection you have

This decides which steps you need. On your laptop, run:

```
ssh root@192.168.1.1 'ifstatus wan | jsonfilter -e "@[\"ipv4-address\"][0].address"'
curl -4 https://ifconfig.me; echo
```

The first command is the address your router received; the second is your
home's address as the internet sees it. Compare them:

| What you see | What it means | What to do |
|---|---|---|
| Both the same | Your router is directly on the internet | Skip step 2 |
| First starts with `192.168.`, `10.` or `172.16`–`172.31` | Your provider's box sits in front of your router | Do step 2 |
| First starts with `100.64` to `100.127` | Your provider shares one public address among many customers ("CGNAT") | Remote access can't work this way. Ask your provider for a public IPv4 address (sometimes free, sometimes paid), then start again |

## Step 2 (only if the provider's box is in front): open the port on that box

**Why:** your phone's request arrives at the provider's box first. Without a
rule, the box doesn't know it should hand the request to your router.

1. Find the box's address:
   ```
   ssh root@192.168.1.1 'ifstatus wan | jsonfilter -e "@.route[0].nexthop"'
   ```
2. Open that address in a browser (e.g. `http://192.168.0.1`) and log in. The
   password is often on a sticker on the box.
3. Find the section called "Port forwarding", "Port sharing", "Virtual server"
   or "NAT", and add a rule:
   - **Protocol:** UDP
   - **External port:** 51820
   - **Internal port:** 51820
   - **Device or internal address:** your router's address from the first
     command in step 1
4. If the box offers "always give this device the same address" (DHCP
   reservation), turn it on for your router. Otherwise the rule can end up
   pointing at an old address.

## Step 3: Get a DuckDNS name

**Why:** your provider can change your home address at any time. The name
keeps working because the router will keep telling DuckDNS the current
address (step 4).

1. Go to **https://www.duckdns.org** and sign in with one of the accounts it
   offers (GitHub, Google and so on).
2. At the top of the page you'll see a **token**, a long code like
   `a1b2c3d4-...`. That is the password for updating your name, so don't share
   it or post screenshots of it.
3. In the **sub domain** field, type a name (for example `myhome`) and click
   **add domain**. You now own `myhome.duckdns.org`.

## Step 4: Make the router keep the name up to date

**Why:** DuckDNS only knows your address if something tells it, so the router
reports it every 5 minutes. Leaving `ip=` empty means "use the address this
request comes from", which is your real public address even when the
provider's box is in front.

1. Log in to the router:
   ```
   ssh root@192.168.1.1
   ```
2. Test once. Replace `myhome` with your name (without `.duckdns.org`) and
   `YOUR-TOKEN` with the token from step 3:
   ```
   uclient-fetch -qO- "https://www.duckdns.org/update?domains=myhome&token=YOUR-TOKEN&ip="; echo
   ```
   It should print `OK`. `KO` means the name or token is mistyped.
3. Make it repeat every 5 minutes (same replacements):
   ```
   echo '*/5 * * * * uclient-fetch -qO /dev/null "https://www.duckdns.org/update?domains=myhome&token=YOUR-TOKEN&ip="' >> /etc/crontabs/root
   /etc/init.d/cron restart
   exit
   ```
4. Check on the laptop: `nslookup myhome.duckdns.org` should show the same
   address as `curl -4 https://ifconfig.me`.

This line survives re-running `./setup.sh`. After a factory reset of the
router, you have to add it again.

## Step 5: Turn on remote access in the setup

```
cd ~/Documents/GitHub/openwrt-oneclick
./setup.sh --reconfigure
```

Press **Enter** at every question: Enter keeps your current answer, and for
"Change the …?" questions it means no. Stop at these:

- `Turn on remote access?` → `y`
- `Public name or address of your home` → `myhome.duckdns.org`
- `UDP port for the tunnel` → Enter (keeps 51820, matching step 2)
- `Devices that may connect` → `phone laptop` (or your own names: letters,
  digits, `-` or `_`, up to 15 characters)

The setup then runs on the router (5–10 minutes; the internet drops briefly).
It also re-measures your line speed, so start it when nobody is streaming. At
the end it prints where the device configs are: `private/remote/phone.conf`
and `private/remote/laptop.conf`.

**Why one file per device:** each holds that device's own secret key, so
they're like passwords. Don't email them or put them in cloud storage.

## Step 6: Put the config on your devices

**Phone**

1. Install **WireGuard** from the Play Store or App Store (publisher:
   WireGuard Development Team).
2. Show the config as a QR code on the laptop, which avoids moving the secret
   file around:
   ```
   sudo apt install qrencode
   qrencode -t ansiutf8 < private/remote/phone.conf
   ```
3. In the app, tap **+** → **Scan from QR code**, scan the code on the screen,
   and name the tunnel `home`.

**Laptop (Ubuntu)**

```
nmcli connection import type wireguard file private/remote/laptop.conf
nmcli connection modify laptop connection.autoconnect no
```

Switch it on with `nmcli connection up laptop` when you're away, and off with
`nmcli connection down laptop`.

## Step 7: Test it

1. On the phone, turn **Wi-Fi off** so you're on mobile data like you would be
   outside.
2. Switch the `home` tunnel on.
3. Open `http://manga.lan` and `http://192.168.1.1` in the browser.

Then check from home that the phone really connected:

```
ssh root@192.168.1.1 wg show remote
```

A line saying "latest handshake: … ago" under one of the peers means it works.
That output lists keys, not names; the peer with a handshake is the device you
just tested.

**Only the home network goes through the tunnel.** Normal browsing goes over
the phone's own connection as usual. But the phone asks your router for DNS
(website names), so ad blocking and family filtering apply on the phone while
the tunnel is on.

## If it doesn't work

| Symptom | Likely cause |
|---|---|
| No handshake at all | The port isn't open on the provider's box (step 2), the DuckDNS name points to an old address (re-check step 4), or you're on CGNAT (step 1) |
| Works outside, not at home on Wi-Fi | Expected: switch the tunnel off at home. With a provider box in front, family filtering's rule against outgoing WireGuard also blocks this |
| `manga.lan` won't load on a hotel or friend's Wi-Fi | That network probably also uses 192.168.1.x and clashes with yours |
| Step 4 prints nothing instead of `OK` | Family filtering may block duckdns.org: add `duckdns.org` to `private/allowlist.txt` and re-run `./setup.sh` |

## Later changes

To add or remove a device, run `./setup.sh --reconfigure` again and edit the
device list. A removed name loses access on that run, a new name gets a new
config, and existing devices keep working.
