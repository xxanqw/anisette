# anisette

Linux-hosted **Anisette V3** server, written in **Swift 6.4.1** with Hummingbird. The **default deployment uses Apple's Windows iTunes CoreADI64.dll through Wine**, not Android. The earlier macOS CoreADI/Unicorn implementation remains available as a rollback option.

> **Experimental:** HTTP/WebSocket endpoints, the actual Windows DLL initialization, and Swift-to-Wine IPC have passed GitHub Actions smoke tests. **An actual V3 provisioning round-trip, MID/OTP acceptance, and AltStore Classic 2.3.1 Apple ID login have not been verified.** Anisette cannot necessarily fix errors caused by AltSign inside the notarized client.

## Requirements

- Linux **x86_64**, Docker Engine and Docker Compose V2.
- `curl`, `7z` and `msiextract` (packages `p7zip-full`, `msitools`) **on the host** for the Apple Windows iTunes DLL extraction.
- A reverse proxy that forwards both HTTP and WebSocket upgrades to `127.0.0.1:6969` (for example, an existing `ani.xxanqw.me` reverse proxy).
- Apple ID credentials and 2FA codes are entered **only into AltStore**; never send them to this service.

## Replace an existing Mac Anisette deployment

**Run the following in the SAME checkout/directory and with the SAME Compose project name used by your current deployment.** This replaces the running `anisette` service rather than starting a second instance. If you previously supplied `-p` or `COMPOSE_PROJECT_NAME`, use the same value.

```sh
git fetch origin
git switch experiments/windows-coreadi-wine
# Install extraction tools if needed (Debian/Ubuntu):
sudo apt-get install -y curl p7zip-full msitools
# The Apple-proprietary binaries are downloaded directly from Apple, never committed:
test -f apple-windows/CoreADI64.dll || bash scripts/prepare_windows_coreadi.sh

docker compose config --quiet
docker compose up --build -d --remove-orphans anisette
docker compose ps
curl -fsS http://127.0.0.1:6969/healthz
curl -fsS http://127.0.0.1:6969/healthz/adi
curl -fsS http://127.0.0.1:6969/v3/client_info
```

The default `compose.yaml` retains the original **service name `anisette`, container port 6969, loopback host port ${ANISETTE_PORT:-6969}, and default directory-derived Compose project**. A normal `docker compose up` recreates the service in place; **do not first run `docker compose down -v`**. The existing HTTPS hostname and proxy can keep pointing to the same port; no new subdomain or proxy change is required.

The new state volume is `windows-state`; the existing Mac `coreadi` and `state` volumes are preserved for rollback. These state formats are not interchangeable. The Windows backend returns opaque `WADIv1` capability tokens; a previously cached `MADIv1` token cannot be reused. If AltStore continues sending the Mac token, it must re-provision a fresh Windows identity. This may require clearing AltStore's persisted Anisette identity/cache, depending on client behavior.

The Windows client profile is:

```text
<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>
akd/1.0 CFNetwork/808.1.4
```

All Apple CoreADI DLLs remain operator-supplied and mounted read-only from `./apple-windows`; they are not baked into Docker images or published in Git. Each client identifier gets a private persistent Wine prefix. Enable `ANISETTE_WINE_DEBUG_LOG=1` only temporarily for troubleshooting.

### Roll back to the original macOS backend

```sh
docker compose -f compose.mac.yaml up --build -d --remove-orphans anisette
curl -fsS http://127.0.0.1:6969/v3/client_info
```

This uses the preserved original Mac volumes. Never use `down -v` for a rollback.

## API

| Endpoint | Function |
| --- | --- |
| `GET /healthz` | Swift HTTP liveness |
| `GET /healthz/adi` | Actually initializes Windows CoreADI via Wine (expensive; do not expose publicly) |
| `GET /v3/client_info` | Windows iTunes identity and CFNetwork user agent |
| `WS /v3/provisioning_session` | Identifier/SPIM → CPIM → PTM/TK → opaque `adi_pb` |
| `POST /v3/get_headers` | Accepts Base64 `identifier` and `adi_pb`; returns MID, OTP, RINFO |

V3 provisioning includes the Apple server's private handshake and is **not tested end-to-end** by the automated checks. The legacy V3 client does not supply a routing value during PTM/TK completion; the worker currently uses fallback `17106176`. Real-world compatibility remains unproven.

## Verification and safety

GitHub Actions compiles the Windows worker, Swift code and linked Rust compatibility library, downloads the original Apple DLL from the official Windows iTunes installer, and verifies its initialization under Wine and from Swift inside Docker. The runtime smoke test also checks `/healthz/adi`, Windows `client_info` and HTTP 101 WebSocket upgrade. These checks **do not authenticate an Apple ID**.

Keep TCP 6969 bound only to loopback, protect the proxy, and never log credentials, 2FA codes, ADI tokens or MID/OTP values. This project has no built-in rate limiting or authorization; exposing the V3 service to the public internet requires additional proxy controls. Apple's private interfaces may change without notice.

## Credits and licensing

The optional macOS CoreADI backend uses the Rust C ABI from [sacca97/os-findmy-e](https://github.com/sacca97/os-findmy-e) with Unicorn. Unicorn's GPL-2.0 obligations should be reviewed before distribution. The Windows CoreADI DLL is proprietary Apple software and must be obtained independently from Apple's installer; no Apple binaries are distributed here.
