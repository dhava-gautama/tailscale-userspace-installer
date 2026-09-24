#!/bin/sh
#
# Smoke test for tailscale-userspace-installer.
#
# Installs into a throwaway prefix with an isolated XDG config/state home, so
# nothing in your real ~/.local, ~/.config or systemd session is touched.
# Requires network access (it downloads the Tailscale static tarball).
#
# Usage: sh tests/smoke.sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

XDG_CONFIG_HOME="$WORK/config"
XDG_STATE_HOME="$WORK/state"
PREFIX="$WORK/prefix"
STATE="$WORK/tsup-state"
export XDG_CONFIG_HOME XDG_STATE_HOME

MANAGER="$PREFIX/bin/tailscale-userspace"
SHIM="$PREFIX/bin/tailscale"

pass=0
fail=0

ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$1"
}

bad() {
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$1" >&2
}

check() { # description, command...
	desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		ok "$desc"
	else
		bad "$desc"
	fi
}

check_not() { # description, command...
	desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		bad "$desc"
	else
		ok "$desc"
	fi
}

printf '== help output ==\n'
check "install.sh --help exits 0" sh "$ROOT/install.sh" --help
check "manager help exits 0" sh "$ROOT/bin/tailscale-userspace" help

printf '\n== install (background backend, isolated prefix) ==\n'
if sh "$ROOT/install.sh" --prefix "$PREFIX" --state-dir "$STATE" --no-systemd \
	--socks5=127.0.0.1:18055 >"$WORK/install.log" 2>&1; then
	ok "install.sh completed"
else
	bad "install.sh completed"
	cat "$WORK/install.log" >&2
	exit 1
fi

check "manager installed" test -x "$MANAGER"
check "tailscale wrapper installed" test -x "$SHIM"
check "tailscaled binary installed" test -x "$(readlink -f "$PREFIX/libexec/tailscale-userspace/current")/tailscaled"
check "config written" test -f "$XDG_CONFIG_HOME/tailscale-userspace/config"
check "daemon socket created" test -S "$STATE/tailscaled.sock"

printf '\n== daemon ==\n'
check "is-running reports up" "$MANAGER" is-running
check "manager status exits 0" "$MANAGER" status
check "wrapper reaches the daemon" env TSU_NO_AUTOSTART=1 "$SHIM" version

status_out=$(env TSU_NO_AUTOSTART=1 "$SHIM" status 2>&1) || true
case "$status_out" in
	*"Logged out"*)
		ok "wrapper talks to the userspace daemon (status: Logged out)"
		;;
	*)
		bad "wrapper talks to the userspace daemon (got: $status_out)"
		;;
esac

printf '\n== wrapper auto-start ==\n'
"$MANAGER" stop >/dev/null
check_not "daemon stopped" "$MANAGER" is-running
env TSU_NO_AUTOSTART=1 "$SHIM" status >/dev/null 2>&1 || true
check_not "TSU_NO_AUTOSTART=1 leaves the daemon down" "$MANAGER" is-running
"$SHIM" status >/dev/null 2>&1 || true
check "wrapper auto-starts the daemon" "$MANAGER" is-running

printf '\n== wrapper fast path ==\n'
# The per-command overhead that was removed is the manager process itself: when
# the daemon is up the wrapper must not spawn it at all. TSU_MANAGER makes the
# manager observable without touching the installed one.
FAKE_LOG="$WORK/fake-manager.log"
cat >"$WORK/fake-manager" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >>"$FAKE_LOG"
exit 0
EOS
chmod +x "$WORK/fake-manager"
: >"$FAKE_LOG"

TSU_MANAGER="$WORK/fake-manager" "$SHIM" status >/dev/null 2>&1 || true
if [ -s "$FAKE_LOG" ]; then
	bad "wrapper does not spawn the manager while the daemon is up (called: $(cat "$FAKE_LOG"))"
else
	ok "wrapper does not spawn the manager while the daemon is up"
fi

"$MANAGER" stop >/dev/null
TSU_MANAGER="$WORK/fake-manager" "$SHIM" status >/dev/null 2>&1 || true
if [ -s "$FAKE_LOG" ]; then
	ok "wrapper spawns the manager when the daemon is down"
else
	bad "wrapper spawns the manager when the daemon is down"
fi
"$MANAGER" start >/dev/null
check "daemon is back up for the remaining checks" "$MANAGER" is-running

if command -v strace >/dev/null 2>&1; then
	calls=$(strace -f -e trace=execve "$SHIM" version 2>&1 | grep -c 'execve(')
	if [ "$calls" -le 2 ]; then
		ok "wrapper costs $calls execve on the hot path (was 5)"
	else
		bad "wrapper costs $calls execve on the hot path (expected <= 2, was 5)"
	fi
else
	printf 'skip execve count (strace not available)\n'
fi

printf '\n== idempotent re-run ==\n'
pid_before=$(pgrep -f "socket=$STATE/tailscaled.sock" 2>/dev/null | head -n 1) || true
# Replacing a file goes through a temp file and a rename, so a new inode means it
# was rewritten. mtime is too coarse to tell within the same second.
wrapper_inode_before=$(stat -c %i "$SHIM")
if sh "$ROOT/install.sh" --prefix "$PREFIX" --state-dir "$STATE" --no-systemd \
	--socks5=127.0.0.1:18055 >"$WORK/rerun.log" 2>&1; then
	ok "re-run with the same version completed"
else
	bad "re-run with the same version completed"
	cat "$WORK/rerun.log" >&2
fi
check "re-run reused the installed binaries" grep -q "Reusing the existing Tailscale" "$WORK/rerun.log"
check_not "re-run did not download the tarball" grep -q "Downloading" "$WORK/rerun.log"
wrapper_inode_after=$(stat -c %i "$SHIM")
check "re-run did not replace the identical wrapper" \
	test "$wrapper_inode_before" = "$wrapper_inode_after"
pid_after=$(pgrep -f "socket=$STATE/tailscaled.sock" 2>/dev/null | head -n 1) || true
if [ -n "$pid_before" ] && [ "$pid_before" = "$pid_after" ]; then
	ok "re-run left the running daemon alone (pid $pid_after)"
else
	bad "re-run left the running daemon alone ($pid_before -> $pid_after)"
fi

printf '\n== backend switch ==\n'
mkdir -p "$XDG_CONFIG_HOME/systemd/user"
printf '[Unit]\nDescription=stale unit from an earlier install\n' \
	>"$XDG_CONFIG_HOME/systemd/user/tailscaled-userspace.service"
sh "$ROOT/install.sh" --prefix "$PREFIX" --state-dir "$STATE" --no-systemd --no-start \
	--socks5=127.0.0.1:18055 >"$WORK/switch.log" 2>&1 || true
check_not "a stale systemd unit is removed by --no-systemd" \
	test -e "$XDG_CONFIG_HOME/systemd/user/tailscaled-userspace.service"
check "config records the background backend" \
	grep -q "^TSU_USE_SYSTEMD='no'\$" "$XDG_CONFIG_HOME/tailscale-userspace/config"

printf '\n== argument validation ==\n'
if out=$(sh "$ROOT/install.sh" --prefix "$PREFIX" --state-dir "$STATE" --no-start \
	--socks5=nonsense 2>&1); then
	bad "--socks5 without a port is rejected"
else
	case "$out" in
		*"host:port"*) ok "--socks5 without a port is rejected with a clear message" ;;
		*) bad "--socks5 without a port gives a clear message (got: $out)" ;;
	esac
fi

printf '\n== userspace networking ==\n'
# A real SOCKS5 greeting (version 5, one method: no-auth) must be answered with
# 05 00. That proves the userspace netstack is serving, not just that a port is
# open.
socks5_handshake() {
	reply=$(printf '\005\001\000' | timeout 5 nc 127.0.0.1 18055 2>/dev/null | od -An -tx1 | tr -d ' \n')
	case "$reply" in
		0500*) return 0 ;;
		*)
			printf 'unexpected SOCKS5 reply: %s\n' "${reply:-<none>}" >&2
			return 1
			;;
	esac
}

if command -v nc >/dev/null 2>&1; then
	check "SOCKS5 proxy answers the handshake" socks5_handshake
elif command -v bash >/dev/null 2>&1; then
	check "SOCKS5 port accepts connections" bash -c 'exec 3<>/dev/tcp/127.0.0.1/18055'
else
	printf 'skip SOCKS5 check (neither nc nor bash available)\n'
fi

printf '\n== lifecycle ==\n'
check "restart works" "$MANAGER" restart
check "stop works" "$MANAGER" stop
check_not "is-running reports down after stop" "$MANAGER" is-running
check "start after stop works" "$MANAGER" start

printf '\n== disabled proxy ==\n'
check "install accepts --socks5= (disabled)" sh "$ROOT/install.sh" \
	--prefix "$PREFIX" --state-dir "$STATE" --no-systemd --no-start --socks5=
check "config records the disabled proxy" \
	grep -q "^TSU_SOCKS5=''\$" "$XDG_CONFIG_HOME/tailscale-userspace/config"

printf '\n== uninstall ==\n'
check "uninstall --purge works" "$MANAGER" uninstall --purge
check_not "manager removed" test -e "$MANAGER"
check_not "wrapper removed" test -e "$SHIM"
check_not "state directory removed" test -e "$STATE"
check_not "config removed" test -e "$XDG_CONFIG_HOME/tailscale-userspace/config"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
