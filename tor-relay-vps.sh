#!/usr/bin/env bash
# tor-relay-vps.sh - run a Tor middle / guard relay on an Ubuntu / Debian VPS. NEVER an exit relay.
#
# What it does:
#   1. Adds the official Tor Project apt repository (deb.torproject.org); its signing key is checked
#      against the pinned fingerprint before it is trusted.
#   2. Installs tor and writes /etc/tor/torrc for a NON-EXIT relay (ExitRelay 0, ExitPolicy reject *:*):
#      your server only passes encrypted traffic between Tor relays; it never connects to websites
#      for Tor users, so abuse complaints about "your IP attacked my site" do not apply to it.
#   3. Checks the config with 'tor --verify-config' before it replaces anything.
#   4. Opens the ORPort in ufw if ufw is active, enables and starts tor@default.
#   5. Prints the relay fingerprint and where to watch it on metrics.torproject.org.
#   Running it again is safe: the relay identity keys in /var/lib/tor/keys are never touched.
#
# Usage:  sudo bash tor-relay-vps.sh --nickname NAME --contact "you@example.com" [--orport 9001]
#                                    [--bandwidth-rate "10 MB"] [--bandwidth-burst "20 MB"] [--no-publish] [--yes]
#   --contact is required and PUBLIC: the Tor Project uses it to reach you if your relay misbehaves or is
#             out of date. A dedicated e-mail address is fine.
#   --bandwidth-rate / --bandwidth-burst  limit relay traffic, e.g. "5 MB" (bytes per second), "100 Mbits"
#   --no-publish  run the relay but do not announce it to the Tor network (for testing)
# Tested on Ubuntu 22.04 and 24.04 (see .github/workflows/test.yml); written for Debian 12 / 13 too.
# License: MIT. Maintained by the PhantomVPS team - https://phantomvps.com
set -euo pipefail

REPO="https://deb.torproject.org/torproject.org"
KEY_FPR="A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89"   # deb.torproject.org archive signing key
KEYRING=/usr/share/keyrings/deb.torproject.org-keyring.gpg
TORRC=/etc/tor/torrc

NICK=""; CONTACT=""; ORPORT=9001; RATE=""; BURST=""; NO_PUBLISH=0; ASSUME_YES=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }
need_arg() { [ -n "${2:-}" ] || die "$1 needs a value (see --help)"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --nickname) need_arg "$@"; NICK="$2"; shift 2 ;;
    --contact) need_arg "$@"; CONTACT="$2"; shift 2 ;;
    --orport) need_arg "$@"; ORPORT="$2"; shift 2 ;;
    --bandwidth-rate) need_arg "$@"; RATE="$2"; shift 2 ;;
    --bandwidth-burst) need_arg "$@"; BURST="$2"; shift 2 ;;
    --no-publish) NO_PUBLISH=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# ---- input validation (before anything is changed) ----
[ -n "$NICK" ] || die "--nickname is required (1-19 letters and digits, e.g. MyRelay01)"
[[ "$NICK" =~ ^[A-Za-z0-9]{1,19}$ ]] || die "bad --nickname (1-19 letters and digits only): $NICK"
[ -n "$CONTACT" ] || die "--contact is required: the Tor Project needs a way to reach relay operators (it is published)"
[[ "$CONTACT" =~ ^[[:print:]]{3,200}$ ]] && [[ "$CONTACT" != *'#'* ]] && [[ "$CONTACT" != *'\'* ]] \
  || die "bad --contact (3-200 printable characters, no # or backslash)"
[[ "$ORPORT" =~ ^[0-9]+$ ]] && [ "$ORPORT" -ge 1 ] && [ "$ORPORT" -le 65535 ] || die "bad --orport: $ORPORT"
norm_bw() {   # "10 MB" / "10MB" / "100 Mbits" -> "10 MB" ; empty stays empty
  [ -z "$1" ] && return 0
  [[ "$1" =~ ^([0-9]+)\ ?([KkMmGgTt](B|Bytes|bytes|bits|Bits))$ ]] || die "bad bandwidth value: $1 (use e.g. \"10 MB\" or \"100 Mbits\")"
  [ "${BASH_REMATCH[1]}" -gt 0 ] || die "bandwidth must be more than 0: $1"
  echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
}
RATE="$(norm_bw "$RATE")"; BURST="$(norm_bw "$BURST")"

[ "$(id -u)" -eq 0 ] || die "run as root (sudo bash $0)"
[ -r /etc/os-release ] || die "cannot read /etc/os-release"
OS_ID="$(. /etc/os-release && echo "${ID:-}")"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
case "$OS_ID" in ubuntu|debian) ;; *) die "only Ubuntu and Debian are supported (found: ${OS_ID:-unknown})" ;; esac
[ -n "$CODENAME" ] || die "cannot find the release codename in /etc/os-release"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64|arm64) ;; *) die "the Tor Project repository has packages for amd64 and arm64 only (found: $ARCH)" ;; esac

echo "Plan: non-exit Tor relay '$NICK', ORPort $ORPORT/tcp, contact '$CONTACT'"
echo "      bandwidth rate: ${RATE:-unlimited}, burst: ${BURST:-unlimited}, announce to the network: $((1-NO_PUBLISH))"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Continue? [y/N] " a; case "$a" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
fi

export DEBIAN_FRONTEND=noninteractive
info "Installing tools (curl, gnupg)"
apt-get update -q
apt-get -y -q install curl ca-certificates gnupg

WORK="$(mktemp -d)"; export GNUPGHOME="$WORK/gnupg"
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
install -d -m 700 "$GNUPGHOME"

curl -fsS --proto '=https' --max-time 20 -o /dev/null "$REPO/dists/$CODENAME/Release" \
  || die "the Tor Project repository has no packages for '$CODENAME' (see https://support.torproject.org/apt/)"

info "Adding the Tor Project apt repository (key $KEY_FPR)"
curl -fsSL --proto '=https' --retry 3 -o "$WORK/tor.asc" "$REPO/$KEY_FPR.asc"
gpg --batch --quiet --import "$WORK/tor.asc" 2>/dev/null
gpg --batch --with-colons --fingerprint "$KEY_FPR" 2>/dev/null | grep "^fpr:::::::::$KEY_FPR:" >/dev/null \
  || die "the downloaded key does not have the expected fingerprint $KEY_FPR"
gpg --batch --yes --export "$KEY_FPR" > "$WORK/keyring.gpg"
if [ ! -s "$KEYRING" ]; then
  install -m 644 "$WORK/keyring.gpg" "$KEYRING"   # later kept up to date by the deb.torproject.org-keyring package
fi
printf 'deb [arch=%s signed-by=%s] %s %s main\n' "$ARCH" "$KEYRING" "$REPO" "$CODENAME" > "$WORK/tor.list"
cmp -s "$WORK/tor.list" /etc/apt/sources.list.d/tor.list 2>/dev/null || install -m 644 "$WORK/tor.list" /etc/apt/sources.list.d/tor.list

info "Installing tor"
apt-get update -q
apt-get -y -q install tor deb.torproject.org-keyring
tor --version | awk 'NR == 1'

new_torrc="$WORK/torrc"
{
  echo "## Managed by tor-relay-vps.sh - re-run the script to change these settings."
  echo "## NON-EXIT relay: it relays encrypted traffic between Tor relays and never exits to the internet."
  echo "Nickname $NICK"
  echo "ContactInfo $CONTACT"
  echo "ORPort $ORPORT"
  echo "ExitRelay 0"
  echo "ExitPolicy reject *:*"
  echo "SocksPort 0"
  [ -n "$RATE" ] && echo "RelayBandwidthRate $RATE"
  [ -n "$BURST" ] && echo "RelayBandwidthBurst $BURST"
  [ "$NO_PUBLISH" -eq 1 ] && echo "PublishServerDescriptor 0"
  true
} > "$new_torrc"

DEFAULTS=/usr/share/tor/tor-service-defaults-torrc
verify=(tor --verify-config --RunAsDaemon 0 -f "$new_torrc"); [ -f "$DEFAULTS" ] && verify+=(--defaults-torrc "$DEFAULTS")
"${verify[@]}" >"$WORK/verify.log" 2>&1 || { cat "$WORK/verify.log" >&2; die "tor rejected the new config; nothing was changed"; }
grep -qx 'ExitPolicy reject \*:\*' "$new_torrc" || die "internal error: exit policy missing"

CHANGED=0
if cmp -s "$new_torrc" "$TORRC" 2>/dev/null; then
  info "$TORRC unchanged"
else
  if [ -f "$TORRC" ] && ! grep -q '^## Managed by tor-relay-vps.sh' "$TORRC" && [ ! -f "$TORRC.before-tor-relay-vps" ]; then
    cp -p "$TORRC" "$TORRC.before-tor-relay-vps"; info "Saved the old config as $TORRC.before-tor-relay-vps"
  fi
  install -m 644 "$new_torrc" "$TORRC"; CHANGED=1; info "Wrote $TORRC"
fi

if ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then   # no -q: avoids SIGPIPE + pipefail
  info "ufw is active: allowing $ORPORT/tcp"
  ufw allow "$ORPORT/tcp" comment 'tor relay'
fi

systemctl enable tor >/dev/null 2>&1 || true
systemctl enable tor@default >/dev/null 2>&1 || true
if ! systemctl is-active --quiet tor@default; then
  info "Starting tor@default"; systemctl start tor@default
elif [ "$CHANGED" -eq 1 ]; then
  info "Restarting tor@default (new settings)"; systemctl restart tor@default
else
  info "tor@default is running, nothing to restart"
fi
sleep 2
systemctl is-active --quiet tor@default || { journalctl -u tor@default -n 30 --no-pager >&2 || true; die "tor@default did not start"; }

FPR=""
for _ in $(seq 1 30); do
  [ -s /var/lib/tor/fingerprint ] && { FPR="$(awk '{print $2}' /var/lib/tor/fingerprint)"; break; }
  sleep 1
done

echo
info "Done. Relay '$NICK' is running${FPR:+, fingerprint $FPR}."
info "Logs:        journalctl -u tor@default -f   (wait for 'Self-testing indicates your ORPort is reachable')"
if [ "$NO_PUBLISH" -eq 1 ]; then
  info "--no-publish: the relay is NOT announced to the Tor network."
else
  info "Metrics:     https://metrics.torproject.org/rs.html#search/${FPR:-$NICK}  (shows up after about 3 hours)"
  info "New relays get little traffic for the first weeks; the Guard flag usually comes after 8+ days of stable uptime."
fi
info "Back up /var/lib/tor/keys: it is your relay's identity."
