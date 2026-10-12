# Number helpers for the SQM steps of install.sh (sourced; BusyBox sh and awk).
# Kept apart so tests/unit.sh can check them without a router.

# median: numbers on stdin, one per line -> their median (whole number); empty for no input
median() {
	sort -n | awk '{ v[NR] = $1 } END { if (NR) printf "%d\n", (NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2) }'
}

# sustained_kbit WARMUP: "seconds byte-counter" samples on stdin (about one a
# second) -> median kbit/s between samples, ignoring the first WARMUP seconds.
# The median leaves out a start-up boost and short dips alike.
sustained_kbit() {
	awk -v w="$1" 'NR == 1 { t0 = $1 }
		NR > 1 && $1 - t0 > w && $1 > pt { printf "%d\n", ($2 - pb) * 8 / 1000 / ($1 - pt) }
		{ pt = $1; pb = $2 }' | median
}

# rtt_median: ping output on stdin -> median round-trip time in ms; empty without replies
rtt_median() {
	sed -n 's/.*time=\([0-9.]*\) *ms.*/\1/p' | median
}

# cpu_snapshot -> the per-core lines of /proc/stat
cpu_snapshot() { grep '^cpu[0-9]' /proc/stat; }

# busy_percent "BEFORE" "AFTER": two cpu_snapshot results -> busy % of the
# busiest core in between. One core doing all the network work is the limit
# even while the others idle.
busy_percent() {
	printf '%s\n-\n%s\n' "$1" "$2" | awk '$1 == "-" { after = 1; next }
		{ t = 0; for (i = 2; i <= NF; i++) t += $i; idle = $5 + $6 }
		!after { t1[$1] = t; i1[$1] = idle; next }
		($1 in t1) && t > t1[$1] { b = 100 - (idle - i1[$1]) * 100 / (t - t1[$1]); if (b > max) max = b }
		END { printf "%d\n", max }'
}

# rtt_replies: ping output on stdin -> number of replies
rtt_replies() { grep -c 'time=[0-9]'; }
