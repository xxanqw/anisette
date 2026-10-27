import Foundation
import Hummingbird

enum AnisetteProtocol {
    static let clientInfo = "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    static let userAgent = "akd/1.0 CFNetwork/808.1.4"
    static let dsID: Int64 = -2
    // Legacy V3 clients do not return Apple's routing with PTM/TK.
    // Match the long-standing RINFO used by the original V3 server.
    static let defaultRouting: UInt64 = 17_106_176

    static func decodeBase64(_ text: String?, named key: String, maxBytes: Int = 1_048_576) throws -> Data {
        guard let text, text.utf8.count <= (maxBytes * 4 / 3) + 4,
              let decoded = Data(base64Encoded: text),
              decoded.count <= maxBytes else {
            throw AnisetteError.invalidInput("Missing or invalid \(key)")
        }
        return decoded
    }

    static func parseMessage(_ text: String) throws -> [String: String] {
        guard let data = text.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw AnisetteError.invalidInput("Expected a JSON string object")
        }
        return value
    }

    static func encodeMessage(_ object: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

enum AnisetteError: Error, CustomStringConvertible {
    case invalidInput(String)
    case unavailable(String)
    case coreADI(String)

    var description: String {
        switch self {
        case .invalidInput(let message), .unavailable(let message), .coreADI(let message):
            return message
        }
    }
}

/// Opaque to AltStore. Unlike the Android adi.pb, this contains the entire
/// macOS emulated filesystem store, plus the matching machine UUID.
struct ProvisionedState {
    static let magic = Data("MADIv1".utf8)
    static let maxStoreBytes = 4 * 1_048_576

    let hostUUID: Data
    let store: Data

    func encode() throws -> Data {
        guard hostUUID.count == 16, store.count <= Self.maxStoreBytes else {
            throw AnisetteError.invalidInput("Invalid CoreADI state")
        }
        var output = Self.magic
        output.append(hostUUID)
        let size = UInt32(store.count)
        output.append(contentsOf: [
            UInt8(truncatingIfNeeded: size >> 24),
            UInt8(truncatingIfNeeded: size >> 16),
            UInt8(truncatingIfNeeded: size >> 8),
            UInt8(truncatingIfNeeded: size),
        ])
        output.append(store)
        return output
    }

    init(hostUUID: Data, store: Data) {
        self.hostUUID = hostUUID
        self.store = store
    }

    init(encoded: Data) throws {
        let headerSize = Self.magic.count + 16 + 4
        guard encoded.count >= headerSize, encoded.prefix(Self.magic.count) == Self.magic else {
            throw AnisetteError.invalidInput("Unsupported ADI state format")
        }
        let uuidStart = Self.magic.count
        let sizeStart = uuidStart + 16
        let len = encoded[sizeStart..<(sizeStart + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard len <= UInt32(Self.maxStoreBytes), encoded.count == headerSize + Int(len) else {
            throw AnisetteError.invalidInput("Corrupt ADI state")
        }
        self.hostUUID = Data(encoded[uuidStart..<sizeStart])
        self.store = Data(encoded[headerSize...])
    }
}

struct ClientInfoResponse: ResponseCodable {
    let clientInfo: String
    let userAgent: String

    enum CodingKeys: String, CodingKey {
        case clientInfo = "client_info"
        case userAgent = "user_agent"
    }
}

struct HeadersRequest: Decodable {
    let identifier: String
    let adiPB: String

    enum CodingKeys: String, CodingKey {
        case identifier
        case adiPB = "adi_pb"
    }
}

struct HeadersResponse: ResponseCodable {
    let result: String
    let message: String?
    let md: String?
    let machineIdentifier: String?
    let routing: String?

    enum CodingKeys: String, CodingKey {
        case result, message
        case md = "X-Apple-I-MD"
        case machineIdentifier = "X-Apple-I-MD-M"
        case routing = "X-Apple-I-MD-RINFO"
    }

    static func success(mid: Data, otp: Data, routing: UInt64) -> HeadersResponse {
        .init(result: "Headers", message: nil, md: otp.base64EncodedString(),
              machineIdentifier: mid.base64EncodedString(), routing: String(routing))
    }

    static func failure(_ message: String) -> HeadersResponse {
        .init(result: "GetHeadersError", message: message, md: nil,
              machineIdentifier: nil, routing: nil)
    }
}
