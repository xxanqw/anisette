import Foundation
import Testing
@testable import AnisetteServer

@Test func stateRoundTrip() throws {
    let uuid = Data((0..<16).map { UInt8($0) })
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

@Test func windowsStateRoundTrip() throws {
    let identifier = Data((0..<16).map { UInt8($0) })
    let secret = Data(repeating: 0xB4, count: WindowsProvisionedState.tokenSize)
    let original = try WindowsProvisionedState(identifier: identifier, secret: secret)
    let restored = try WindowsProvisionedState(encoded: original.encode())
    #expect(restored.identifier == identifier)
    #expect(restored.matches(original))
}

@Test func windowsStateRejectsWrongToken() throws {
    let identifier = Data(repeating: 0x11, count: 16)
    let original = try WindowsProvisionedState(
        identifier: identifier, secret: Data(repeating: 0x11, count: 32)
    )
    let swapped = try WindowsProvisionedState(
        identifier: identifier, secret: Data(repeating: 0x12, count: 32)
    )
    let matches = original.matches(swapped)
    #expect(matches == false)
    #expect(throws: AnisetteError.self) {
        try WindowsProvisionedState(encoded: Data(original.encode().dropLast()))
    }
    #expect(throws: AnisetteError.self) {
        try WindowsProvisionedState(encoded: Data("MADIv1".utf8))
    }
}

@Test func windowsWorkerParsesCRLFResponses() throws {
    #expect(try WindowsWorkerProtocol.parseLine(Array("OK\\r".utf8)).isEmpty)
    #expect(try WindowsWorkerProtocol.parseLine(Array("OK\\tYWJj\\t17\\r".utf8)) == ["YWJj", "17"])
    #expect(try WindowsWorkerProtocol.parseLine(Array("OK".utf8)).isEmpty)
}

@Test func windowsWorkerRejectsErrorFrames() {
    #expect(throws: AnisetteError.self) {
        try WindowsWorkerProtocol.parseLine(Array("ERR\\t-45001\\r".utf8))
    }
}
