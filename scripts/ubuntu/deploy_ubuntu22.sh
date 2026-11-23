#!/usr/bin/env bash
# Copyright © 2026 POPOPX Chat
# SPDX-License-Identifier: AGPL-3.0-only
#
# Install or upgrade the POPOPX relay roles on Ubuntu 22.04.
#
# Idempotent: a node that has never been touched gets initialised, a node that
# already runs a role only gets its binary and its unit replaced. This is not
# cosmetic caution - smp-server init and xftp-server init both call
# clearDirIfExists on their configuration and log directories, so re-running
# init on a live relay would delete ca.key and change the fingerprint that every
# existing queue and file depends on. Upgrade therefore never runs init, and it
# re-checks the identity files afterwards to prove nothing was replaced.

set -Eeuo pipefail

REPO="${POPOPX_REPO:-popopx-chat/popopxmq}"
DL_BASE="https://github.com/${REPO}/releases"
API_BASE="https://api.github.com/repos/${REPO}/releases"
SOURCE_URI="https://github.com/${REPO}"

BIN_DIR="/usr/local/bin"
RUN_USER="popopx"
RUN_GROUP="popopx"

MODE="prebuilt"
TAG="latest"
ROLES_CSV="all"
EXPECTED_SHA=""
FQDN=""
SMP_PASSWORD=""
XFTP_PATH="/srv/xftp"
XFTP_QUOTA="100gb"
SIGN_ALGORITHM="ED448"
PORT_SMP=5223
PORT_XFTP=8443
PORT_NTF=5226
PORT_RELAY=5227
WEB_PORT_SMP=8000
WEB_PORT_RELAY=8001
WEB_PORT_XFTP=8002
WITH_TOR=0
WITH_CADDY=1
WITH_UFW=1
WITH_SYSCTL=1
DRY_RUN=0
JSON_OUT=""
ARCH_OVERRIDE=""
KEEP_TMP=0

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: deploy_ubuntu22.sh [OPTIONS]

Installs or upgrades one or more POPOPX relay roles on Ubuntu 22.04 as systemd
services, then prints the real-fingerprint address of each role for registration
in popopx-server-up-bot/cluster.json.

First run:   creates the non-login system user popopx, initialises each enabled
             role (its own CA key, TLS credentials and .ini), applies kernel and
             firewall settings, installs units, starts the services.
Later runs:  stops the service, replaces the binary in /usr/local/bin, rewrites
             the unit, restarts. Configuration, ca.key, the store logs and
             /srv/xftp are left alone, and the CA identity is re-checked
             afterwards.

Roles (each is a separate process with its own CA, directories and port):
  smp     popopx-smp.service    port 5223   /etc/opt/popopx            /var/opt/popopx
  xftp    popopx-xftp.service   port 8443   /etc/opt/popopx-xftp       /var/opt/popopx-xftp  (files /srv/xftp)
  ntf     popopx-ntf.service    port 5226   /etc/opt/popopx-notifications  /var/opt/popopx-notifications
  relay   popopx-relay.service  port 5227   /etc/opt/popopx-relay      /var/opt/popopx-relay
          A second smp-server process, so group queues can be relayed by a
          different identity than direct ones. It selects its own directories
          through SMP_SERVER_CFG_PATH and SMP_SERVER_LOG_PATH.
  all     smp, xftp, ntf and relay

Options:
  --roles LIST           Comma-separated. Default: all.
  --fqdn HOST            Public hostname for the TLS certificate and the printed
                         address. Default: hostname -f.
  --version TAG          Release tag to install. Default: latest.
  --sha256 HEX           Also require this digest for the downloaded bundle.
                         The bundle digest is always verified against its own
                         .sha256; this pins a specific build instead.
  --repo owner/name      Release repository. Default: popopx-chat/popopxmq.
  --from-source          Build on this host with cabal instead of downloading.
                         Needs the repository tree, not just this script.
  --smp-password PASS    Password needed to create queues (printable ASCII
                         without whitespace, '@', ':', '/'). Unset = open relay.
  --xftp-path DIR        Chunk storage directory. Default: /srv/xftp.
  --xftp-quota SIZE      File storage quota. Default: 100gb.
  --sign-algorithm ALG   ED448 or ED25519 for the TLS certificates. Default: ED448.
  --smp-port/--xftp-port/--ntf-port/--relay-port N
                         Override a role's port.
  --with-tor             Publish each enabled smp, relay or xftp role as a Tor V3
                         hidden service (ntf gets none) and route onion-destination
                         traffic through the local SOCKS proxy. Default: off.
  --no-caddy             Do not install or configure Caddy. The relay then keeps
                         port 443 itself and its HTTPS mini-site stays disabled.
  --no-ufw               Do not add firewall rules and do not enable ufw.
  --no-sysctl            Do not write the kernel tuning drop-in.
  --json-out PATH        Also write the printed summary as JSON.
  --arch NAME            Override uname -m for the asset name. Only for planning
                         a node of a different architecture than this one.
  -n, --dry-run          Print the whole plan, change nothing.
  -h, --help             Show this help.

Port notes, measured from this package:
  * xftp-server and ntf-server default to port 443 and smp-server to 5223,443;
    the ports above are what this script configures, not the binaries' defaults.
  * 5224 is defaultControlPort (src/Popopx/Messaging/Server/Main/Init.hs:37). The
    generated .ini names it in a commented control_port line and this script never
    enables it, so it costs nothing here. If you enable it for two smp-server
    roles on one host, they collide on 5224 - enable it for one of them only.
  * With Caddy installed, Caddy owns 80 and 443 and proxies the information site
    to the relay's loopback web port (8000, 8001, 8002); the protocol listeners
    keep their own pinned-fingerprint TLS on the ports above.

Tor note: /var/lib/tor/popopx-<role>/ holds the hidden service private key. The
script creates it only when missing and never deletes or rewrites it, because a
removed directory means new .onion addresses and every contact link that already
carries the old one stops working.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --roles) ROLES_CSV="${2:?--roles needs a value}"; shift 2 ;;
    --fqdn) FQDN="${2:?--fqdn needs a value}"; shift 2 ;;
    --version) TAG="${2:?--version needs a value}"; shift 2 ;;
    --sha256) EXPECTED_SHA="${2:?--sha256 needs a value}"; shift 2 ;;
    --repo)
      REPO="${2:?--repo needs a value}"
      DL_BASE="https://github.com/${REPO}/releases"
      API_BASE="https://api.github.com/repos/${REPO}/releases"
      SOURCE_URI="https://github.com/${REPO}"
      shift 2
      ;;
    --from-source) MODE="source"; shift ;;
    --smp-password) SMP_PASSWORD="${2:?--smp-password needs a value}"; shift 2 ;;
    --xftp-path) XFTP_PATH="${2:?--xftp-path needs a value}"; shift 2 ;;
    --xftp-quota) XFTP_QUOTA="${2:?--xftp-quota needs a value}"; shift 2 ;;
    --sign-algorithm) SIGN_ALGORITHM="${2:?--sign-algorithm needs a value}"; shift 2 ;;
    --smp-port) PORT_SMP="${2:?--smp-port needs a value}"; shift 2 ;;
    --xftp-port) PORT_XFTP="${2:?--xftp-port needs a value}"; shift 2 ;;
    --ntf-port) PORT_NTF="${2:?--ntf-port needs a value}"; shift 2 ;;
    --relay-port) PORT_RELAY="${2:?--relay-port needs a value}"; shift 2 ;;
    --with-tor) WITH_TOR=1; shift ;;
    --no-caddy) WITH_CADDY=0; shift ;;
    --no-ufw) WITH_UFW=0; shift ;;
    --no-sysctl) WITH_SYSCTL=0; shift ;;
    --json-out) JSON_OUT="${2:?--json-out needs a value}"; shift 2 ;;
    --arch) ARCH_OVERRIDE="${2:?--arch needs a value (x86_64 | aarch64)}"; shift 2 ;;
    -n | --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

run_sh() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] %s\n' "$*"
    return 0
  fi
  bash -c "$*"
}

is_port() { case "${1:-}" in (*[!0-9]* | "") return 1 ;; (*) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] ;; esac; }

# ---- role tables -----------------------------------------------------------

role_bin() { case "$1" in (smp | relay) printf 'smp-server' ;; (xftp) printf 'xftp-server' ;; (ntf) printf 'ntf-server' ;; (*) return 1 ;; esac; }
role_ini() { case "$1" in (smp | relay) printf 'smp-server.ini' ;; (xftp) printf 'file-server.ini' ;; (ntf) printf 'ntf-server.ini' ;; (*) return 1 ;; esac; }
role_scheme() { case "$1" in (smp | relay) printf 'smp' ;; (xftp) printf 'xftp' ;; (ntf) printf 'ntf' ;; (*) return 1 ;; esac; }
role_service() { printf 'popopx-%s.service' "$1"; }
role_port() { case "$1" in (smp) printf '%s' "$PORT_SMP" ;; (xftp) printf '%s' "$PORT_XFTP" ;; (ntf) printf '%s' "$PORT_NTF" ;; (relay) printf '%s' "$PORT_RELAY" ;; (*) return 1 ;; esac; }
role_cfg() { case "$1" in (smp) printf '/etc/opt/popopx' ;; (relay) printf '/etc/opt/popopx-relay' ;; (xftp) printf '/etc/opt/popopx-xftp' ;; (ntf) printf '/etc/opt/popopx-notifications' ;; (*) return 1 ;; esac; }
role_log() { case "$1" in (smp) printf '/var/opt/popopx' ;; (relay) printf '/var/opt/popopx-relay' ;; (xftp) printf '/var/opt/popopx-xftp' ;; (ntf) printf '/var/opt/popopx-notifications' ;; (*) return 1 ;; esac; }
role_web_port() { case "$1" in (smp) printf '%s' "$WEB_PORT_SMP" ;; (relay) printf '%s' "$WEB_PORT_RELAY" ;; (xftp) printf '%s' "$WEB_PORT_XFTP" ;; (*) return 1 ;; esac; }

# The directories come from apps/<server>/Main.hs, which reads these variables
# and falls back to the same defaults written above. Setting them for every role
# keeps the unit file self-describing and is what isolates the relay instance.
role_env() {
  case "$1" in
    (smp | relay)
      printf 'Environment=SMP_SERVER_CFG_PATH=%s\nEnvironment=SMP_SERVER_LOG_PATH=%s\n' "$(role_cfg "$1")" "$(role_log "$1")"
      ;;
    (xftp) printf 'Environment=XFTP_SERVER_CFG_PATH=%s\nEnvironment=XFTP_SERVER_LOG_PATH=%s\n' "$(role_cfg xftp)" "$(role_log xftp)" ;;
    (ntf) printf 'Environment=NTF_SERVER_CFG_PATH=%s\nEnvironment=NTF_SERVER_LOG_PATH=%s\n' "$(role_cfg ntf)" "$(role_log ntf)" ;;
    (*) return 1 ;;
  esac
}

# ---- preflight -------------------------------------------------------------

# Per-role results, kept in indexed arrays rather than associative ones so the
# script parses and runs on bash 3.2 too: Ubuntu 22.04 ships 5.1, but the syntax
# gate should not need a shell newer than the one available for checking.
role_index() {
  case "$1" in
    smp) printf '0' ;;
    xftp) printf '1' ;;
    ntf) printf '2' ;;
    relay) printf '3' ;;
    *) return 1 ;;
  esac
}
FP=("" "" "" "")
ONION=("" "" "" "")
ADDR=("" "" "" "")
ACT=("" "" "" "")
set_fp() { local i; i="$(role_index "$1")"; FP[i]="$2"; }
set_onion() { local i; i="$(role_index "$1")"; ONION[i]="$2"; }
set_addr() { local i; i="$(role_index "$1")"; ADDR[i]="$2"; }
set_act() { local i; i="$(role_index "$1")"; ACT[i]="$2"; }
get_fp() { local i; i="$(role_index "$1")"; printf '%s' "${FP[i]}"; }
get_onion() { local i; i="$(role_index "$1")"; printf '%s' "${ONION[i]}"; }
get_addr() { local i; i="$(role_index "$1")"; printf '%s' "${ADDR[i]}"; }
get_act() { local i; i="$(role_index "$1")"; printf '%s' "${ACT[i]}"; }

ROLES=()
case "$ROLES_CSV" in
  all) ROLES=(smp xftp ntf relay) ;;
  *)
    IFS=',' read -r -a ROLES <<<"$ROLES_CSV"
    for r in "${ROLES[@]}"; do
      case "$r" in
        smp | xftp | ntf | relay) ;;
        *) die "unknown role: $r (use smp, xftp, ntf, relay or all)" ;;
      esac
    done
    ;;
esac
[ "${#ROLES[@]}" -gt 0 ] || die "no roles selected"

for r in "${ROLES[@]}"; do
  is_port "$(role_port "$r")" || die "port for role $r is not a valid port: $(role_port "$r")"
done

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || warn "written for Ubuntu, found ${ID:-unknown}"
  [ "${VERSION_ID:-}" = "22.04" ] || warn "written for Ubuntu 22.04, found ${VERSION_ID:-unknown}"
fi

ARCH="${ARCH_OVERRIDE:-$(uname -m)}"
# macOS reports arm64 where Linux reports aarch64; the asset names follow Linux.
[ "$ARCH" = "arm64" ] && ARCH="aarch64"
if [ -n "$ARCH_OVERRIDE" ] && [ "$ARCH_OVERRIDE" != "$(uname -m)" ]; then
  warn "planning for ${ARCH_OVERRIDE} while this host is $(uname -m) - a real run would install foreign binaries"
fi
case "$ARCH" in
  x86_64 | aarch64) ;;
  *) die "no release bundle is published for $ARCH; use --from-source or pass --arch" ;;
esac

if [ "$DRY_RUN" != "1" ]; then
  [ "$(id -u)" -eq 0 ] || die "must run as root (or use --dry-run to see the plan)"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
fi

case "$SIGN_ALGORITHM" in
  ED448 | ED25519) ;;
  *) die "--sign-algorithm must be ED448 or ED25519" ;;
esac

if [ -n "$SMP_PASSWORD" ]; then
  case "$SMP_PASSWORD" in
    (*[[:space:]]* | *"@"* | *":"* | *"/"*) die "the queue password may not contain whitespace, '@', ':' or '/' (the server address embeds it)" ;;
  esac
fi

if [ -z "$FQDN" ]; then
  FQDN="$(hostname -f 2>/dev/null || true)"
  case "$FQDN" in
    (*.*) ;;
    *) FQDN="" ;;
  esac
fi
if [ -z "$FQDN" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    FQDN="relay.example.com"
    warn "no usable hostname -f, the dry run assumes ${FQDN}; pass --fqdn for a real run"
  else
    die "hostname -f did not return a domain name; pass --fqdn"
  fi
fi
case "$FQDN" in
  (*[!A-Za-z0-9._-]*) die "invalid hostname: $FQDN" ;;
  (*.local) die "hostname -f gave the link-local name ${FQDN}; pass --fqdn with the public domain" ;;
esac

TMP_DIR="$(mktemp -d /tmp/popopx-deploy.XXXXXX)"
cleanup() { [ "$KEEP_TMP" = "1" ] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT
BUNDLE_DIR="${TMP_DIR}/bundle"

# ---- obtain the binaries ---------------------------------------------------

fetch() {
  # $1 url, $2 destination
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] curl -fL %s -o %s\n' "$1" "$2"
    return 0
  fi
  curl -fL --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 -o "$2" "$1"
}

resolve_tag() {
  if [ "$TAG" != "latest" ]; then
    RESOLVED_TAG="$TAG"
    return 0
  fi
  local json=""
  # GitHub's /releases/latest skips prereleases, and this repository's CI marks
  # the releases it creates prerelease: true, so the plain "latest" lookup can
  # legitimately 404. Fall back to the newest entry of the full list.
  if [ "$DRY_RUN" = "1" ]; then
    RESOLVED_TAG="<resolved>"
    printf '    [dry-run] GET %s/latest, falling back to %s (prereleases are skipped by "latest")\n' "$API_BASE" "$API_BASE"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required to download a release; or use --from-source"
  json="$(curl -fsSL --retry 3 --proto '=https' --tlsv1.2 "${API_BASE}/latest" 2>/dev/null || true)"
  RESOLVED_TAG="$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
  if [ -z "$RESOLVED_TAG" ]; then
    warn "no stable release found, using the newest release including prereleases"
    json="$(curl -fsSL --retry 3 --proto '=https' --tlsv1.2 "${API_BASE}" 2>/dev/null || true)"
    RESOLVED_TAG="$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
  fi
  [ -n "$RESOLVED_TAG" ] || die "could not resolve a release tag from ${REPO}; pass --version TAG or use --from-source"
}

obtain_prebuilt() {
  resolve_tag
  local asset="popopxmq-linux-${ARCH}-${RESOLVED_TAG}.tar.gz"
  log "downloading ${asset}"
  fetch "${DL_BASE}/download/${RESOLVED_TAG}/${asset}" "${TMP_DIR}/${asset}"
  fetch "${DL_BASE}/download/${RESOLVED_TAG}/${asset}.sha256" "${TMP_DIR}/${asset}.sha256"
  if [ "$DRY_RUN" = "1" ]; then
    STAGE_BIN="${TMP_DIR}/bundle/bin"
    return 0
  fi

  [ -s "${TMP_DIR}/${asset}" ] || die "downloaded nothing for ${asset}: does release ${RESOLVED_TAG} carry it? (scripts/ubuntu/build_release_bundle.sh produces it)"
  log "verifying SHA-256"
  (cd "$TMP_DIR" && sha256sum -c "${asset}.sha256") || die "checksum mismatch for ${asset}: refusing to install"
  if [ -n "$EXPECTED_SHA" ]; then
    local got
    got="$(sha256sum "${TMP_DIR}/${asset}" | cut -d' ' -f1)"
    [ "$got" = "$EXPECTED_SHA" ] || die "pinned SHA-256 mismatch: expected ${EXPECTED_SHA}, got ${got}"
    log "pinned digest matches"
  fi
  mkdir -p "$BUNDLE_DIR"
  tar -xzf "${TMP_DIR}/${asset}" -C "$BUNDLE_DIR" --strip-components=1
  [ -x "${BUNDLE_DIR}/bin/smp-server" ] || die "${asset} has no bin/smp-server"
  STAGE_BIN="${BUNDLE_DIR}/bin"
  if [ ! -x "${BUNDLE_DIR}/bin/ntf-server" ]; then
    HAS_NTF_BIN=0
    warn "this bundle has no ntf-server (built with --without-ntf); the ntf role will be skipped"
  fi
}

obtain_source() {
  [ -f "${ROOT}/popopxmq.cabal" ] || die "--from-source needs the popopxmq tree; ${ROOT} is a bundle, not the repository"
  log "building the release bundle on this host (this takes a while on a first run)"
  run_sh "cd '${ROOT}' && ./scripts/ubuntu/build_release_bundle.sh --out '${TMP_DIR}/build' --tag 'local-$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)'"
  if [ "$DRY_RUN" = "1" ]; then
    STAGE_BIN="${TMP_DIR}/build/popopxmq-linux-${ARCH}-local/bin"
    return 0
  fi
  local built
  built="$(find "${TMP_DIR}/build" -maxdepth 1 -name 'popopxmq-linux-*.tar.gz' | head -n 1)"
  [ -n "$built" ] || die "the build did not produce a bundle"
  mkdir -p "$BUNDLE_DIR"
  tar -xzf "$built" -C "$BUNDLE_DIR" --strip-components=1
  STAGE_BIN="${BUNDLE_DIR}/bin"
}

STAGE_BIN=""
HAS_NTF_BIN=1
if [ "$MODE" = "source" ]; then
  obtain_source
else
  obtain_prebuilt
fi

# ---- service user ----------------------------------------------------------

ensure_user() {
  if [ "$DRY_RUN" = "1" ] || id "$RUN_USER" >/dev/null 2>&1; then
    return 0
  fi
  log "creating the non-login system user ${RUN_USER}"
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$RUN_USER"
}

# ---- identity guard --------------------------------------------------------

identity_snapshot() {
  local cfg="$1" out="" f
  for f in ca.key ca.crt fingerprint; do
    if [ -f "${cfg}/${f}" ]; then
      out+="$(sha256sum "${cfg}/${f}" | cut -d' ' -f1)  ${f}"$'\n'
    fi
  done
  printf '%s' "$out"
}

identity_check() {
  local role="$1" before="$2" after
  [ -n "$before" ] || return 0
  after="$(identity_snapshot "$(role_cfg "$role")")"
  if [ "$before" != "$after" ]; then
    die "role ${role}: the CA identity files under $(role_cfg "$role") changed during the upgrade.
Nothing was deleted by this script knowingly - stop here, diff the two snapshots,
and only then restart. A changed fingerprint makes every existing queue and file
reference on this relay unreachable."
  fi
}

# ---- one role --------------------------------------------------------------

write_unit() {
  local role="$1" bin unit
  bin="$(role_bin "$role")"
  unit="/etc/systemd/system/$(role_service "$role")"
  log "writing ${unit}"
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] unit: %s, %s start, port %s, run as %s, graceful SIGINT\n' \
      "$(role_service "$role")" "$bin" "$(role_port "$role")" "$RUN_USER"
    return 0
  fi
  {
    printf '[Unit]\n'
    printf 'Description=POPOPX %s relay (%s, port %s)\n' "$role" "$(role_scheme "$role")" "$(role_port "$role")"
    printf 'Documentation=%s\n' "$SOURCE_URI"
    printf 'After=network-online.target\nWants=network-online.target\n\n'
    printf '[Service]\n'
    printf 'Type=simple\n'
    printf 'User=%s\nGroup=%s\n' "$RUN_USER" "$RUN_GROUP"
    role_env "$role"
    printf 'ExecStart=%s/%s start +RTS -N -RTS\n' "$BIN_DIR" "$bin"
    # The servers flush and close the store log on SIGINT, so the stop signal has
    # to be SIGINT; the default SIGTERM takes the abrupt path. Matches
    # scripts/main/smp-server.service and the docker entrypoints' exec comment.
    printf 'KillSignal=SIGINT\n'
    printf 'TimeoutStartSec=infinity\nTimeoutStopSec=infinity\n'
    printf 'Restart=on-failure\nRestartSec=10s\n'
    printf 'StartLimitBurst=3\nStartLimitInterval=60s\n'
    printf 'LimitNOFILE=65535\n'
    printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\n'
    printf 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE\n'
    printf 'NoNewPrivileges=true\n'
    printf 'PrivateTmp=true\n'
    printf '\n[Install]\nWantedBy=multi-user.target\n'
  } >"$unit"
}

configure_ini() {
  # Everything below is a sed on the generated file rather than a re-init,
  # because init is destructive and idempotency has to come from editing.
  local role="$1" cfg ini port web_port
  cfg="$(role_cfg "$role")"
  ini="${cfg}/$(role_ini "$role")"
  port="$(role_port "$role")"
  log "configuring ${ini} (port ${port})"
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] set [TRANSPORT] port = %s in %s\n' "$port" "$ini"
    if [ "$WITH_CADDY" = "1" ] && role_web_port "$role" >/dev/null 2>&1; then
      printf '    [dry-run] set [WEB] http = %s in %s\n' "$(role_web_port "$role")" "$ini"
    fi
    return 0
  fi
  [ -f "$ini" ] || die "${ini} is missing after init"

  # One line per key; the generated [TRANSPORT] block is the only place a bare
  # "port =" appears, and commented keys never match "^port".
  sed -i "s|^port = .*|port = ${port}|" "$ini"
  sed -i "s|^host = .*|host = ${FQDN}|" "$ini"

  case "$role" in
    smp | relay)
      # init's --source-code takes no value, so the scripted ini has this line
      # commented ("# source_code = URI"); AGPL-3.0 needs a real URI here. An
      # operator's own uncommented value is left alone.
      sed -i "s|^# *source_code = .*|source_code = ${SOURCE_URI}|" "$ini"
      if [ "$WITH_CADDY" = "1" ]; then
        sed -i "s|^# *http = .*|http = $(role_web_port "$role")|" "$ini"
        # Caddy terminates TLS for the site, so the embedded HTTPS listener must
        # not bind 443 next to the protocol listener. Same edit the docker
        # entrypoint applies for WEB_MANUAL.
        sed -i -e 's|^https = .*|# https = &|' -e 's|^cert = .*|# cert = &|' -e 's|^key = .*|# key = &|' "$ini"
      else
        sed -i -e 's|^https = .*|# https = &|' -e 's|^cert = .*|# cert = &|' -e 's|^key = .*|# key = &|' "$ini"
      fi
      ;;
    xftp)
      if [ "$WITH_CADDY" = "1" ]; then
        sed -i "s|^# *http = .*|http = $(role_web_port xftp)|" "$ini"
      fi
      sed -i "s|^path = .*|path = ${XFTP_PATH}|" "$ini"
      sed -i "s|^storage_quota = .*|storage_quota = ${XFTP_QUOTA}|" "$ini"
      ;;
  esac
}

install_role() {
  local role="$1" cfg logd bin ini svc before
  cfg="$(role_cfg "$role")"
  logd="$(role_log "$role")"
  bin="$(role_bin "$role")"
  ini="${cfg}/$(role_ini "$role")"
  svc="$(role_service "$role")"

  if [ "$role" = "ntf" ] && [ "$HAS_NTF_BIN" != "1" ]; then
    warn "skipping role ntf: the bundle has no ntf-server"
    return 0
  fi

  before="$(identity_snapshot "$cfg")"
  local upgraded=0
  [ -n "$before" ] && upgraded=1

  log "installing ${role} (${svc})"
  if [ "$upgraded" = "1" ]; then
    log "upgrade: replacing the binary only, configuration and identity untouched"
    run systemctl stop "$svc" 2>/dev/null || true
  fi
  run install -m 0755 -o root -g root "${STAGE_BIN}/${bin}" "${BIN_DIR}/${bin}"
  run install -d -m 0750 -o "$RUN_USER" -g "$RUN_GROUP" "$cfg" "$logd"
  if [ "$role" = "xftp" ]; then
    run install -d -m 0750 -o "$RUN_USER" -g "$RUN_GROUP" "$XFTP_PATH"
  fi

  if [ "$upgraded" != "1" ]; then
    # First install for this role: nothing exists under $cfg, so init's
    # clearDirIfExists has nothing to destroy.
    log "initialising ${role} on ${FQDN}"
    local -a init_cmd
    case "$role" in
      smp | relay)
        init_cmd=("$BIN_DIR/$bin" init --yes --daily-stats --fqdn "$FQDN" --sign-algorithm "$SIGN_ALGORITHM")
        if [ -n "$SMP_PASSWORD" ]; then
          init_cmd+=(--password "$SMP_PASSWORD")
        else
          init_cmd+=(--no-password)
        fi
        ;;
      xftp)
        init_cmd=("$BIN_DIR/$bin" init --fqdn "$FQDN" --path "$XFTP_PATH" --quota "$XFTP_QUOTA" --sign-algorithm "$SIGN_ALGORITHM")
        ;;
      ntf)
        init_cmd=("$BIN_DIR/$bin" init --fqdn "$FQDN" --sign-algorithm "$SIGN_ALGORITHM")
        ;;
    esac
    # init must see the same variables the unit will get, or it writes the .ini
    # and ca.key into the binary's default directories (for relay that is the smp
    # role's /etc/opt/popopx) and the check below fails. The pairs are taken from
    # role_env so the two can never drift apart.
    local -a init_env=()
    local kv
    while IFS= read -r kv; do
      init_env+=("${kv#Environment=}")
    done < <(role_env "$role")
    init_cmd=(env "${init_env[@]}" "${init_cmd[@]}")
    if [ "$DRY_RUN" = "1" ]; then
      printf '    [dry-run] %s\n' "${init_cmd[*]}"
    else
      # init prints the address it derived; keep it so a failed run is debuggable.
      "${init_cmd[@]}"
      run_sh "chown -R ${RUN_USER}:${RUN_GROUP} '${cfg}' '${logd}'"
      [ -f "$ini" ] || die "init did not create ${ini}"
      chmod 0640 "$ini"
    fi
  fi

  configure_ini "$role"
  write_unit "$role"

  if [ "$DRY_RUN" != "1" ]; then
    run_sh "chown -R ${RUN_USER}:${RUN_GROUP} '${cfg}' '${logd}'"
    identity_check "$role" "$before"
  fi

  run systemctl daemon-reload
  run systemctl enable "$svc"
  run systemctl restart "$svc"
  if [ "$upgraded" = "1" ]; then set_act "$role" upgraded; else set_act "$role" initialised; fi

  if [ "$DRY_RUN" != "1" ]; then
    local fp
    fp="$(cat "${cfg}/fingerprint" 2>/dev/null || true)"
    [ -n "$fp" ] || die "${cfg}/fingerprint is missing; the relay identity was not created"
    set_fp "$role" "$fp"
  else
    set_fp "$role" "<fingerprint>"
  fi
}

ensure_user

# The relay role shares /usr/local/bin/smp-server with smp but must not share a
# single byte of state, so its CA, store log and web port are all separate.
for role in "${ROLES[@]}"; do
  install_role "$role"
done

# ---- Caddy -----------------------------------------------------------------

install_caddy() {
  local cf="/etc/caddy/Caddyfile" block
  local key_url="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
  local list_url="https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt"
  local keyring="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
  local list="/etc/apt/sources.list.d/caddy-stable.list"
  if [ "$WITH_CADDY" != "1" ]; then
    log "Caddy skipped (--no-caddy): the relays keep port 443 for their own TLS"
    return 0
  fi
  if ! command -v caddy >/dev/null 2>&1 && [ "$DRY_RUN" != "1" ]; then
    log "installing caddy"
    # Ubuntu 22.04 has no caddy in its own archives, so the official Cloudsmith
    # repository is the only source that carries its security updates.
    run_sh "apt-get update -qq && apt-get install -y ca-certificates curl gnupg" || {
      warn "could not install ca-certificates/curl/gnupg, so the Caddy repository cannot be added."
      warn "The relays still work; only the ACME certificate and the site reverse proxy are missing."
      return 0
    }
    run_sh "set -o pipefail; install -d -m 0755 /usr/share/keyrings && curl -1sLf '${key_url}' | gpg --yes --dearmor -o '${keyring}' && curl -1sLf '${list_url}' >'${list}'" || {
      warn "could not add the Caddy apt repository from dl.cloudsmith.io (check this host's network)."
      warn "The relays still work; only the ACME certificate and the site reverse proxy are missing."
      return 0
    }
    run_sh "apt-get update -qq && apt-get install -y caddy" || {
      warn "caddy is not installable from this host's apt sources; the relays still work, only the"
      warn "ACME certificate and the site reverse proxy are missing. Re-run with --no-caddy to silence this."
      return 0
    }
  fi
    log "configuring Caddy for ${FQDN}"
  # One public name can front one mini-site, so the site belongs to the first
  # installed role that has a web port. Another role's site needs its own host.
  local web_role="" r
  for r in smp relay xftp; do
    for installed in "${ROLES[@]}"; do
      if [ "$installed" = "$r" ] && [ -z "$web_role" ]; then web_role="$r"; fi
    done
  done
  [ -n "$web_role" ] || web_role="smp"
  log "  the site on ${FQDN} fronts the ${web_role} mini-site on 127.0.0.1:$(role_web_port "$web_role")"
  block="# BEGIN popopx (managed by deploy_ubuntu22.sh; edit outside the markers)
${FQDN} {
    encode gzip
    header {
        Strict-Transport-Security \"max-age=31536000\"
        -Server
    }
    reverse_proxy 127.0.0.1:$(role_web_port "$web_role") {
        header_up X-Forwarded-Proto https
    }
}
# END popopx
"
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] write the popopx block to %s, then systemctl reload caddy\n' "$cf"
    return 0
  fi
  install -d /etc/caddy
  if [ -f "$cf" ] && grep -q '^# BEGIN popopx' "$cf"; then
    cp -a "$cf" "${cf}.popopx-backup"
    sed -i '/^# BEGIN popopx/,/^# END popopx/d' "$cf"
    printf '%s' "$block" >>"$cf"
  else
    [ -f "$cf" ] && { cp -a "$cf" "${cf}.popopx-backup"; printf '\n' >>"$cf"; }
    printf '%s' "$block" >>"$cf"
  fi
  if caddy validate --config "$cf" >/dev/null 2>&1; then
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy || true
  else
    warn "the merged Caddyfile does not validate; it was left in place but Caddy was not reloaded."
    warn "run 'caddy validate --config %s' to see why; the backup is %s.popopx-backup" "$cf" "$cf"
  fi
}

install_caddy

# ---- Tor -------------------------------------------------------------------

tor_on() { [ "$WITH_TOR" = "1" ]; }

install_tor() {
  tor_on || return 0
  local roles="" r
  for r in "${ROLES[@]}"; do
    case "$r" in (smp | relay | xftp) roles+=" $r" ;; esac
  done
  [ -n "$roles" ] || { warn "--with-tor given but no role publishes a hidden service"; return 0; }

  if ! command -v tor >/dev/null 2>&1 && [ "$DRY_RUN" != "1" ]; then
    log "installing tor"
    run_sh "apt-get update -qq && apt-get install -y tor" || die "could not install tor"
  fi

  local block="# BEGIN popopx (managed by deploy_ubuntu22.sh)
SocksPort 127.0.0.1:9050
"
  for r in $roles; do
    # The directory is created only when missing. Its private key IS the .onion
    # address, so removing it would silently change a published identity.
    log "hidden service for ${r} on port $(role_port "$r")"
    block+="HiddenServiceDir /var/lib/tor/popopx-${r}
HiddenServicePort $(role_port "$r") 127.0.0.1:$(role_port "$r")
"
    run_sh "install -d -m 0700 -o debian-tor -g debian-tor /var/lib/tor/popopx-${r}"
  done

  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] append this block to /etc/tor/torrc, backing the file up once as torrc.popopx-backup:\n'
    printf '%s' "$block" | sed 's/^/        /'
    printf '        # END popopx\n'
    printf '    [dry-run] systemctl enable --now tor; systemctl restart tor\n'
    printf '    [dry-run] read /var/lib/tor/popopx-<role>/hostname, set [TRANSPORT] host = <fqdn>,<onion>\n'
    printf '    [dry-run] and socks_proxy = localhost:9050 for smp/relay, then restart only those services\n'
    for r in $roles; do set_onion "$r" "<${r}-onion>.onion"; done
    return 0
  fi

  local torrc="/etc/tor/torrc"
  [ -f "${torrc}.popopx-backup" ] || cp -a "$torrc" "${torrc}.popopx-backup" 2>/dev/null || : >"${torrc}.popopx-backup"
  if grep -q '^# BEGIN popopx' "$torrc" 2>/dev/null; then
    sed -i '/^# BEGIN popopx/,/^# END popopx/d' "$torrc"
  fi
  printf '%s# END popopx\n' "$block" >>"$torrc"

  systemctl enable tor >/dev/null 2>&1 || true
  systemctl restart tor
  log "waiting for Tor to publish the hidden services"
  local waited=0 r host
  for r in $roles; do
    while [ ! -s "/var/lib/tor/popopx-${r}/hostname" ] && [ "$waited" -lt 120 ]; do
      sleep 2
      waited=$((waited + 2))
    done
    host="$(cut -d' ' -f1 "/var/lib/tor/popopx-${r}/hostname" 2>/dev/null || true)"
    if [ -z "$host" ]; then
      warn "no .onion for role ${r} yet - check 'systemctl status tor'; the address below omits it"
      continue
    fi
    set_onion "$r" "$host"
    log "  ${r} -> ${host}"
  done

  # The dual-stack address goes into the ini so the relay advertises and logs
  # both names, and the SOCKS proxy is what lets this relay reach onion-only
  # peers. Restart only the roles whose ini changed.
  local changed=""
  for r in $roles; do
    onion="$(get_onion "$r")"
    [ -n "$onion" ] || continue
    ini_path="$(role_cfg "$r")/$(role_ini "$r")"
    sed -i "s|^host = .*|host = ${FQDN},${onion}|" "$ini_path"
    case "$r" in
      smp | relay) sed -i "s|^#\? *socks_proxy = .*|socks_proxy = localhost:9050|" "$ini_path" ;;
    esac
    changed+=" $(role_service "$r")"
  done
  if [ -n "$changed" ]; then
    log "restarting with the onion address advertised:${changed}"
    # shellcheck disable=SC2086
    systemctl restart $changed
  fi
}

install_tor

# ---- firewall and kernel ---------------------------------------------------

# Ports that must stay reachable while the firewall comes up. SSH_CONNECTION is
# "<client ip> <client port> <server ip> <server port>", so its last field is the
# port this session is actually served on; a root login shell (sudo -i) has none,
# so fall back to the sockets sshd is listening on. No output means neither was
# available, and the script then adds nothing beyond the plain 22/tcp rule.
ssh_listen_ports() {
  local p=""
  if [ -n "${SSH_CONNECTION:-}" ]; then
    p="${SSH_CONNECTION##* }"
    if [[ "$p" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  command -v ss >/dev/null 2>&1 || return 0
  ss -Htlnp 2>/dev/null | awk '/sshd/ { n = split($4, a, ":"); if (a[n] ~ /^[0-9]+$/) print a[n] }' | sort -un
}

install_ufw() {
  if [ "$WITH_UFW" != "1" ]; then
    log "firewall rules skipped (--no-ufw)"
    return 0
  fi
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw is not installed; add rules for ports $(for r in "${ROLES[@]}"; do printf '%s ' "$(role_port "$r")"; done)80 443 yourself"
    return 0
  fi
  local r p was_active
  # SSH is allowed before anything else, because ufw enable below switches the
  # inbound policy to deny and would otherwise cut the session this script runs in.
  run ufw allow 22/tcp comment "ssh"
  # shellcheck disable=SC2046  # ssh_listen_ports prints one bare port per line
  for p in $(ssh_listen_ports); do
    if [ "$p" != "22" ]; then
      log "sshd also answers on port ${p}, allowing it before the firewall goes active"
      run ufw allow "${p}/tcp" comment "ssh (${p})"
    fi
  done
  for r in "${ROLES[@]}"; do
    run ufw allow "$(role_port "$r")/tcp" comment "popopx ${r}"
  done
  if [ "$WITH_CADDY" = "1" ]; then
    run ufw allow 80/tcp comment "popopx acme"
    run ufw allow 443/tcp comment "popopx site"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] ufw --force enable; the rules above are what goes active\n'
    return 0
  fi
  was_active=0
  if ufw status | grep -q 'Status: active'; then was_active=1; fi
  if ufw --force enable; then
    log "firewall enabled with the rules above"
    if [ "$was_active" != "1" ]; then
      warn "ufw was inactive, so inbound deny now applies to every port not allowed above - a TURN"
      warn "relay port range, a database, a monitoring agent: add those rules yourself."
    fi
  else
    warn "'ufw --force enable' failed, so the rules above are stored but NOT in force."
    warn "The relays still work. Investigate with: ufw status verbose"
  fi
}

install_ufw

install_sysctl() {
  if [ "$WITH_SYSCTL" != "1" ]; then
    log "kernel tuning skipped (--no-sysctl)"
    return 0
  fi
  local f="/etc/sysctl.d/99-popopx-relay.conf"
  log "writing ${f}"
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] accept-queue, SYN backlog, ephemeral ports and fin_timeout for a busy relay\n'
    return 0
  fi
  # Every key here is built into the core/tcp_ipv4 code, so the drop-in applies
  # on a stock Ubuntu 22.04 kernel without a netfilter or congestion-control
  # module present. In a container the write still succeeds and sysctl warns.
  cat >"$f" <<'CONF'
# POPOPX relay: a public relay holds many long-lived TLS connections and
# forwards each message to a destination server, so the accept queue and the
# outbound port range matter more than on a typical host.
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
CONF
  sysctl --system >/dev/null 2>&1 || warn 'some keys were rejected (expected inside a container); see "sysctl --system"'
}

install_sysctl

# ---- summary ---------------------------------------------------------------

address_for() {
  # Mirrors how the servers encode their own address: the port is written only
  # when it differs from the protocol default (5223 for SMP, 443 for XFTP/NTF).
  local role="$1" scheme port default hosts onion
  scheme="$(role_scheme "$role")"
  port="$(role_port "$role")"
  case "$role" in
    smp | relay) default=5223 ;;
    *) default=443 ;;
  esac
  hosts="$FQDN"
  onion="$(get_onion "$role")"
  [ -n "$onion" ] && hosts="${FQDN},${onion}"
  if [ "$port" = "$default" ]; then
    printf '%s://%s@%s' "$scheme" "$(get_fp "$role")" "$hosts"
  else
    printf '%s://%s@%s:%s' "$scheme" "$(get_fp "$role")" "$hosts" "$port"
  fi
}

echo
log "installed on ${FQDN}"
for role in "${ROLES[@]}"; do
  [ -n "$(get_fp "$role")" ] || continue
  set_addr "$role" "$(address_for "$role")"
  printf '  %-6s %-16s port %-6s %s\n' "$role" "$(role_service "$role")" "$(role_port "$role")" "$(get_act "$role")"
  printf '         %s\n' "$(get_addr "$role")"
done

if [ "$WITH_TOR" = "1" ]; then
  echo
  log "hidden service keys live in /var/lib/tor/popopx-<role>/hostname and survive upgrades by design"
fi

cat <<EOF

Next steps
  * Publish the addresses above. They are identity-bearing: the fingerprint is the
    CA certificate this host generated, and it must not change while queues or
    files reference it. Keep $(role_cfg smp)/ca.key off the machine that serves
    traffic if the offline-CA split matters to you.
  * Journal: systemctl status popopx-smp.service, journalctl -u popopx-smp.service -f
  * The source of this build is ${SOURCE_URI}; AGPL-3.0 section 13 obliges you to
    offer it to the users of this relay.
EOF

if [ -n "$JSON_OUT" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    printf '    [dry-run] write the summary to %s\n' "$JSON_OUT"
  else
    {
      printf '{\n  "node": "%s",\n  "release": "%s",\n  "installed_at": "%s",\n  "roles": {\n' \
        "$FQDN" "${RESOLVED_TAG:-$TAG}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      first=1
      for role in "${ROLES[@]}"; do
        [ -n "$(get_addr "$role")" ] || continue
        [ "$first" = "1" ] || printf ',\n'
        first=0
        printf '    "%s": {"service": "%s", "port": %s, "fingerprint": "%s", "address": "%s", "onion": "%s"}' \
          "$role" "$(role_service "$role")" "$(role_port "$role")" "$(get_fp "$role")" "$(get_addr "$role")" "$(get_onion "$role")"
      done
      printf '\n  }\n}\n'
    } >"$JSON_OUT"
    log "wrote ${JSON_OUT}"
  fi
fi
