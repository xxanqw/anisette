import Foundation
import CADI

/// Owns one Rust ADI emulation session. All access is serialized by MacADIEngine.
private final class ADIHandle {
    let pointer: OpaquePointer

    init(image: Data, hostUUID: Data) throws {
        var handle: OpaquePointer?
        let status = image.withUnsafeBytes { bytes in
            adi_open(bytes.bindMemory(to: UInt8.self).baseAddress, image.count, &handle)
        }
        guard status == 0, let handle else {
            throw AnisetteError.coreADI("adi_open: \(Self.lastError())")
        }
        let uuidStatus = hostUUID.withUnsafeBytes { bytes in
            adi_set_host_uuid(handle, bytes.bindMemory(to: UInt8.self).baseAddress)
        }
        guard uuidStatus == 0 else {
            let reason = Self.lastError()
            adi_close(handle)
            throw AnisetteError.coreADI("adi_set_host_uuid: \(reason)")
        }
        pointer = handle
    }

    deinit {
        adi_close(pointer)
    }

    static func lastError() -> String {
        var buffer = [CChar](repeating: 0, count: 2_048)
        _ = buffer.withUnsafeMutableBufferPointer { ptr in
            adi_last_error(ptr.baseAddress, ptr.count)
        }
        return buffer.withUnsafeBufferPointer {
            guard let start = $0.baseAddress else { return "Unknown CoreADI error" }
            return String(cString: start)
        }
    }

    static func check(_ status: Int32) throws {
        guard status == 0 else {
            throw AnisetteError.coreADI("CoreADI (\(status)): \(lastError())")
        }
    }

    static func take(_ buffer: AdiBuf) -> Data {
        defer { adi_buf_free(buffer) }
        guard let ptr = buffer.ptr, buffer.len > 0 else { return Data() }
        return Data(bytes: ptr, count: buffer.len)
    }

    func begin(spim: Data) throws -> (UInt32, Data) {
        var cpim = AdiBuf(ptr: nil, len: 0)
        var session: UInt32 = 0
        let result = spim.withUnsafeBytes { bytes in
            adi_provisioning_begin(pointer, AnisetteProtocol.dsID,
                                   bytes.bindMemory(to: UInt8.self).baseAddress, spim.count,
                                   &cpim, &session)
        }
        try Self.check(result)
        return (session, Self.take(cpim))
    }

    func finish(session: UInt32, ptm: Data, tk: Data) throws {
        let result = ptm.withUnsafeBytes { ptmBytes in
            tk.withUnsafeBytes { tkBytes in
                adi_provisioning_finish(
                    pointer, AnisetteProtocol.dsID, session,
                    ptmBytes.bindMemory(to: UInt8.self).baseAddress, ptm.count,
                    tkBytes.bindMemory(to: UInt8.self).baseAddress, tk.count,
                    AnisetteProtocol.defaultRouting
                )
            }
        }
        try Self.check(result)
    }

    func exportStore() throws -> Data {
        var output = AdiBuf(ptr: nil, len: 0)
        try Self.check(adi_store_export(pointer, &output))
        return Self.take(output)
    }

    func importStore(_ value: Data) throws {
        let status = value.withUnsafeBytes { bytes in
            adi_store_import(pointer, bytes.bindMemory(to: UInt8.self).baseAddress, value.count)
        }
        try Self.check(status)
    }

    func headers() throws -> (Data, Data, UInt64) {
        var mid = AdiBuf(ptr: nil, len: 0)
        var otp = AdiBuf(ptr: nil, len: 0)
        var routing: UInt64 = 0
        let status = adi_headers(pointer, AnisetteProtocol.dsID, &mid, &otp, &routing)
        guard status == 0 else {
            adi_buf_free(mid)
            adi_buf_free(otp)
            try Self.check(status)
            throw AnisetteError.coreADI("Headers unavailable")
        }
        return (Self.take(mid), Self.take(otp), routing)
    }
}

/// Prevents concurrent access to a CoreADI instance, in particular during provisioning.
/// No passwords or Apple ID session data are retained by the server.
actor MacADIEngine: AnisetteEngine {
    private struct Pending {
        let handle: ADIHandle
        let hostUUID: Data
        let session: UInt32
    }

    private let image: Data
    private let stateDirectory: URL
    private var pending: [UUID: Pending] = [:]

    init(coreADIPath: String, stateDirectory: String) throws {
        self.stateDirectory = URL(fileURLWithPath: stateDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: self.stateDirectory, withIntermediateDirectories: true
        )
        let url = URL(fileURLWithPath: coreADIPath)
        do {
            image = try Data(contentsOf: url)
        } catch {
            throw AnisetteError.unavailable("Cannot load macOS CoreADI at \(url.path): \(error)")
        }
        guard image.count > 4_096 else {
            throw AnisetteError.unavailable("CoreADI Mach-O binary is missing or too small")
        }
        // Fail fast if CoreADI's SHA or Mach-O layout is not supported.
        let probe = try ADIHandle(image: image, hostUUID: Data(repeating: 0, count: 16))
        _ = probe
    }

    func begin(hostUUID: Data, spim: Data) throws -> (id: UUID, cpim: Data) {
        guard hostUUID.count == 16 else {
            throw AnisetteError.invalidInput("identifier must be 16 bytes")
        }
        guard pending.count < 64 else {
            throw AnisetteError.unavailable("Too many concurrent provisioning sessions")
        }
        let handle = try ADIHandle(image: image, hostUUID: hostUUID)
        let (session, cpim) = try handle.begin(spim: spim)
        let id = UUID()
        pending[id] = Pending(handle: handle, hostUUID: hostUUID, session: session)
        return (id, cpim)
    }

    func finish(id: UUID, ptm: Data, tk: Data) throws -> Data {
        guard let current = pending.removeValue(forKey: id) else {
            throw AnisetteError.invalidInput("Provisioning session expired")
        }
        try current.handle.finish(session: current.session, ptm: ptm, tk: tk)
        let store = try current.handle.exportStore()
        guard !store.isEmpty else {
            throw AnisetteError.coreADI("Provisioning yielded an empty CoreADI store")
        }
        try saveStore(store, hostUUID: current.hostUUID)
        let state = ProvisionedState(hostUUID: current.hostUUID, store: store)
        return try state.encode()
    }

    func cancel(id: UUID) {
        pending.removeValue(forKey: id)
    }

    private func stateURL(for hostUUID: Data) -> URL {
        let filename = hostUUID.map { String(format: "%02x", $0) }.joined()
        return stateDirectory.appendingPathComponent(filename + ".store")
    }

    private func saveStore(_ store: Data, hostUUID: Data) throws {
        try store.write(to: stateURL(for: hostUUID), options: .atomic)
    }

    func headers(hostUUID: Data, stateBytes: Data) throws -> HeadersResponse {
        let state = try ProvisionedState(encoded: stateBytes)
        guard state.hostUUID == hostUUID else {
            throw AnisetteError.invalidInput("identifier does not match the provisioned state")
        }
        let handle = try ADIHandle(image: image, hostUUID: hostUUID)
        let diskState = try? Data(contentsOf: stateURL(for: hostUUID))
        try handle.importStore(diskState ?? state.store)
        let (mid, otp, routing) = try handle.headers()
        try saveStore(try handle.exportStore(), hostUUID: hostUUID)
        return .success(mid: mid, otp: otp, routing: routing)
    }
}
