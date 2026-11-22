# POPOPXMQ

[![GitHub build](https://github.com/popopx-chat/popopxmq/actions/workflows/build.yml/badge.svg)](https://github.com/popopx-chat/popopxmq/actions/workflows/build.yml)

POPOPXMQ is the reference implementation of the POPOPX Messaging Protocol (SMP) and of the XFTP
blind file store: a message broker and a file relay that carry traffic over unidirectional queues
created per connection. The protocol has no user accounts, no global identifiers and no directory —
a recipient learns only the queues it consumes, which is what limits metadata collection to the
relays a connection happens to traverse.

Everything here is written in Haskell on software transactional memory (STM). The server keeps its
queue state in memory, so a relay restart is durable only to the extent that the store log or the
PostgreSQL queue store is enabled.

## Components

| Target | Role |
| --- | --- |
| `smp-server` | SMP relay: creates queues, delivers messages, authenticates senders. Listens on 5223 and 443. |
| `xftp-server` | XFTP relay: blind, chunked, end-to-end encrypted file storage. Listens on 443 (HTTP/2). |
| `ntf-server` | Notification service used by mobile clients to receive wake-ups. |
| `xftp` | XFTP client library and CLI. |
| `popopxmq` (library) | SMP client, SMP agent and XFTP client APIs, for embedding in an application. |

**SMP relay (`smp-server`).** Transport is TLS, authenticated by pinning the fingerprint of an
offline CA certificate rather than by a web PKI name, so the server address carries its own trust
anchor: `smp://<fingerprint>@<hostname>[:5223]`. Initialisation builds a two-level chain — a long
lived self-signed CA ("offline") and the leaf used in the handshake ("online"). If the leaf is
compromised, the CA key signs a replacement and the address, and therefore every existing queue,
stays valid; keep that key off the host that serves traffic. Queue persistence is the append-only
store log, enabled by default and compacted on restart (suspended and deleted queues are dropped at
that point), with `smp-server database` to import or export the store to PostgreSQL.

**XFTP relay (`xftp-server`).** Files arrive as chunks already encrypted by the sender; the relay
stores, deduplicates and serves them without a decrypting path, and it records only sizes and
expiry. Per-file quota is set at initialisation, and stored files expire — 48 hours by default
(`defFileExpirationHours`).

**Client and agent libraries.** `Popopx.Messaging.Client` is a functional API over a single relay:
commands as function calls, received messages as an STM queue, keep-alive handled for you.
`Popopx.Messaging.Agent` sits above it and owns duplex connections that span several relays, with
the whole protocol expressed by the `ACommand` / `AResponse` types. The agent is a library that runs
in the application's process; it is not a daemon and binds no port. Where a separate local process
is wanted, speak the [agent protocol](./protocol/agent-protocol.md) over your own socket.

## Prerequisites

- OpenSSL, used at initialisation to generate keys and certificates. On Debian/Ubuntu:
  `apt update && apt install openssl`.
- On macOS, Homebrew's `openssl@3`: the LibreSSL that ships with the system cannot build the
  required algorithms. Confirm with `openssl version` before running `smp-server init` — if it
  reports LibreSSL, install OpenSSL and put it first on your `PATH`.
- GHC 9.6.3 and Cabal 3.10 or newer. Continuous integration builds the reference toolchain
  (9.6.3) on Ubuntu 22.04 and 24.04, and also compiles the package with GHC 8.10.7.

## Build from source

```sh
git clone https://github.com/popopx-chat/popopxmq
cd popopxmq
git submodule update --init --recursive   # cbits/blst, cbits/libbbs
cabal update
cabal build exe:smp-server exe:xftp-server
```

Point Cabal at the result with `cabal list-bin`:

```sh
cabal list-bin exe:smp-server
cabal list-bin exe:xftp-server
```

Run the suite with `cabal test`, and read `smp-server --help`, `smp-server init --help` and
`xftp-server --help` for the options below.

## Initialise and run

```sh
smp-server init -n relay.example.com     # or: smp-server init --ip 203.0.113.10
smp-server start
```

`init` writes `smp-server.ini` plus the credentials into the configuration directory
(`/etc/opt/popopx` in the packaged layout), and prints the `smp://` address to publish. The store
log is on by default; pass `--disable-store-log` to run without it. `--password`,
`--sign-algorithm ED25519|ED448`, `--control-port` and `--socks-proxy` cover queue creation
credentials, the certificate algorithm, administrative access and routing to onion-only relays.

The XFTP relay is initialised the same way, with its storage directory and quota made explicit:

```sh
xftp-server init -n files.example.com -p /srv/xftp -q 100gb
xftp-server start
```

A relay can hold both a public hostname and an `.onion` address, which lets a connection succeed
when only one of the two peers uses Tor: `smp://<fingerprint>@<public_hostname>,<onion_hostname>`.
See [`scripts/tor`](./scripts/tor/) for the hidden-service setup.

## Containers

Build the image from this repository — one `Dockerfile`, with `APP` selecting the binary and
`APP_PORT` the exposed port:

```sh
DOCKER_BUILDKIT=1 docker build -t local/smp-server  --build-arg APP=smp-server  --build-arg APP_PORT=5223 .
DOCKER_BUILDKIT=1 docker build -t local/xftp-server --build-arg APP=xftp-server --build-arg APP_PORT=443  .
```

[`scripts/docker`](./scripts/docker/) holds compose files for both relays. `docker-compose-smp.env`
and `docker-compose-xftp.env` list the parameters; `ADDR` is required, and the image reference comes
from `POPOPX_IMAGE` / `POPOPX_XFTP_IMAGE`, so point them at what you just built:

```sh
cd scripts/docker

ADDR=relay.example.com POPOPX_IMAGE=local/smp-server \
  docker compose -f docker-compose-smp-complete.yml up -d

ADDR=files.example.com QUOTA=100gb POPOPX_XFTP_IMAGE=local/xftp-server \
  docker compose -f docker-compose-xftp.yml up -d
```

`docker-compose-smp-complete.yml` brings up Caddy for ACME certificates and mounts them into the
relay; `docker-compose-smp-manual.yml` is the same relay without the certificate automation. The
paths worth pinning to a volume are:

| Container | Path | Contents |
| --- | --- | --- |
| `smp-server` | `/etc/opt/popopx` | `smp-server.ini`, CA and TLS credentials |
| `smp-server` | `/var/opt/popopx` | store log, message log, statistics |
| `xftp-server` | `/etc/opt/popopx-xftp` | `xftp-server.ini`, credentials |
| `xftp-server` | `/var/opt/popopx-xftp` | state and logs |
| `xftp-server` | `/srv/xftp` | stored chunks |

## Install script

For Ubuntu, [`install.sh`](./install.sh) installs both relays as systemd services and adds
`popopx-servers-update` and `popopx-servers-uninstall`. The download is verified against a pinned
SHA-256 before it runs:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/popopx-chat/popopxmq/master/install.sh -o popopx-server-install.sh &&\
if echo 'af89b3d9cb5368b4335db9a1b01b79bbb02f3a75fb32bd349f3d8edf0ee427ed popopx-server-install.sh' | sha256sum -c; then
  chmod +x ./popopx-server-install.sh && ./popopx-server-install.sh && rm ./popopx-server-install.sh
else
  echo "SHA-256 checksum is incorrect!" && rm ./popopx-server-install.sh
fi
```

## Protocol specifications

- [SMP protocol](./protocol/popopx-messaging.md) — queues, credentials, command and response grammar.
- [SMP agent protocol](./protocol/agent-protocol.md) — duplex connections across relays.
- [XFTP protocol](./protocol/xftp.md) — file upload, download and quota commands.
- [XRCP](./protocol/xrcp.md) — the redundancy control protocol between relays.
- [Cryptographic constants](./protocol/crypto-registry.md) — every key-derivation label and separator,
  with its inputs and its outputs. These values are computed independently by each peer and are not
  negotiated, so a change on one side only breaks the other side silently.
- [Security](./protocol/security.md) and an [overview](./protocol/overview-tjr.md).

## Ecosystem

- [popopx.chat](https://popopx.chat) — product entry point.
- [popopx-chat](https://github.com/popopx-chat/popopx-chat) — desktop, terminal and mobile clients;
  embeds the agent library from this package.
- [popopx-service-suite](https://github.com/popopx-chat/popopx-service-suite) — self-hosted services
  on top of the agent protocol.
- [popopx-mac-node](https://github.com/popopx-chat/popopx-mac-node) — local relay node for macOS.

## License

POPOPXMQ is licensed under the **GNU Affero General Public License, version 3 only**
(`AGPL-3.0-only`); the full text is in [LICENSE](./LICENSE).

POPOPXMQ is a modified version of [simplexmq](https://github.com/simplex-chat/simplexmq), Copyright
(c) simplex.chat, distributed under the same AGPL-3.0-only license. All upstream copyright and legal
notices are retained verbatim, as AGPL-3.0 section 5(d) requires: the license text, the `author`,
`maintainer` and `copyright` fields of `popopxmq.cabal`, and the module headers in
`src/Popopx/Messaging/`. [NOTICE](./NOTICE) records what was changed and when, the
interoperability consequences of those changes, and the third-party notices that this package
conveys.

Under AGPL-3.0 section 13, anyone running a modified server for others over a network owes those
users the complete corresponding source, which is this repository:
<https://github.com/popopx-chat/popopxmq>. A relay can also publish that address to its clients
through the `[INFORMATION]` section of the SMP protocol; `smp-server init` sets it from
`--source-code`, defaulting to the same URL.
