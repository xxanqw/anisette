import Foundation
import Testing
@testable import AnisetteServer

@Test func stateRoundTrip() throws {
    let uuid = Data(0..<16)
    let store = Data([0x00, 0xFF, 0x42, 0x01])
    let packed = try ProvisionedState(hostUUID: uuid, store: store).encode()
    let unpacked = try ProvisionedState(encoded: packed)
    #expect(unpacked.hostUUID == uuid)
    #expect(unpacked.store == store)
}

@Test func stateRejectsTruncatedContent() throws {
    let packed = try ProvisionedState(
        hostUUID: Data(repeating: 0x33, count: 16),
        store: Data([1, 2, 3])
    ).encode()
    #expect(throws: AnisetteError.self) {
        try ProvisionedState(encoded: Data(packed.dropLast()))
    }
}

@Test func stateRejectsUnknownFormats() {
    #expect(throws: AnisetteError.self) {
        try ProvisionedState(encoded: Data(repeating: 0, count: 50))
    }
}

@Test func jsonWireProtocol() throws {
    let json = try AnisetteProtocol.encodeMessage([
        "result": "GiveEndProvisioningData",
        "cpim": "AAECAw==",
    ])
    let parsed = try AnisetteProtocol.parseMessage(json)
    #expect(parsed["result"] == "GiveEndProvisioningData")
    #expect(parsed["cpim"] == "AAECAw==")
}

@Test func decodingRejectsOversizedIdentifiers() {
    let oversized = Data(repeating: 0x42, count: 17).base64EncodedString()
    #expect(throws: AnisetteError.self) {
        try AnisetteProtocol.decodeBase64(oversized, named: "identifier", maxBytes: 16)
    }
}
