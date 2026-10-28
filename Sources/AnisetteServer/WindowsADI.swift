import Foundation

/// All backends implement the same V3 protocol. The Mac engine remains the default.
protocol AnisetteEngine: Actor {
    func probe() throws
    func begin(hostUUID: Data, spim: Data) throws -> (id: UUID, cpim: Data)
    func finish(id: UUID, ptm: Data, tk: Data) throws -> Data
    func cancel(id: UUID)
    func headers(hostUUID: Data, stateBytes: Data) throws -> HeadersResponse
}

/// Windows CoreADI persists machine provisioning in the Wine prefix on disk.
/// Unlike the Mac implementation, adi_pb is an opaque capability token, not a DLL store.
struct WindowsProvisionedState {
    static let magic = Data("WADIv1".utf8)
    static let tokenSize = 32

    let identifier: Data
    let secret: Data

    init(identifier: Data, secret: Data) throws {
        guard identifier.count == 16, secret.count == Self.tokenSize else {
            throw AnisetteError.invalidInput("Invalid Windows ADI state")
        }
        self.identifier = identifier
        self.secret = secret
    }

    init(encoded: Data) throws {
        guard encoded.count == Self.magic.count + 16 + Self.tokenSize,
              encoded.prefix(Self.magic.count) == Self.magic else {
            throw AnisetteError.invalidInput("Unsupported Windows ADI state")
        }
        let offset = Self.magic.count
        identifier = Data(encoded[offset..<(offset + 16)])
        secret = Data(encoded[(offset + 16)...])
    }

    func encode() -> Data {
        var bytes = Self.magic
        bytes.append(identifier)
        bytes.append(secret)
        return bytes
    }

    func matches(_ other: WindowsProvisionedState) -> Bool {
        guard identifier == other.identifier, secret.count == other.secret.count else { return false }
        // A client-provided token is a bearer capability; compare without byte-position leakage.
        let difference = zip(secret, other.secret).reduce(UInt8(0)) {
            $0 ^ ($1.0 ^ $1.1)
        }
        return difference == 0
    }
}

/// A Windows program executing the actual, operator-supplied CoreADI64.dll under Wine.
/// Only one command is active per worker, and a provisioning worker stays alive until FINISH.
private final class WineADIWorker {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(wine: String, binary: String, coreADI: String, prefix: String) throws {
        process.executableURL = URL(fileURLWithPath: wine)
        process.arguments = [binary, "Z:" + coreADI.replacingOccurrences(of: "/", with: "\\")]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = prefix
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = "-all"
        process.environment = environment
        try process.run()
        _ = try send(["PING"])
    }

    func send(_ parts: [String]) throws -> [String] {
        guard parts.allSatisfy({ !$0.contains("\n") && !$0.contains("\t") }) else {
            throw AnisetteError.invalidInput("Malformed Windows ADI command")
        }
        let request = (parts.joined(separator: "\t") + "\n").data(using: .utf8)!
        input.fileHandleForWriting.write(request)

        var line = [UInt8]()
        line.reserveCapacity(512)
        while line.count < 2 * 1_048_576 {
            let chunk = output.fileHandleForReading.readData(ofLength: 1)
            guard let byte = chunk.first else {
                throw AnisetteError.unavailable("Windows ADI worker exited unexpectedly")
            }
            if byte == 0x0A { break }
            line.append(byte)
        }
        guard line.count < 2 * 1_048_576,
              let response = String(bytes: line, encoding: .utf8) else {
            throw AnisetteError.unavailable("Invalid Windows ADI worker response")
        }
        let fields = response.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.first == "OK" else {
            throw AnisetteError.coreADI("Windows CoreADI: " + fields.dropFirst().joined(separator: " "))
        }
        return Array(fields.dropFirst())
    }

    func close() {
        if process.isRunning {
            // Do not block cleanup while a worker is hung in a proprietary DLL.
            process.terminate()
        }
    }

    deinit {
        close()
    }
}

/// Experimental Windows V3 backend. Each identifier gets its own Wine prefix,
/// so device provisioning is never shared with unrelated clients.
actor WindowsADIEngine: AnisetteEngine {
    private struct Pending {
        let identifier: Data
        let worker: WineADIWorker
    }

    private let root: URL
    private let winePath: String
    private let workerPath: String
    private let coreADIPath: String
    private var pending: [UUID: Pending] = [:]

    init(stateDirectory: String, winePath: String, workerPath: String, coreADIPath: String) throws {
        for path in [winePath, workerPath, coreADIPath] {
            guard FileManager.default.fileExists(atPath: path) else {
                throw AnisetteError.unavailable("Missing Windows ADI dependency: \(path)")
            }
        }
        self.winePath = winePath
        self.workerPath = workerPath
        self.coreADIPath = coreADIPath
        root = URL(fileURLWithPath: stateDirectory, isDirectory: true)
            .appendingPathComponent("windows", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func directory(for identifier: Data) -> URL {
        let name = identifier.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func worker(for identifier: Data) throws -> WineADIWorker {
        let prefix = directory(for: identifier)
        try FileManager.default.createDirectory(
            at: prefix, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try WineADIWorker(
            wine: winePath, binary: workerPath,
            coreADI: coreADIPath, prefix: prefix.path
        )
    }

    func probe() throws {
        let testWorker = try worker(for: Data(repeating: 0, count: 16))
        testWorker.close()
    }

    func begin(hostUUID: Data, spim: Data) throws -> (id: UUID, cpim: Data) {
        guard hostUUID.count == 16 else {
            throw AnisetteError.invalidInput("identifier must be exactly 16 bytes")
        }
        guard pending.count < 8 else {
            throw AnisetteError.unavailable("Too many Windows ADI sessions")
        }
        let deviceWorker = try worker(for: hostUUID)
        do {
            let values = try deviceWorker.send(["BEGIN", spim.base64EncodedString()])
            guard values.count == 1, let cpim = Data(base64Encoded: values[0]) else {
                throw AnisetteError.unavailable("Invalid Windows ADI CPIM")
            }
            let id = UUID()
            pending[id] = Pending(identifier: hostUUID, worker: deviceWorker)
            return (id, cpim)
        } catch {
            deviceWorker.close()
            throw error
        }
    }

    func finish(id: UUID, ptm: Data, tk: Data) throws -> Data {
        guard let session = pending.removeValue(forKey: id) else {
            throw AnisetteError.invalidInput("Unknown Windows ADI session")
        }
        defer { session.worker.close() }
        let values = try session.worker.send([
            "FINISH", ptm.base64EncodedString(), tk.base64EncodedString(),
        ])
        guard values.isEmpty else {
            throw AnisetteError.unavailable("Unexpected Windows ADI completion response")
        }
        var random = SystemRandomNumberGenerator()
        let secret = Data((0..<WindowsProvisionedState.tokenSize).map {
            _ in UInt8.random(in: 0...255, using: &random)
        })
        let state = try WindowsProvisionedState(identifier: session.identifier, secret: secret)
        let destination = directory(for: session.identifier).appendingPathComponent("token")
        try state.encode().write(to: destination, options: .atomic)
        return state.encode()
    }

    func cancel(id: UUID) {
        guard let session = pending.removeValue(forKey: id) else { return }
        try? session.worker.send(["CANCEL"])
        session.worker.close()
    }

    func headers(hostUUID: Data, stateBytes: Data) throws -> HeadersResponse {
        let received = try WindowsProvisionedState(encoded: stateBytes)
        guard received.identifier == hostUUID else {
            throw AnisetteError.invalidInput("identifier does not match Windows ADI state")
        }
        let tokenPath = directory(for: hostUUID).appendingPathComponent("token")
        let stored = try WindowsProvisionedState(encoded: Data(contentsOf: tokenPath))
        guard received.matches(stored) else {
            throw AnisetteError.invalidInput("Windows ADI state token does not match")
        }
        let deviceWorker = try worker(for: hostUUID)
        defer { deviceWorker.close() }
        let values = try deviceWorker.send(["HEADERS"])
        guard values.count == 3,
              let mid = Data(base64Encoded: values[0]),
              let otp = Data(base64Encoded: values[1]),
              let routing = UInt64(values[2]) else {
            throw AnisetteError.unavailable("Invalid Windows ADI header response")
        }
        return .success(mid: mid, otp: otp, routing: routing)
    }
}
