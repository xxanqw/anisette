# anisette

Experimental, Linux-hosted Anisette V3 service for AltStore Classic and compatible clients. Written in Swift 6.4.1 (Hummingbird), using a Rust C-ABI backend that emulates the **macOS** CoreADI library with Unicorn. No Android environment, Android provisioning, or Android device identifier is used.

> This project is an experimental interoperability implementation, **not a verified replacement for AltServer**. Building and passing protocol tests do not establish that Apple's login service will accept generated headers or that every AltStore client can use them. In particular, Apple's private authentication flow may change without notice.

## Requirements

- Docker Engine and Docker Compose V2, on **Linux x86_64** (the CoreADI image is x86_64).
- Network access to GitHub and Apple's iTunes download during the one-time CoreADI setup.
- Apple ID credentials are entered **only in your AltStore/AltServer client**, never in this service.
- HTTPS reverse proxy if used beyond localhost (e.g. Caddy, Nginx, Tailscale). The Compose example deliberately binds to `127.0.0.1`.

## Deploy

```sh
docker compose --profile setup build coreadi-setup
docker compose --profile setup run --rm coreadi-setup
docker compose up --build -d anisette
curl -fsS http://127.0.0.1:6969/healthz
curl -fsS http://127.0.0.1:6969/v3/client_info
```

The setup container downloads **Apple's original iTunes 12.8.3 DMG**, verifies its hard-coded SHA-256, and extracts the x86_64 CoreADI Mach-O into a private Docker volume. Neither Apple's file nor any account token is committed to this repository or baked into the application image. A separate private Docker volume holds emulated device state after provisioning and OTP generation.

Both the C-ABI wrapper and this project pin the Rust implementation to a specific commit for reproducibility. The server fails fast if the CoreADI file is absent. You can restart the service with `docker compose restart anisette`.

To expose it through your reverse proxy, route both HTTP and WebSockets to `127.0.0.1:6969`. Configure your AltStore-compatible client to use `https://your-host.example` (base URL, without `/v3`) **only if it supports changing the Anisette server URL**. This does not patch AltSign or the notarized AltStore Classic app, and cannot fix a client that does not allow the custom endpoint.

## API

| Endpoint | Purpose |
| --- | --- |
| `GET /healthz` | Health check |
| `GET /v3/client_info` | Mac AuthKit `client_info` and CFNetwork user agent |
| `WS /v3/provisioning_session` | V3 identifier/SPIM → CPIM → PTM/TK provisioning handshake |
| `POST /v3/get_headers` | Accepts Base64 `identifier` and `adi_pb`, returns MID, OTP and RINFO |

The protocol uses the standard V3 message labels. The `adi_pb` value is an **opaque, server-specific** encoded blob containing the emulated macOS store and 16-byte machine UUID. It cannot be exchanged with Android-based Anisette V3 services. Preserve the exact Base64 string the server returns during provisioning.

This service defaults to a modern Mac AuthKit identity and `akd/1.0 CFNetwork/808.1.4` to match the AltSign client family under investigation. You can configure `ANISETTE_CLIENT_INFO` and `ANISETTE_USER_AGENT` in a Compose `.env` file; changing these values does **not** change the emulated CoreADI binary.

Because legacy V3 provisioning clients omit the routing value when sending PTM/TK, the backend currently uses the legacy fallback `17106176`. If Apple's response uses a different value, provisioning may fail; this requires real-client validation, not merely successful HTTP responses.

## Testing

```sh
docker build --progress=plain -t anisette-test .
```

The Docker build compiles the pinned Rust backend, Swift project, and runs Swift unit tests. GitHub Actions also downloads the SHA-256-verified macOS CoreADI from Apple's CDN, verifies the emulator loads it, and tests `/healthz`, `/v3/client_info`, the WebSocket upgrade, and invalid-input handling. It **does not log into Apple or test live provisioning**.

A real integration test requires:

1. A valid Apple ID on a device you control, with 2FA.
2. The downloaded verified CoreADI image.
3. A V3-compatible client configured to point at your Anisette URL.
4. A complete WebSocket handshake, followed by a successful `/v3/get_headers`, and then an actual client login.

Only after step 4 should compatibility be claimed. Keep debug logs free of credentials, 2FA codes, `adi_pb`, MID/OTP values, and Apple cookies.

## Current limitations

- x86_64 Linux only.
- Uses an opaque, non-Android ADI state format that existing clients should treat as uninterpreted bytes; clients that interpret Android `adi.pb` cannot use it.
- OTP state changes are saved to a private Docker volume, keyed by the machine UUID. Back up this volume along with any client-provided `adi_pb` state. Its contents are sensitive and must not be made publicly readable.
- No rate limiting, access controls, or TLS termination included. Do not publish port 6969 directly to the internet.
- Apple's authentication and Anisette APIs are undocumented and can change.

## Credits and licenses

The macOS CoreADI emulation and C ABI originate from [sacca97/os-findmy-e](https://github.com/sacca97/os-findmy-e), licensed MIT; the project builds the pinned native `adi-core` Rust crate. Its Unicorn dependency is GPL-2.0, so review license obligations before distributing binaries. Apple CoreADI is proprietary and fetched directly from Apple by each operator. This repository does not include Apple's binaries.
