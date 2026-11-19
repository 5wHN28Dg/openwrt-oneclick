# Builds the router's Tailscale on the laptop (POSIX sh, sourced by setup.sh).
#
# OpenWrt's tailscale package is the full program: 26 MB of storage and
# about 50 MB of memory on a 256 MB router. Tailscale can leave features out
# at build time; this build keeps only what the router needs (routing, NAT
# traversal, UDP to peers, advertising routes, the command-line tool) and
# measured 13 MB (about 5 MB compressed on flash) and 21-26 MB of memory.
# See README (Tailscale).
#
# The source is Tailscale's release tag, checked against its commit; the Go
# compiler comes from Tailscale's own ./tool/go (downloaded into
# ~/.cache/tsgo on first use). Builds are cached per version and processor.
# To update: change TS_VERSION and TS_COMMIT (git ls-remote --tags
# https://github.com/tailscale/tailscale "v<version>^{}").

TS_VERSION=1.104.7
TS_COMMIT=cbc74fe48ef1b1649f69a4d9a602319427e25102
# ipnbus: without it "tailscale up" returns before logging in.
TS_FEATURES=osrouter,nattraversal,udptransport,advertiseroutes,cli,ipnbus

# ts_goarch OPENWRT-ARCH -> "GOARCH [GOARM-or-GOMIPS]"; fails for others.
# OPENWRT-ARCH is the package architecture (/etc/apk/arch), e.g.
# aarch64_cortex-a53, mipsel_24kc, arm_cortex-a7_neon-vfpv4, x86_64.
ts_goarch() {
	case $1 in
		aarch64*) echo arm64 ;;
		x86_64) echo amd64 ;;
		i386*) echo 386 ;;
		arm_cortex-a*|arm_*neon*|arm_*vfp*) echo 'arm 7' ;;
		arm_*) echo 'arm 5' ;;
		mipsel_*) echo 'mipsle softfloat' ;;
		mips_*) echo 'mips softfloat' ;;
		mips64el_*) echo mips64le ;;
		mips64_*) echo mips64 ;;
		riscv64*) echo riscv64 ;;
		*) return 1 ;;
	esac
}

# ts_build OPENWRT-ARCH -> prints the built tailscaled's path (progress on stderr)
ts_build() {
	_ga=$(ts_goarch "$1") || { echo "no Tailscale build for the router's processor ($1)" >&2; return 1; }
	_goarch=${_ga% *} _sub=''; [ "$_ga" = "$_goarch" ] || _sub=${_ga#* }
	_dir=${XDG_CACHE_HOME:-$HOME/.cache}/openwrt-oneclick/tailscale
	_out=$_dir/tailscaled-$TS_VERSION-$_goarch${_sub:+-$_sub}
	[ -x "$_out" ] && { echo "$_out"; return 0; }
	for _t in git curl tar; do
		command -v $_t >/dev/null || { echo "building Tailscale needs $_t" >&2; return 1; }
	done
	_src=$_dir/src-$TS_VERSION
	mkdir -p "$_dir"
	if [ "$(git -C "$_src" rev-parse HEAD 2>/dev/null)" != "$TS_COMMIT" ]; then
		rm -rf "$_src"
		echo "Downloading Tailscale $TS_VERSION source ..." >&2
		git -c advice.detachedHead=false clone -q --depth 1 --branch "v$TS_VERSION" \
			https://github.com/tailscale/tailscale.git "$_src" >&2 || { rm -rf "$_src"; return 1; }
		if [ "$(git -C "$_src" rev-parse HEAD)" != "$TS_COMMIT" ]; then
			echo "Tailscale's tag v$TS_VERSION is not commit $TS_COMMIT: not building it" >&2
			rm -rf "$_src"; return 1
		fi
	fi
	echo "Building Tailscale $TS_VERSION for $1 (first time: downloads Go, 2-5 minutes) ..." >&2
	(
		cd "$_src" || exit 1
		export TS_USE_TOOLCHAIN=1 CGO_ENABLED=0
		_tags=$(GOOS='' GOARCH='' ./tool/go run ./cmd/featuretags --min --add="$TS_FEATURES") || exit 1
		case $_goarch in arm) export GOARM="$_sub" ;; mips|mipsle) export GOMIPS="$_sub" ;; esac
		GOOS=linux GOARCH=$_goarch TAGS="$_tags,ts_include_cli" ./build_dist.sh --strip -o "$_out.tmp" ./cmd/tailscaled
	) >&2 || { rm -f "$_out.tmp"; echo "Tailscale build failed" >&2; return 1; }
	mv "$_out.tmp" "$_out" && echo "$_out"
}
