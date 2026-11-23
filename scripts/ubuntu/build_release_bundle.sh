#!/usr/bin/env bash
# Copyright © 2026 POPOPX Chat
# SPDX-License-Identifier: AGPL-3.0-only
#
# Build the POPOPX relay binaries on Ubuntu 22.04 and pack the release bundle
# that scripts/ubuntu/deploy_ubuntu22.sh installs on the cluster nodes.
#
# Two cabal passes, on purpose: popopxmq.cabal marks the ntf-server executable
# buildable: False unless the server_postgres flag is on, so it cannot join the
# lean build of the other two. Separate --builddirs keep the flag sets from
# recompiling each other, which is the same split .github/workflows/build.yml
# uses with dist-postgres.

set -Eeuo pipefail

# Mirrors Dockerfile.build, the image this repository's CI compiles in.
GHC_VERSION="9.6.3"
CABAL_VERSION="3.14.1.1"
APT_PACKAGES="curl libpq-dev git sqlite3 libsqlite3-dev build-essential libgmp3-dev zlib1g-dev llvm llvm-dev libnuma-dev libssl-dev"

REPO="${POPOPX_REPO:-popopx-chat/popopxmq}"
SOURCE_URI="https://github.com/${REPO}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT}/dist"
BUILDDIR_LEAN="dist-release"
BUILDDIR_PG="dist-release-postgres"
JOBS=""
TAG=""
WITH_NTF=1
SKIP_DEPS=0
SKIP_TOOLCHAIN=0
DO_STRIP=1
DRY_RUN=0

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: build_release_bundle.sh [OPTIONS]

Builds smp-server and xftp-server with the package defaults, and ntf-server with
-fserver_postgres, then packs them with LICENSE, NOTICE and a VERSIONS.txt record
into dist/popopxmq-linux-<arch>-<tag>.tar.gz plus its .sha256.

Options:
  --tag TAG          Bundle and release tag. Default: the tag pointing at HEAD,
                     otherwise v<package version> from popopxmq.cabal.
  --out DIR          Output directory. Default: ./dist
  --jobs N           Parallel cabal jobs. Default: nproc.
  --without-ntf      Skip the ntf-server pass, halving build time. The bundle then
                     cannot serve the ntf role.
  --skip-deps        Do not run apt-get install.
  --skip-toolchain   Fail instead of installing GHC with ghcup.
  --no-strip         Keep symbols in the shipped binaries.
  -n, --dry-run      Print every command, change nothing.
  -h, --help         Show this help.

Environment:
  POPOPX_REPO        owner/name of the source repository. Default popopx-chat/popopxmq.

Requires an Ubuntu 22.04 (or newer) build host with git and sudo, and network
access to downloads.haskell.org and Hackage on a first run.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --out) OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    --jobs) JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    --without-ntf) WITH_NTF=0; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --skip-toolchain) SKIP_TOOLCHAIN=1; shift ;;
    --no-strip) DO_STRIP=0; shift ;;
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

SUDO=""
if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != "1" ]; then
  command -v sudo >/dev/null 2>&1 || die "not root and sudo is unavailable; run as root or pass --skip-deps"
  SUDO="sudo"
fi

cd "$ROOT"

[ -f popopxmq.cabal ] || die "popopxmq.cabal not found in ${ROOT}: run this from the repository"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    warn "this script targets Ubuntu; found ${ID:-unknown}"
  elif [ "${VERSION_ID:-}" != "22.04" ]; then
    warn "written for Ubuntu 22.04, found ${VERSION_ID:-unknown}; the toolchain steps may differ"
  fi
fi

ARCH="$(uname -m)"
# macOS reports arm64 where Linux reports aarch64; asset names follow Linux.
[ "$ARCH" = "arm64" ] && ARCH="aarch64"
case "$ARCH" in
  x86_64 | aarch64) ;;
  *) die "unsupported architecture: $ARCH" ;;
esac
if [ "${ID:-}" != "ubuntu" ] && [ "$DRY_RUN" != "1" ]; then
  die "this builds the Linux release bundle; found ${ID:-unknown} (pass --dry-run to inspect the plan)"
fi

[ -n "$JOBS" ] || JOBS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

PKG_VERSION="$(awk '/^version:/ {print $2; exit}' popopxmq.cabal)"
[ -n "$PKG_VERSION" ] || die "could not read the package version from popopxmq.cabal"

if [ -z "$TAG" ]; then
  TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
  [ -n "$TAG" ] || TAG="v${PKG_VERSION}"
fi

case "$TAG" in
  *[!A-Za-z0-9._-]*) die "tag must be [A-Za-z0-9._-], got: $TAG" ;;
esac

BASE_NAME="popopxmq-linux-${ARCH}-${TAG}"
STAGE_NAME="${BASE_NAME}"
STAGE_DIR="${OUT_DIR}/${STAGE_NAME}"
TARBALL="${OUT_DIR}/${BASE_NAME}.tar.gz"

log "bundle ${BASE_NAME} from ${ROOT}"
log "package popopxmq ${PKG_VERSION}, commit $(git rev-parse --short HEAD)$(git diff --quiet HEAD 2>/dev/null || printf ', dirty')"

if [ "$SKIP_DEPS" != "1" ]; then
  log "installing build dependencies"
  run_sh "${SUDO} apt-get update"
  # shellcheck disable=SC2086
  run_sh "${SUDO} apt-get install -y ${APT_PACKAGES}"
fi

export PATH="${HOME}/.ghcup/bin:${HOME}/.cabal/bin:${PATH}"

if ! command -v ghc >/dev/null 2>&1; then
  if [ "$SKIP_TOOLCHAIN" = "1" ]; then
    die "ghc not found and --skip-toolchain was passed; install GHC ${GHC_VERSION} first"
  fi
  log "installing GHC ${GHC_VERSION} and cabal ${CABAL_VERSION} with ghcup"
  run_sh "curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org \
    | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
      BOOTSTRAP_HASKELL_GHC_VERSION=${GHC_VERSION} \
      BOOTSTRAP_HASKELL_CABAL_VERSION=${CABAL_VERSION} \
      BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1 \
      BOOTSTRAP_HASKELL_INSTALL_NO_STACK_HOOK=1 sh"
fi

if [ "$DRY_RUN" != "1" ]; then
  HAVE_GHC="$(ghc --version 2>/dev/null | awk '{print $NF}')"
  if [ "${HAVE_GHC:-}" != "$GHC_VERSION" ]; then
    [ "$SKIP_TOOLCHAIN" = "1" ] && die "ghc ${HAVE_GHC:-missing} found, ${GHC_VERSION} expected"
    log "selecting GHC ${GHC_VERSION} with ghcup"
    ghcup install ghc "$GHC_VERSION" >/dev/null 2>&1 || true
    ghcup set ghc "$GHC_VERSION"
    have_cabal="$(cabal --version | awk '{print $3}')"
    if [ "$have_cabal" != "$CABAL_VERSION" ]; then
      ghcup install cabal "$CABAL_VERSION" >/dev/null 2>&1 || true
      ghcup set cabal "$CABAL_VERSION"
    fi
  fi
fi

log "syncing submodules (cbits/blst, cbits/libbbs)"
run git submodule update --init --recursive

log "cabal update"
run cabal update

log "building smp-server and xftp-server (${JOBS} jobs)"
run_sh "cabal build --builddir=${BUILDDIR_LEAN} --jobs=${JOBS} exe:smp-server exe:xftp-server"

if [ "$WITH_NTF" = "1" ]; then
  log "building ntf-server with -fserver_postgres"
  run_sh "cabal build --builddir=${BUILDDIR_PG} --jobs=${JOBS} -fserver_postgres exe:ntf-server"
fi

list_bin() {
  # -v0 still prints cabal's git chatter on some versions, and the path is the last line.
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "<built $1>"
    return 0
  fi
  cabal list-bin -v0 --builddir="$2" "exe:$1" | tail -n 1
}

SRC_SMP="$(list_bin smp-server "$BUILDDIR_LEAN")"
SRC_XFTP="$(list_bin xftp-server "$BUILDDIR_LEAN")"
SRC_NTF=""
[ "$WITH_NTF" = "1" ] && SRC_NTF="$(list_bin ntf-server "$BUILDDIR_PG")"

rm_stage() { [ "$DRY_RUN" = "1" ] || rm -rf "$STAGE_DIR"; }

log "staging ${STAGE_DIR}"
run_sh "mkdir -p ${STAGE_DIR}/bin ${STAGE_DIR}/scripts/ubuntu"
run_sh "install -m 0755 '${SRC_SMP}' ${STAGE_DIR}/bin/smp-server"
run_sh "install -m 0755 '${SRC_XFTP}' ${STAGE_DIR}/bin/xftp-server"
if [ "$WITH_NTF" = "1" ]; then
  run_sh "install -m 0755 '${SRC_NTF}' ${STAGE_DIR}/bin/ntf-server"
fi
if [ "$DO_STRIP" = "1" ]; then
  run_sh "strip ${STAGE_DIR}/bin/*"
fi
run cp LICENSE NOTICE README.md "$STAGE_DIR/"
run cp scripts/ubuntu/deploy_ubuntu22.sh "$STAGE_DIR/scripts/ubuntu/"
run chmod +x "$STAGE_DIR/scripts/ubuntu/deploy_ubuntu22.sh"

VERSIONS_FILE="${STAGE_DIR}/VERSIONS.txt"
if [ "$DRY_RUN" = "1" ]; then
  printf '    [dry-run] write %s\n' "$VERSIONS_FILE"
else
  {
    printf 'POPOPXMQ release bundle\n\n'
    printf '  tag:            %s\n' "$TAG"
    printf '  package:        popopxmq %s\n' "$PKG_VERSION"
    printf '  source:         %s\n' "$SOURCE_URI"
    printf '  revision:       %s%s\n' "$(git rev-parse HEAD)" "$(git diff --quiet HEAD 2>/dev/null || printf ' (built from a dirty working tree)')"
    printf '  built:          %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  host:           %s %s / %s\n' "${NAME:-Ubuntu}" "${VERSION_ID:-unknown}" "$ARCH"
    printf '  toolchain:      GHC %s, cabal %s\n' "$(ghc --version | awk '{print $NF}')" "$(cabal --version | awk '{print $3}')"
    printf '  strip:          %s\n' "$([ "$DO_STRIP" = "1" ] && printf yes || printf no)"
    printf '\nBUILT BINARIES\n'
    if [ "$WITH_NTF" = "1" ]; then
      printf '  smp-server, xftp-server  package default flags (memory and store-log queues)\n'
      printf '  ntf-server               -fserver_postgres; popopxmq.cabal marks it buildable: False without\n'
      printf '                           that flag, so it needs libpq5 present at runtime\n'
    else
      printf '  smp-server, xftp-server  package default flags; ntf-server not built (--without-ntf)\n'
    fi
    printf '\nBINARIES\n'
    (cd "$STAGE_DIR/bin" && sha256sum -- *)
    printf '\nEvery file in this bundle is AGPL-3.0-only; LICENSE is included and NOTICE\n'
    printf 'records the modifications made to the upstream simplexmq sources. The complete\n'
    printf 'corresponding source for this build is the revision named above.\n'
  } >"$VERSIONS_FILE"
fi

log "packing"
run_sh "tar --owner=0 --group=0 --numeric-owner -czf '${TARBALL}' -C '${OUT_DIR}' '${STAGE_NAME}'"
if [ "$DRY_RUN" = "1" ]; then
  printf '    [dry-run] sha256sum %s > %s\n' "$BASE_NAME.tar.gz" "$BASE_NAME.tar.gz.sha256"
else
  (cd "$OUT_DIR" && sha256sum -- "${BASE_NAME}.tar.gz" >"${BASE_NAME}.tar.gz.sha256")
  log "verifying the checksum file the way a node will"
  (cd "$OUT_DIR" && sha256sum -c "${BASE_NAME}.tar.gz.sha256")
  printf '\n  size: %s\n' "$(du -h "$TARBALL" | cut -f1)"
  printf '  sha256: %s\n' "$(cut -d' ' -f1 "${TARBALL}.sha256")"
fi

cat <<EOF

Bundle ready: ${TARBALL}

Publish it (the two files go up together; the installer verifies the second):

  gh release create ${TAG} \\
    --repo ${REPO} \\
    --title "POPOPXMQ ${TAG}" \\
    --notes "Relay binaries for Ubuntu 22.04 (${ARCH}), built from $(git rev-parse --short HEAD). Source: ${SOURCE_URI}" \\
    '${TARBALL}' "${TARBALL}.sha256"

Or add it to a release CI already created for this tag:

  gh release upload ${TAG} --repo ${REPO} --clobber \\
    '${TARBALL}' "${TARBALL}.sha256"

Note: .github/workflows/build.yml publishes with prerelease: true, and GitHub
excludes prereleases from /releases/latest, which is where install.sh and
deploy_ubuntu22.sh look by default. Either mark the release as not a prerelease,
or pin the nodes to the tag with --version ${TAG}.
EOF
