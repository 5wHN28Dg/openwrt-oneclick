# CLAUDE.md

Project kind: every other project (do the work).

One-click setup for a fresh OpenWrt router: `setup.sh` runs on a laptop, asks
for anything it doesn't know yet, copies `router/` to the router and runs
`router/install.sh` there.

- Anything personal (passwords, keys, Wi-Fi, device MACs, VPN config, own
  block lists) lives in `private/`, which is gitignored. Never commit it, and
  never print secrets in logs or reports.
- Router resources are scarce: no new packages or persistent processes without
  a reason that is written down. Prefer what OpenWrt ships (BusyBox, ucode,
  uclient-fetch, jsonfilter).
- Test on the throwaway VM (`tests/vm.sh`), never on a live router. Unit tests:
  `tests/unit.sh`.
