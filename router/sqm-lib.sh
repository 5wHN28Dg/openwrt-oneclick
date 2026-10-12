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

# busy_percent "BEFORE" "AFTER": two first lines of /proc/stat -> CPU busy % in between
busy_percent() {
	printf '%s\n%s\n' "$1" "$2" | awk '{ t = 0; for (i = 2; i <= NF; i++) t += $i; idle = $5 + $6 }
		NR == 1 { t1 = t; i1 = idle } NR == 2 { if (t > t1) printf "%d\n", 100 - (idle - i1) * 100 / (t - t1); else print 0 }'
}
