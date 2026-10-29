import Testing
@testable import hexagon
import Foundation

// The catalogue file is shared with Android, so this fixture is too: Android's CatalogCodecTest
// decodes the very same text. Change it in both places or in neither. Every field holds something
// other than its default, so a field one side forgets to write cannot pass unnoticed, and the keys
// are bytes whose base64url differs from plain base64.
private let sharedFixture = """
{
  "version": 1,
  "contacts": [
    {
      "id": "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b",
      "pseudonym": "Bob",
      "verifyKey": "-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_s",
      "encKey": "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI",
      "verificationLevel": "veryHigh",
      "verifiedAt": "2026-10-29T07:27:35.457Z",
      "addedAt": "2026-10-28T19:32:50.123Z",
      "relayBaseUrl": "https://relay.example.org",
      "cipherSuite": "ed25519+x25519-v1",
      "nickname": "Bobby",
      "revokedVerifyKeys": ["_Pz8_Pz8_Pz8_Pz8_Pz8_Pz8_Pz8_Pz8_Pz8_Pz8_Pw"],
      "keyChangedAt": "2026-10-29T08:00:00.001Z",
      "heartbeatOptedOutAt": "2026-10-29T09:15:42.999Z",
      "lastHeartbeatSentAt": "2026-10-29T10:00:00.500Z",
      "heartbeatEmissionOptedOut": true
    }
  ],
  "secrets": [
    {
      "id": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
      "label": "S1",
      "k": 2,
      "n": 3,
      "mimeType": "text/plain",
      "secretCreatedAt": "2026-10-29T07:27:15.657Z",
      "state": "destroying"
    }
  ],
  "shareMetadata": [
    {
      "id": "10a39134-615c-4d28-8e19-a1f9f4a926ba",
      "secretId": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
      "contactId": "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b",
      "lastConfirmedAt": "2026-10-29T07:29:56.809Z"
    }
  ]
}
"""

private func ms(_ date: Date?) -> Int64? { date.map(PayloadCanonical.epochMilliseconds) }

private func jsonObject(_ data: Data) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

@Test func theSharedFixtureDecodesFieldByField() throws {
    let catalog = try CatalogCodec.decode(Data(sharedFixture.utf8))

    let contact = try #require(catalog.contacts.first)
    #expect(contact.id == UUID(uuidString: "6F1C2A3B-4D5E-4F60-8A7B-9C0D1E2F3A4B"))
    #expect(contact.pseudonym == "Bob")
    #expect(contact.verifyKey == Data(repeating: 0xFB, count: 32))
    #expect(contact.encKey == Data(repeating: 0x02, count: 32))
    #expect(contact.verificationLevel == .veryHigh)
    #expect(ms(contact.verifiedAt) == 1793258855457)
    #expect(ms(contact.addedAt) == 1793215970123)
    #expect(contact.relayBaseUrl == "https://relay.example.org")
    #expect(contact.cipherSuite == .ed25519X25519V1)
    #expect(contact.nickname == "Bobby")
    #expect(contact.revokedVerifyKeys == [Data(repeating: 0xFC, count: 32)])
    #expect(ms(contact.keyChangedAt) == 1793260800001)
    #expect(ms(contact.heartbeatOptedOutAt) == 1793265342999)
    #expect(ms(contact.lastHeartbeatSentAt) == 1793268000500)
    #expect(contact.heartbeatEmissionOptedOut)

    let secret = try #require(catalog.secrets.first)
    #expect(secret.id == UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"))
    #expect(secret.label == "S1")
    #expect(secret.k == 2 && secret.n == 3)
    #expect(secret.mimeType == MimeType("text/plain"))
    #expect(ms(secret.secretCreatedAt) == 1793258835657)
    #expect(secret.state == .destroying)

    let meta = try #require(catalog.shareMetadata.first)
    #expect(meta.id == UUID(uuidString: "10A39134-615C-4D28-8E19-A1F9F4A926BA"))
    #expect(meta.secretId == secret.id)
    #expect(meta.contactId == contact.id)
    #expect(ms(meta.lastConfirmedAt) == 1793258996809)
}

@Test func theSharedFixtureEncodesBackToItself() throws {
    let fixture = Data(sharedFixture.utf8)

    let encoded = try CatalogCodec.encode(try CatalogCodec.decode(fixture))

    #expect(try jsonObject(encoded) == jsonObject(fixture))
}

// Android writes nothing for a field still at its default, so a contact can arrive with only the
// fields that have none.
@Test func aContactWithOnlyItsRequiredFieldsDecodesWithTheDefaults() throws {
    let catalog = try CatalogCodec.decode(Data("""
    {"version": 1, "secrets": [], "shareMetadata": [], "contacts": [{
      "id": "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b", "pseudonym": "Bob",
      "verifyKey": "-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_s",
      "encKey": "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI",
      "verificationLevel": "low", "verifiedAt": null,
      "addedAt": "2026-10-28T19:32:50.123Z", "cipherSuite": "ed25519+x25519-v1"
    }]}
    """.utf8))

    let contact = try #require(catalog.contacts.first)
    #expect(contact.verifiedAt == nil)
    #expect(contact.relayBaseUrl == nil)
    #expect(contact.nickname == nil)
    #expect(contact.revokedVerifyKeys.isEmpty)
    #expect(contact.keyChangedAt == nil)
    #expect(!contact.heartbeatEmissionOptedOut)
}

// Kotlin's Instant.toString leaves the fraction out on a whole second and writes six or nine
// digits when it has them, so a reader takes all of it.
@Test func timesAreReadWithAnyNumberOfFractionalDigitsAndIdsInEitherCase() throws {
    let catalog = try CatalogCodec.decode(Data("""
    {"version": 1, "contacts": [], "shareMetadata": [], "secrets": [{
      "id": "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D", "label": "S1", "k": 2, "n": 3,
      "mimeType": "text/plain", "secretCreatedAt": "2026-10-29T07:27:15Z", "state": "active"
    }, {
      "id": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4e", "label": "S2", "k": 2, "n": 3,
      "mimeType": "text/plain", "secretCreatedAt": "2026-10-29T07:27:15.657123Z", "state": "active"
    }]}
    """.utf8))

    #expect(catalog.secrets.map { ms($0.secretCreatedAt) } == [1793258835000, 1793258835657])
    #expect(catalog.secrets.first?.id == UUID(uuidString: "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"))
}

@Test func aCatalogOfAnotherVersionIsRefused() {
    #expect(throws: CatalogCodecError.unsupportedVersion(2)) {
        try CatalogCodec.decode(Data(#"{"version": 2, "contacts": [], "secrets": [], "shareMetadata": []}"#.utf8))
    }
    #expect(throws: (any Error).self) {
        try CatalogCodec.decode(Data(#"{"contacts": [], "secrets": [], "shareMetadata": []}"#.utf8))
    }
}

// A property added to a domain type has to be added to the catalogue too, or a restore silently
// drops it. The wire keys are the property names, so the encoding has to name every one.
@Test func everyStoredPropertyOfTheDomainTypesIsWritten() throws {
    let catalog = try CatalogCodec.decode(Data(sharedFixture.utf8))
    let encoded = try jsonObject(try CatalogCodec.encode(catalog))

    func keys(_ section: String) throws -> Set<String> {
        let first = try #require((encoded[section] as? [NSDictionary])?.first)
        return Set(first.allKeys.compactMap { $0 as? String })
    }
    func properties(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    #expect(properties(try #require(catalog.contacts.first)).subtracting(try keys("contacts")).isEmpty)
    #expect(properties(try #require(catalog.secrets.first)).subtracting(try keys("secrets")).isEmpty)
    #expect(properties(try #require(catalog.shareMetadata.first)).subtracting(try keys("shareMetadata")).isEmpty)
}
