// Proton VPN server list (/vpn/v1/logicals) -> "CC LOAD NAME IP KEY" lines.
// Usage: ucode parse.uc LOGICALS.json MAX_TIER "CC CC ..."   (empty = all)
// Keeps enabled servers the plan may use, without Secure Core (1) or Tor (2),
// with every enabled machine that has a WireGuard key (first one first).
import { readfile } from "fs";

const file = ARGV[0], tier = +ARGV[1], want = split(ARGV[2] ?? "", /\s+/);
const only = {};
for (let c in want) if (length(c)) only[c] = true;
const any = !length(keys(only));

const data = json(readfile(file));
for (let s in data?.LogicalServers ?? []) {
	if (s.Status != 1 || s.Tier > tier || (s.Features & 3)) continue;
	if (!any && !only[s.ExitCountry]) continue;
	for (let p in s.Servers ?? []) {
		if (p.Status == 1 && p.X25519PublicKey && p.EntryIP &&
		    match(p.EntryIP, /^[0-9.]+$/) && match(p.X25519PublicKey, /^[A-Za-z0-9+\/]{43}=$/)) {
			print(s.ExitCountry, " ", s.Load ?? 100, " ", replace(s.Name, /[^A-Za-z0-9#._-]/g, "_"), " ",
			      p.EntryIP, " ", p.X25519PublicKey, "\n");
		}
	}
}
