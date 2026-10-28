import Foundation
import Hummingbird
import HummingbirdWebSocket

// Diagnostic events contain only operation names and coarse error categories.
// Never record Apple credentials, ADI state, device identifiers or generated OTPs.
func logAnisetteEvent(_ event: String) {
    FileHandle.standardError.write(Data("AnisetteV3 \(event)\n".utf8))
}

func anisetteErrorCategory(_ error: Error) -> String {
    guard let value = error as? AnisetteError else { return "internal" }
    switch value {
    case .invalidInput(let reason):
        if reason.contains("Unsupported Windows ADI state") { return "stale-adi-pb" }
        if reason.contains("Windows ADI state missing") { return "needs-provisioning" }
        if reason.contains("identifier does not match") { return "identifier-mismatch" }
        if reason.contains("token does not match") { return "token-mismatch" }
        return "invalid-input"
    case .unavailable:
        return "unavailable"
    case .coreADI:
        return "coreadi"
    }
}

let env = ProcessInfo.processInfo.environment
let corePath = env["ANISETTE_COREADI_PATH"] ?? "/data/CoreADI.x86_64"
let statePath = env["ANISETTE_STATE_DIR"] ?? "/state"
let port = Int(env["PORT"] ?? "6969") ?? 6969
let backend = env["ANISETTE_BACKEND"] ?? "mac"
let defaultClientInfo = backend == "windows"
    ? "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
    : AnisetteProtocol.clientInfo
let clientInfo = env["ANISETTE_CLIENT_INFO"] ?? defaultClientInfo
let userAgent = env["ANISETTE_USER_AGENT"] ?? AnisetteProtocol.userAgent

do {
    let engine: any AnisetteEngine
    switch backend {
    case "mac":
        engine = try MacADIEngine(coreADIPath: corePath, stateDirectory: statePath)
    case "windows":
        engine = try WindowsADIEngine(
            stateDirectory: statePath,
            winePath: env["ANISETTE_WINE_PATH"] ?? "/usr/bin/wine",
            workerPath: env["ANISETTE_WINDOWS_WORKER"] ?? "/usr/local/bin/anisette-win.exe",
            coreADIPath: env["ANISETTE_WINDOWS_COREADI_PATH"] ?? "/data/CoreADI64.dll"
        )
    default:
        throw AnisetteError.invalidInput("Unknown ANISETTE_BACKEND: \(backend)")
    }
    let router = Router(context: BasicWebSocketRequestContext.self)

    router.get("/healthz") { _, _ in "ok" }
    router.get("/healthz/adi") { _, _ in
        do {
            try await engine.probe()
            return "ok"
        } catch {
            FileHandle.standardError.write(Data("ADI health probe failed: \(error)\n".utf8))
            throw error
        }
    }
    router.get("/v3/client_info") { _, _ in
        logAnisetteEvent("client_info.request backend=\(backend)")
        return ClientInfoResponse(clientInfo: clientInfo, userAgent: userAgent)
    }

    router.post("/v3/get_headers") { request, context -> HeadersResponse in
        logAnisetteEvent("headers.request")
        do {
            let message = try await request.decode(as: HeadersRequest.self, context: context)
            let identifier = try AnisetteProtocol.decodeBase64(
                message.identifier, named: "identifier", maxBytes: 16
            )
            let state = try AnisetteProtocol.decodeBase64(
                message.adiPB, named: "adi_pb", maxBytes: ProvisionedState.maxStoreBytes + 64
            )
            let response = try await engine.headers(hostUUID: identifier, stateBytes: state)
            logAnisetteEvent(response.result == "Headers" ? "headers.success" : "headers.error result=engine")
            return response
        } catch {
            logAnisetteEvent("headers.error category=\(anisetteErrorCategory(error))")
            return .failure(String(describing: error))
        }
    }

    router.ws("/v3/provisioning_session") { inbound, outbound, _ in
        logAnisetteEvent("provision.connected")
        var activeSession: UUID?
        var failureType = "InvalidIdentifier"
        do {
            var iterator = inbound.makeAsyncIterator()
            try await outbound.write(.text(try AnisetteProtocol.encodeMessage([
                "result": "GiveIdentifier",
            ])))
            guard let identifierFrame = try await iterator.next(),
                  identifierFrame.opcode == .text else {
                throw AnisetteError.invalidInput("Expected identifier frame")
            }
            let identifierMessage = try AnisetteProtocol.parseMessage(
                String(buffer: identifierFrame.data)
            )
            let identifier = try AnisetteProtocol.decodeBase64(
                identifierMessage["identifier"], named: "identifier", maxBytes: 16
            )

            failureType = "StartProvisioningError"
            try await outbound.write(.text(try AnisetteProtocol.encodeMessage([
                "result": "GiveStartProvisioningData",
            ])))
            guard let spimFrame = try await iterator.next(), spimFrame.opcode == .text else {
                throw AnisetteError.invalidInput("Expected SPIM frame")
            }
            let spimMessage = try AnisetteProtocol.parseMessage(String(buffer: spimFrame.data))
            let spim = try AnisetteProtocol.decodeBase64(spimMessage["spim"], named: "spim")

            logAnisetteEvent("provision.begin")
            let session = try await engine.begin(hostUUID: identifier, spim: spim)
            activeSession = session.id
            logAnisetteEvent("provision.begin.success")
            failureType = "EndProvisioningError"
            try await outbound.write(.text(try AnisetteProtocol.encodeMessage([
                "result": "GiveEndProvisioningData",
                "cpim": session.cpim.base64EncodedString(),
            ])))

            guard let finalFrame = try await iterator.next(), finalFrame.opcode == .text else {
                throw AnisetteError.invalidInput("Expected PTM/TK frame")
            }
            let finalMessage = try AnisetteProtocol.parseMessage(String(buffer: finalFrame.data))
            let ptm = try AnisetteProtocol.decodeBase64(finalMessage["ptm"], named: "ptm")
            let tk = try AnisetteProtocol.decodeBase64(finalMessage["tk"], named: "tk")
            logAnisetteEvent("provision.finish")
            let state = try await engine.finish(id: session.id, ptm: ptm, tk: tk)
            activeSession = nil
            logAnisetteEvent("provision.finish.success")

            try await outbound.write(.text(try AnisetteProtocol.encodeMessage([
                "result": "ProvisioningSuccess",
                "adi_pb": state.base64EncodedString(),
            ])))
        } catch {
            logAnisetteEvent("provision.error stage=\(failureType) category=\(anisetteErrorCategory(error))")
            if let activeSession {
                await engine.cancel(id: activeSession)
            }
            try? await outbound.write(.text(try AnisetteProtocol.encodeMessage([
                "result": failureType,
                "message": String(describing: error),
            ])))
        }
    }

    let app = Application(
        router: router,
        server: .http1WebSocketUpgrade(webSocketRouter: router),
        configuration: .init(address: .hostname("0.0.0.0", port: port))
    )
    try await app.runService()
} catch {
    print("Anisette startup error: \(error)")
    exit(1)
}
