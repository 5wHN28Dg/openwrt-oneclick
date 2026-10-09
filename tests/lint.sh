#!/bin/sh
# Lint every shell script with ShellCheck (errors and warnings; its notes and
# style hints flag idioms used on purpose here, e.g. `ok || bad` in tests and
# single-quoted commands that run on the router). Usage: tests/lint.sh

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
command -v shellcheck >/dev/null || { echo "shellcheck not found (https://www.shellcheck.net)"; exit 2; }
cd "$HERE" || exit 2
# Every file starting with a sh shebang, plus the sourced library. Bundled
# third-party code (router/vendor/) is left as its authors wrote it.
files=$(git ls-files | grep -v '^router/vendor/' | while read -r f; do
	[ -f "$f" ] && head -n 1 "$f" | grep -qE '^#!.*/(env )?(ba)?sh( |$)' && echo "$f"
done)
# shellcheck disable=SC2086  # one file name per word
shellcheck --shell=sh --severity=warning --external-sources lib/laptop.sh $files && echo "shellcheck: no warnings"
