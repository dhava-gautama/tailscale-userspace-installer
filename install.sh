#!/bin/sh
#
# tailscale-userspace-installer
#
# Tailscale that runs entirely in userspace: no root, no sudo, no /dev/net/tun,
# no system-wide daemon, no iptables. Everything lands under $HOME.
#
# Quick start:
#   curl -fsSL https://raw.githubusercontent.com/dhava-gautama/tailscale-userspace-installer/main/install.sh | sh
#
# Join a tailnet in one shot (mirrors the official one-liner):
#   curl -fsSL .../install.sh | sh -s -- --auth-key=tskey-auth-xxxx --advertise-exit-node --ssh
#
# See --help for all flags. Flags that are not installer flags are passed
# through to `tailscale up`, so anything the official CLI accepts works here.

set -eu

REPO_SLUG="dhava-gautama/tailscale-userspace-installer"
REPO_REF="${TSU_REPO_REF:-main}"
ASSET_BASE="${TSU_INSTALL_BASE_URL:-https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}}"
PKGS_BASE="${TSU_PKGS_BASE:-https://pkgs.tailscale.com}"
PROG="tailscale-userspace-installer"

QUIET=no
say() { [ "$QUIET" = yes ] || printf '%s\n' "$*"; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<'EOF'
Usage: install.sh [installer flags] [-- tailscale-up flags...]

Installer flags:
  --prefix DIR        install prefix (default: $HOME/.local)
  --state-dir DIR     state/socket/log directory
                      (default: $XDG_STATE_HOME/tailscale-userspace)
  --version VER       Tailscale version to install (default: latest on --track)
  --track TRACK       stable (default) or unstable
  --arch ARCH         override architecture detection (amd64, arm64, arm, 386, ...)
  --socks5 ADDR       SOCKS5 listen address as host:port (default: 127.0.0.1:1055,
                      empty to disable)
  --http-proxy ADDR   HTTP proxy listen address as host:port (default: same as --socks5)
  --auth-key KEY      tailnet auth key; also read from $TS_AUTHKEY / $TS_AUTH_KEY
  --shim / --no-shim  install the `tailscale` wrapper that auto-starts the daemon
                      (default: install it)
  --systemd / --no-systemd
                      use a systemd user service when available (default: auto)
  --linger / --no-linger
                      try to enable systemd user lingering so the daemon survives
                      logout and starts at boot (default: try, ignore failure)
  --no-start          install only, do not start the daemon
  --no-up             do not run `tailscale up` even if an auth key was given
  -q, --quiet         less output
  -h, --help          this help

Anything else starting with `-` is passed to `tailscale up`, e.g.
  --advertise-exit-node --ssh --hostname=my-box --accept-dns=false
Use the `=` form for pass-through flags that take a value, or put them after
`--` to use the space-separated form.

Examples:
  sh install.sh
  sh install.sh --prefix "$HOME/.local" --track stable
  sh install.sh --auth-key=tskey-auth-xxxx --advertise-exit-node --ssh
  sh install.sh --socks5=127.0.0.1:1080 --no-shim
EOF
}

# ---------------------------------------------------------------- helpers

say_err() { printf '%s\n' "$*" >&2; }

sha256_of() {
	if have sha256sum; then
		sha256sum "$1" | cut -d' ' -f1
	elif have shasum; then
		shasum -a 256 "$1" | cut -d' ' -f1
	elif have openssl; then
		openssl dgst -sha256 "$1" | sed 's/.*= *//'
	else
		printf ''
	fi
}

install_file() { # src dst mode
	if have install; then
		install -m "$3" "$1" "$2"
	else
		cp -f "$1" "$2"
		chmod "$3" "$2"
	fi
}

# Write through a temp file and rename, so replacing a running binary works.
place_file() { # src dst mode
	dir=$(dirname "$2")
	tmp="$dir/.$(basename "$2").new.$$"
	install_file "$1" "$tmp" "$3"
	mv -f "$tmp" "$2"
}

normalize_arch() {
	case "$1" in
		amd64 | x86_64 | x64) echo amd64 ;;
		arm64 | aarch64) echo arm64 ;;
		arm | armv6 | armv6l | armv7 | armv7l | armv8l | armhf) echo arm ;;
		386 | i386 | i486 | i586 | i686 | x86) echo 386 ;;
		mipsel) echo mipsle ;;
		mips64el) echo mips64le ;;
		riscv64 | mips | mipsle | mips64 | mips64le) echo "$1" ;;
		*) echo '' ;;
	esac
}

fetch_url() { # url destination
	url="$1"
	dest="$2"
	set -- -fsSL --retry 3 --retry-delay 2 --retry-connrefused -o "$dest"
	case "$url" in
		https://*) set -- "$@" --proto '=https' ;;
	esac
	curl "$@" "$url"
}

fetch_stdout() { # url
	url="$1"
	set -- -fsSL --compressed --retry 3 --retry-delay 2 --retry-connrefused
	case "$url" in
		https://*) set -- "$@" --proto '=https' ;;
	esac
	curl "$@" "$url"
}

resolve_version() { # track
	json=$(fetch_stdout "$PKGS_BASE/$1/?mode=json") ||
		die "cannot reach $PKGS_BASE/$1 (network problem?)"
	ver=$(printf '%s' "$json" | sed -n 's/.*"TarballsVersion":[[:space:]]*"\([^"]*\)".*/\1/p')
	[ -n "$ver" ] || die "cannot determine the latest version from $PKGS_BASE/$1"
	printf '%s' "$ver"
}

check_value() { # label value
	case "$2" in
		*[[:space:]]*) die "$1 may not contain whitespace: $2" ;;
		*\'*) die "$1 may not contain a single quote: $2" ;;
	esac
}

check_path() { # label path
	case "$2" in
		/*) ;;
		*) die "$1 must be an absolute path: $2" ;;
	esac
	check_value "$1" "$2"
}

check_listener() { # label value; an empty value disables the listener
	case "$2" in
		'') return 0 ;;
		*:*) check_value "$1" "$2" ;;
		*) die "$1 must look like host:port, or be empty to disable it (got: $2)" ;;
	esac
}

sq() { printf "'%s'" "$1"; }

# ---------------------------------------------------------------- arguments

PREFIX=""
STATE_DIR=""
VERSION=""
TRACK="stable"
ARCH=""
SOCKS5="127.0.0.1:1055"
HTTP_PROXY=""
AUTH_KEY="${TS_AUTHKEY:-${TS_AUTH_KEY:-}}"
INSTALL_SHIM=yes
USE_SYSTEMD=auto
DO_LINGER=auto
DO_START=yes
DO_UP=yes
UP_ARGS=""

add_up_arg() {
	if [ -z "$UP_ARGS" ]; then
		UP_ARGS="$1"
	else
		UP_ARGS="$UP_ARGS
$1"
	fi
}

VALUE_FLAGS="--prefix --state-dir --version --track --arch --socks5 --http-proxy --auth-key"

while [ $# -gt 0 ]; do
	arg="$1"
	shift
	optval=""
	had_eq=no
	case "$arg" in
		--*=*) optval="${arg#*=}"; flag="${arg%%=*}"; had_eq=yes ;;
		*) flag="$arg" ;;
	esac

	# Installer flags given as "--flag value" consume the next word. The
	# "--flag=" form passes an explicitly empty value, which is how a listener
	# gets disabled.
	case " $VALUE_FLAGS " in
		*" $flag "*)
			if [ "$had_eq" = no ]; then
				[ $# -ge 1 ] || die "$flag requires a value"
				optval="$1"
				shift
			fi
			;;
	esac

	case "$flag" in
		-h | --help)
			usage
			exit 0
			;;
		--prefix) PREFIX="$optval" ;;
		--state-dir) STATE_DIR="$optval" ;;
		--version) VERSION="$optval" ;;
		--track) TRACK="$optval" ;;
		--arch) ARCH="$optval" ;;
		--socks5) SOCKS5="$optval" ;;
		--http-proxy) HTTP_PROXY="$optval" ;;
		--auth-key) AUTH_KEY="$optval" ;;
		--shim) INSTALL_SHIM=yes ;;
		--no-shim) INSTALL_SHIM=no ;;
		--systemd) USE_SYSTEMD=yes ;;
		--no-systemd) USE_SYSTEMD=no ;;
		--linger) DO_LINGER=yes ;;
		--no-linger) DO_LINGER=no ;;
		--no-start) DO_START=no ;;
		--no-up) DO_UP=no ;;
		-q | --quiet) QUIET=yes ;;
		--)
			while [ $# -gt 0 ]; do
				add_up_arg "$1"
				shift
			done
			;;
		-*) add_up_arg "$arg" ;;
		*) die "unexpected argument: $arg (see --help)" ;;
	esac
done

case "$TRACK" in
	stable | unstable) ;;
	*) die "--track must be stable or unstable" ;;
esac

[ "$(uname -s)" = Linux ] ||
	die "this installer targets Linux only (macOS and Windows should use the official Tailscale app)"

have curl || die "curl is required"
have tar || die "tar is required"
have mktemp || die "mktemp is required"

# ---------------------------------------------------------------- paths

: "${HOME:?HOME is not set}"
[ -n "$PREFIX" ] || PREFIX="$HOME/.local"
[ -n "$STATE_DIR" ] || STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tailscale-userspace"
[ -n "$HTTP_PROXY" ] || HTTP_PROXY="$SOCKS5"

check_path "--prefix" "$PREFIX"
check_path "--state-dir" "$STATE_DIR"
check_listener "--socks5" "$SOCKS5"
check_listener "--http-proxy" "$HTTP_PROXY"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tailscale-userspace"
CONFIG_FILE="$CONFIG_DIR/config"
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/tailscaled-userspace.service"
BIN_DIR="$PREFIX/libexec/tailscale-userspace"
SOCKET="$STATE_DIR/tailscaled.sock"
LOG_FILE="$STATE_DIR/tailscaled.log"
MANAGER="$PREFIX/bin/tailscale-userspace"

if [ "${#SOCKET}" -gt 100 ]; then
	die "socket path is too long for a unix socket (${#SOCKET} > 100): $SOCKET
use a shorter --state-dir, e.g. --state-dir /tmp/tsup-$USER"
fi

# ---------------------------------------------------------------- version

if [ -n "$ARCH" ]; then
	ARCH="$(normalize_arch "$ARCH")"
	[ -n "$ARCH" ] || die "unsupported --arch"
else
	ARCH="$(normalize_arch "$(uname -m)")"
	[ -n "$ARCH" ] || die "unsupported machine architecture: $(uname -m) (use --arch)"
fi

if [ -n "$VERSION" ]; then
	VERSION="${VERSION#v}"
else
	say "Looking up the latest Tailscale version on the $TRACK track..."
	VERSION="$(resolve_version "$TRACK")"
fi

TARBALL="tailscale_${VERSION}_${ARCH}.tgz"
URL="$PKGS_BASE/$TRACK/$TARBALL"
TAR_DIR="tailscale_${VERSION}_${ARCH}"
VERSION_DIR="$BIN_DIR/$VERSION"

# ---------------------------------------------------------------- download

TMP_DIR="$(mktemp -d)"
cleanup() { [ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM HUP

# An existing install of this exact version was checksum-verified when it was
# first unpacked, so do not download and unpack it again just to land in the
# same place.
REUSE=no
if [ -x "$VERSION_DIR/tailscaled" ] && [ -x "$VERSION_DIR/tailscale" ]; then
	if "$VERSION_DIR/tailscaled" --version 2>/dev/null | head -n 1 | grep -qx "$VERSION"; then
		REUSE=yes
		say "Reusing the existing Tailscale $VERSION install in $VERSION_DIR"
	fi
fi

if [ "$REUSE" = no ]; then
	say "Downloading $URL"
	fetch_url "$URL" "$TMP_DIR/$TARBALL" ||
		die "download failed: $URL (does version $VERSION exist on the $TRACK track for $ARCH?)"

	if fetch_url "$URL.sha256" "$TMP_DIR/$TARBALL.sha256" 2>/dev/null; then
		want=$(sed -n 's/^\([0-9a-fA-F]\{64\}\).*/\1/p' "$TMP_DIR/$TARBALL.sha256" | head -n 1 | tr 'A-F' 'a-f')
		got=$(sha256_of "$TMP_DIR/$TARBALL" | tr 'A-F' 'a-f')
		if [ -z "$want" ]; then
			warn "could not parse $TARBALL.sha256, skipping checksum verification"
		elif [ -z "$got" ]; then
			warn "no sha256 tool found, skipping checksum verification"
		elif [ "$want" != "$got" ]; then
			die "checksum mismatch for $TARBALL
  expected $want
  got      $got"
		else
			say "Checksum verified (sha256 $got)"
		fi
	else
		warn "no checksum published at $URL.sha256, skipping verification"
	fi

	tar -xzf "$TMP_DIR/$TARBALL" -C "$TMP_DIR" "$TAR_DIR/tailscale" "$TAR_DIR/tailscaled" ||
		die "could not extract $TARBALL"

	# Catch a wrong --arch here, with a clear message, rather than letting the
	# daemon fail to start later.
	got_ver=$("$TMP_DIR/$TAR_DIR/tailscaled" --version 2>/dev/null | head -n 1) || got_ver=""
	if [ "$got_ver" != "$VERSION" ]; then
		die "the downloaded tailscaled reports version '${got_ver:-none}', expected $VERSION
  (is --arch $ARCH right for this machine?)"
	fi
fi

# ---------------------------------------------------------------- install

say "Installing Tailscale $VERSION ($ARCH) into $VERSION_DIR"
mkdir -p "$VERSION_DIR" "$PREFIX/bin" "$STATE_DIR" "$CONFIG_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

if [ "$REUSE" = no ]; then
	place_file "$TMP_DIR/$TAR_DIR/tailscale" "$VERSION_DIR/tailscale" 0755
	place_file "$TMP_DIR/$TAR_DIR/tailscaled" "$VERSION_DIR/tailscaled" 0755
fi
ln -sfn "$VERSION" "$BIN_DIR/current"

# The manager and the `tailscale` wrapper come from this repo. When install.sh
# is run from a checkout, use the local copies; otherwise fetch them.
LOCAL_DIR=""
if [ -f "$0" ] && [ -f "$(dirname "$0")/install.sh" ] && [ -d "$(dirname "$0")/bin" ]; then
	LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

fetch_asset() { # repo path, destination, mode
	asset_src=""
	if [ -n "$LOCAL_DIR" ] && [ -f "$LOCAL_DIR/$1" ]; then
		asset_src="$LOCAL_DIR/$1"
	else
		fetch_url "$ASSET_BASE/$1" "$TMP_DIR/asset" ||
			die "could not download $ASSET_BASE/$1"
		asset_src="$TMP_DIR/asset"
	fi
	# Leave an identical file alone, so a re-run touches nothing.
	if [ -f "$2" ] && cmp -s "$asset_src" "$2"; then
		return 0
	fi
	place_file "$asset_src" "$2" "$3"
}

fetch_asset "bin/tailscale-userspace" "$MANAGER" 0755
if [ "$INSTALL_SHIM" = yes ]; then
	if [ -e "$PREFIX/bin/tailscale" ] && ! grep -q tailscale-userspace "$PREFIX/bin/tailscale" 2>/dev/null; then
		warn "$PREFIX/bin/tailscale already exists and is not this project's wrapper; replacing it
  (re-run with --no-shim if you meant to keep it)"
	fi
	fetch_asset "bin/tailscale" "$PREFIX/bin/tailscale" 0755
fi

# What the daemon was started with, so an unchanged re-run can leave it running
# instead of dropping every live tailnet connection.
OLD_BIN_DIR=""
OLD_SOCKS5=""
OLD_HTTP_PROXY=""
OLD_STATE_DIR=""
OLD_USE_SYSTEMD=""
if [ -f "$CONFIG_FILE" ]; then
	# shellcheck source=/dev/null
	. "$CONFIG_FILE"
	OLD_BIN_DIR="${TSU_BIN_DIR:-}"
	OLD_SOCKS5="${TSU_SOCKS5:-}"
	OLD_HTTP_PROXY="${TSU_HTTP_PROXY:-}"
	OLD_STATE_DIR="${TSU_STATE_DIR:-}"
	OLD_USE_SYSTEMD="${TSU_USE_SYSTEMD:-}"
fi

{
	printf '# Written by %s on %s\n' "$PROG" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	printf 'TSU_PREFIX=%s\n' "$(sq "$PREFIX")"
	printf 'TSU_VERSION=%s\n' "$(sq "$VERSION")"
	printf 'TSU_BIN_DIR=%s\n' "$(sq "$VERSION_DIR")"
	printf 'TSU_STATE_DIR=%s\n' "$(sq "$STATE_DIR")"
	printf 'TSU_SOCKET=%s\n' "$(sq "$SOCKET")"
	printf 'TSU_LOG=%s\n' "$(sq "$LOG_FILE")"
	printf 'TSU_SOCKS5=%s\n' "$(sq "$SOCKS5")"
	printf 'TSU_HTTP_PROXY=%s\n' "$(sq "$HTTP_PROXY")"
	printf 'TSU_USE_SYSTEMD=%s\n' "$(sq "$USE_SYSTEMD")"
	printf 'TSU_INSTALL_SHIM=%s\n' "$(sq "$INSTALL_SHIM")"
} >"$CONFIG_FILE"

say "Wrote $CONFIG_FILE"

# Switching away from the systemd backend: a left-over unit would keep a daemon
# alive, fight the background one for the socket, and Restart=on-failure would
# revive it.
if [ "$USE_SYSTEMD" = no ] && [ -f "$UNIT_FILE" ]; then
	if have systemctl && [ -d /run/systemd/system ]; then
		systemctl --user disable --now tailscaled-userspace.service 2>/dev/null || true
	fi
	rm -f "$UNIT_FILE"
	say "Removed the systemd user unit (--no-systemd)."
fi

# ---------------------------------------------------------------- start

DAEMON_SETTINGS_CHANGED=no
if [ "$OLD_BIN_DIR" != "$VERSION_DIR" ] ||
	[ "$OLD_SOCKS5" != "$SOCKS5" ] ||
	[ "$OLD_HTTP_PROXY" != "$HTTP_PROXY" ] ||
	[ "$OLD_STATE_DIR" != "$STATE_DIR" ] ||
	[ "$OLD_USE_SYSTEMD" != "$USE_SYSTEMD" ]; then
	DAEMON_SETTINGS_CHANGED=yes
fi

if [ "$DO_START" = no ]; then
	say "Skipping daemon start (--no-start). Start it later with: $MANAGER start"
elif [ "$DAEMON_SETTINGS_CHANGED" = no ] && "$MANAGER" is-running >/dev/null 2>&1; then
	# Refresh the systemd unit if it drifted, but leave the daemon running.
	"$MANAGER" start >/dev/null 2>&1 || true
	say "Daemon already running with the same settings; left it alone."
else
	say "Starting the userspace daemon..."
	"$MANAGER" restart || die "the daemon failed to start; check: $MANAGER logs"
fi

if [ "$DO_LINGER" != no ] && have loginctl && [ -d /run/systemd/system ]; then
	linger=no
	if loginctl show-user "$(id -un)" 2>/dev/null | grep -q '^Linger=yes$'; then
		linger=yes
	fi
	if [ "$linger" = no ] && [ "$DO_LINGER" = yes ]; then
		if loginctl enable-linger "$(id -un)" 2>/dev/null; then
			say "Enabled systemd user lingering: the daemon starts at boot, without a login."
		else
			warn "could not enable lingering; the daemon stops when you log out
  (run this yourself if you want it to survive: sudo loginctl enable-linger $(id -un))"
		fi
	fi
fi

# ---------------------------------------------------------------- up

if [ -n "$AUTH_KEY" ] && [ "$DO_UP" = yes ] && [ "$DO_START" = yes ]; then
	say "Joining the tailnet..."
	set -- "$MANAGER" up
	if [ -n "$UP_ARGS" ]; then
		old_ifs=$IFS
		IFS='
'
		for up_arg in $UP_ARGS; do
			set -- "$@" "$up_arg"
		done
		IFS=$old_ifs
	fi
	case "$AUTH_KEY" in
		file:*)
			set -- "$@" "--auth-key=$AUTH_KEY"
			;;
		*)
			# The tailscale CLI has no TS_AUTHKEY environment variable (that is
			# a container-entrypoint convention), and a key on the command line
			# shows up in `ps`. Hand it over as a file instead: --auth-key
			# accepts a file:<path> value.
			KEY_FILE="$TMP_DIR/authkey"
			(umask 077 && printf '%s' "$AUTH_KEY" >"$KEY_FILE")
			set -- "$@" "--auth-key=file:$KEY_FILE"
			;;
	esac
	"$@" || die "tailscale up failed (see the output above)"
elif [ -n "$AUTH_KEY" ] && [ "$DO_UP" = yes ]; then
	warn "an auth key was given but --no-start was used; join with:
  $MANAGER up --auth-key=tskey-auth-...   (or: TS_AUTHKEY=... $MANAGER up)"
fi

# ---------------------------------------------------------------- summary

case ":${PATH}:" in
	*":$PREFIX/bin:"*) ;;
	*) warn "$PREFIX/bin is not in your PATH; add it, e.g.
  export PATH=\"$PREFIX/bin:\$PATH\"" ;;
esac

if [ "$INSTALL_SHIM" = yes ]; then
	other=$(command -v tailscale 2>/dev/null || true)
	case "$other" in
		"" | "$PREFIX/bin/tailscale") ;;
		*) warn "another tailscale is on your PATH at $other; it will win unless $PREFIX/bin comes first" ;;
	esac
fi

say ""
say "Tailscale $VERSION installed (userspace mode, no root, no TUN device)."
say ""
say "  daemon       $MANAGER (status | logs | stop | uninstall)"
say "  binaries     $VERSION_DIR"
say "  state        $STATE_DIR"
say "  SOCKS5/HTTP  ${SOCKS5:-disabled}"
say ""
say "Next steps:"
say "  tailscale status"
say "  tailscale up --auth-key=tskey-auth-... --advertise-exit-node --ssh"
say "  export ALL_PROXY=socks5://${SOCKS5:-127.0.0.1:1055}/"
say ""
say "Userspace mode has no TUN device, so programs must use the proxy above."
say "See the README for what that means in practice."
