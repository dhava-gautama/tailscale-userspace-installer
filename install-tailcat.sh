#!/bin/sh
#
# install-tailcat.sh — install Tailcat (https://github.com/tailscale/tailcat)
# without root, next to the tailscale-userspace binaries.
#
# Tailcat is Tailscale's netcat-style tool: point-to-point WireGuard-encrypted
# pipes between two machines, with DERP as the bootstrap relay. It has NO
# control plane and NO daemon — it does not join a tailnet, touch routing, or
# need a TUN device. One side runs `tailcat` and prints a short capability
# address; the other side connects by passing that address.
#
# Standalone use:
#   curl -fsSL https://raw.githubusercontent.com/dhava-gautama/tailscale-userspace-installer/main/install-tailcat.sh | sh
#
# Called by install.sh when it is run with --tailcat.

set -eu

PROG="install-tailcat"
REPO_SLUG="${TSU_TAILCAT_REPO:-tailscale/tailcat}"
DL_BASE="${TSU_TAILCAT_DL:-https://github.com/${REPO_SLUG}/releases/download}"

QUIET=no
say() { [ "$QUIET" = yes ] || printf '%s\n' "$*"; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<'EOF'
Usage: install-tailcat.sh [flags]

  --prefix DIR          install prefix (default: $HOME/.local)
  --version TAG         tailcat release tag, e.g. v0.7.0 (default: latest)
  --repo OWNER/NAME     GitHub repo to download from (default: tailscale/tailcat)
  -q, --quiet           less output
  -h, --help            this help

Installs the static `tailcat` binary into
  $PREFIX/libexec/tailscale-userspace/tailcat/<tag>/tailcat
with $PREFIX/bin/tailcat pointing at it. Published checksums are mandatory:
a release without a matching checksums.txt entry is rejected.

Tailcat needs no account and no daemon: run `tailcat` on one machine, it prints
a `tc...` address; on the other run `echo hi | tailcat <address>`.
EOF
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

place_file() { # src dst mode
	dir=$(dirname "$2")
	tmp="$dir/.$(basename "$2").new.$$"
	install_file "$1" "$tmp" "$3"
	mv -f "$tmp" "$2"
}

resolve_version() {
	loc=$(curl -fsSI "https://github.com/${REPO_SLUG}/releases/latest" 2>/dev/null |
		sed -n 's/^[Ll]ocation:[[:space:]]*.*\/tag\/\(v[0-9][^[:space:]]*\).*/\1/p' | head -n 1)
	[ -n "$loc" ] || die "cannot determine the latest tailcat release
  (pass --version explicitly, or check https://github.com/${REPO_SLUG}/releases)"
	printf '%s' "$loc"
}

# ---------------------------------------------------------------- arguments

PREFIX=""
VERSION=""
while [ $# -gt 0 ]; do
	case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		--prefix)
			[ $# -ge 2 ] || die "--prefix requires a value"
			PREFIX="$2"
			shift
			;;
		--prefix=*)
			PREFIX="${1#*=}"
			;;
		--version)
			[ $# -ge 2 ] || die "--version requires a value"
			VERSION="$2"
			shift
			;;
		--version=*)
			VERSION="${1#*=}"
			;;
		--repo)
			[ $# -ge 2 ] || die "--repo requires a value"
			REPO_SLUG="$2"
			DL_BASE="https://github.com/${REPO_SLUG}/releases/download"
			shift
			;;
		--repo=*)
			REPO_SLUG="${1#*=}"
			DL_BASE="https://github.com/${REPO_SLUG}/releases/download"
			;;
		-q | --quiet) QUIET=yes ;;
		*) die "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

: "${HOME:?HOME is not set}"
[ -n "$PREFIX" ] || PREFIX="$HOME/.local"
case "$PREFIX" in
	/*) ;;
	*) die "--prefix must be an absolute path: $PREFIX" ;;
esac
case "$PREFIX" in
	*[[:space:]]* | *\'*) die "--prefix may not contain whitespace or quotes: $PREFIX" ;;
esac

have curl || die "curl is required"
have tar || die "tar is required"
have mktemp || die "mktemp is required"

[ "$(uname -s)" = Linux ] ||
	die "tailcat prebuilt Linux binaries only; on macOS use Homebrew, on Windows Scoop
  (see https://github.com/${REPO_SLUG}#install)"

# tailcat releases: amd64, arm64, armv7 — that is all.
case "$(uname -m)" in
	x86_64 | amd64) TC_ARCH=amd64 ;;
	aarch64 | arm64) TC_ARCH=arm64 ;;
	armv7l | armv7 | armhf) TC_ARCH=armv7 ;;
	*)
		die "no prebuilt tailcat for $(uname -m)
  (releases ship amd64, arm64 and armv7; otherwise build from source, see the repo README)"
		;;
esac

if [ -n "$VERSION" ]; then
	case "$VERSION" in
		v*) ;;
		*) VERSION="v$VERSION" ;;
	esac
else
	say "Looking up the latest tailcat release..."
	VERSION=$(resolve_version)
fi

TARBALL="tailcat_${VERSION#v}_linux_${TC_ARCH}.tar.gz"
URL="$DL_BASE/$VERSION/$TARBALL"
BINROOT="$PREFIX/libexec/tailscale-userspace/tailcat"
DEST_DIR="$BINROOT/$VERSION"

# Already installed at this exact tag? The binary's --version is the truth.
if [ -x "$DEST_DIR/tailcat" ] &&
	[ "$("$DEST_DIR/tailcat" --version 2>/dev/null || true)" = "$VERSION" ]; then
	say "Reusing the existing tailcat $VERSION install in $DEST_DIR"
else
	TMP_DIR="$(mktemp -d)"
	cleanup() { [ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"; }
	trap cleanup EXIT INT TERM HUP

	say "Downloading $URL"
	fetch_url "$URL" "$TMP_DIR/$TARBALL" ||
		die "download failed: $URL (does tag $VERSION exist, and is there a linux_${TC_ARCH} build?)"

	# tailcat publishes checksums.txt in every release; verification is not
	# optional here, unlike the tailscale tarball's sidecar.
	CHECKS="$TMP_DIR/checksums.txt"
	fetch_url "$DL_BASE/$VERSION/checksums.txt" "$CHECKS" ||
		die "could not download $DL_BASE/$VERSION/checksums.txt"
	want=$(awk -v n="$TARBALL" '$2 == n { print $1 }' "$CHECKS")
	[ -n "$want" ] || die "$TARBALL is not listed in checksums.txt; refusing to install"
	got=$(sha256_of "$TMP_DIR/$TARBALL" | tr 'A-F' 'a-f')
	want=$(printf '%s' "$want" | tr 'A-F' 'a-f')
	[ -n "$got" ] || die "no sha256 tool found (sha256sum, shasum or openssl); refusing to install"
	[ "$want" = "$got" ] ||
		die "checksum mismatch for $TARBALL
  expected $want
  got      $got"
	say "Checksum verified (sha256 $got)"

	tar -xzf "$TMP_DIR/$TARBALL" -C "$TMP_DIR" ||
		die "could not extract $TARBALL"
	[ -f "$TMP_DIR/tailcat" ] || die "the tarball did not contain a tailcat binary"

	bin_ver=$("$TMP_DIR/tailcat" --version 2>/dev/null || true)
	[ "$bin_ver" = "$VERSION" ] ||
		die "the extracted tailcat reports '${bin_ver:-none}', expected $VERSION"

	say "Installing tailcat $VERSION into $DEST_DIR"
	mkdir -p "$DEST_DIR" "$PREFIX/bin"
	place_file "$TMP_DIR/tailcat" "$DEST_DIR/tailcat" 0755
	if [ -f "$TMP_DIR/LICENSE" ]; then
		place_file "$TMP_DIR/LICENSE" "$DEST_DIR/LICENSE" 0644
	fi
fi

ln -sfn "$VERSION" "$BINROOT/current"
place_symlink() {
	tmp_link="$PREFIX/bin/.tailcat.new.$$"
	ln -sfn "$BINROOT/current/tailcat" "$tmp_link"
	mv -f "$tmp_link" "$PREFIX/bin/tailcat"
}
place_symlink

case ":${PATH}:" in
	*":$PREFIX/bin:"*) ;;
	*) warn "$PREFIX/bin is not in your PATH; add it, e.g.
  export PATH=\"$PREFIX/bin:\$PATH\"" ;;
esac

say ""
say "tailcat $VERSION installed (no account, no daemon, no root needed)."
say ""
say "  binary   $PREFIX/bin/tailcat"
say ""
say "Try it between two machines (or two terminals):"
say "  tailcat                       # prints a tc... address, waits"
say "  echo hello | tailcat <tc...>  # from the other side"
say ""
say "Serve and forward local ports:"
say "  tailcat serve 8080            # on the server side"
say "  tailcat forward <tc...> 18080:8080   # on the client side"
say ""
say "Note: tailcat does NOT join a tailnet. Connections are made by exchanging"
say "the tc... address out of band; it is end-to-end WireGuard-encrypted either way."
