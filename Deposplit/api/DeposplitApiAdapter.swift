import hexagon
import Foundation
import CryptoKit

struct ApiError: Error, LocalizedError {
    let statusCode: Int
    let body: String
    var errorDescription: String? { "HTTP \(statusCode): \(body)" }
}

final class DeposplitApiAdapter: ShareRelay {

    private let identity: any Identity
    private let baseURL: String

    init(identity: any Identity, baseURL: String = RelayDefaults.fallbackBaseURL) {
        self.identity = identity
        self.baseURL = baseURL
    }

    // MARK: - ShareRelay

    func openShareRequest(secretId: UUID, recipientKey: Data, label: String, secretCreatedAt: Date, transactionType: ShareTransactionType, shareId: UUID?, ciphertext: Data?, k: Int?, n: Int?, senderSignature: Data) async throws -> ShareRequest {
        let body = OpenShareRequestJSON(
            secretId: secretId.uuidString,
            recipientKey: recipientKey.base64URLEncoded,
            label: label,
            secretCreatedAt: _iso8601.string(from: secretCreatedAt),
            transactionType: transactionType.rawValue,
            shareId: shareId?.uuidString,
            ciphertext: ciphertext?.base64EncodedString(),
            k: k,
            n: n,
            senderSignature: senderSignature.base64URLEncoded
        )
        let data = try await execute("POST", path: "/share-requests", body: body)
        return try JSONDecoder().decode(ShareRequestJSON.self, from: data).toDomain()
    }

    func listShareRequests(role: Role, transactionType: ShareTransactionType?, state: ShareRequestState?) async throws -> [ShareRequest] {
        var query = "?role=\(role.rawValue)"
        if let t = transactionType { query += "&type=\(t.rawValue)" }
        if let s = state { query += "&state=\(s.rawValue)" }
        let data = try await execute("GET", path: "/share-requests\(query)")
        return try JSONDecoder().decode([ShareRequestJSON].self, from: data).map { $0.toDomain() }
    }

    func getShareRequest(requestId: UUID) async throws -> ShareRequest {
        let data = try await execute("GET", path: "/share-requests/\(requestId)")
        return try JSONDecoder().decode(ShareRequestJSON.self, from: data).toDomain()
    }

    func respondToShareRequest(requestId: UUID, approved: Bool, ciphertext: Data?, recipientSignature: Data) async throws -> ShareRequest {
        let body = RespondJSON(
            state: approved ? "approved" : "denied",
            ciphertext: ciphertext?.base64EncodedString(),
            recipientSignature: recipientSignature.base64URLEncoded
        )
        let data = try await execute("PATCH", path: "/share-requests/\(requestId)", body: body)
        return try JSONDecoder().decode(ShareRequestJSON.self, from: data).toDomain()
    }

    func deleteShareRequest(requestId: UUID) async throws {
        _ = try await execute("DELETE", path: "/share-requests/\(requestId)")
    }

    func deleteShareRequests(senderKey: Data?, secretId: UUID?) async throws {
        var query = ""
        var parts: [String] = []
        if let key = senderKey { parts.append("senderKey=\(key.base64URLEncoded)") }
        if let id = secretId { parts.append("secretId=\(id)") }
        if !parts.isEmpty { query = "?" + parts.joined(separator: "&") }
        _ = try await execute("DELETE", path: "/share-requests\(query)")
    }

    func withdrawShareRequests(senderKey: Data?, secretId: UUID?) async throws {
        var query = ""
        var parts: [String] = []
        if let key = senderKey { parts.append("senderKey=\(key.base64URLEncoded)") }
        if let id = secretId { parts.append("secretId=\(id)") }
        if !parts.isEmpty { query = "?" + parts.joined(separator: "&") }
        _ = try await execute("POST", path: "/share-requests/withdraw\(query)")
    }

    func pushRotation(recipientKey: Data, newVerifyKey: Data, newEncKey: Data, newCipherSuite: CipherSuite, signature: Data) async throws {
        let body = PushRotationJSON(
            recipientKey: recipientKey.base64URLEncoded,
            newVerifyKey: newVerifyKey.base64URLEncoded,
            newEncKey: newEncKey.base64URLEncoded,
            newCipherSuite: newCipherSuite.rawValue,
            signature: signature.base64URLEncoded
        )
        _ = try await execute("POST", path: "/key-rotations", body: body)
    }

    func listRotations() async throws -> [KeyRotation] {
        let data = try await execute("GET", path: "/key-rotations")
        return try JSONDecoder().decode([KeyRotationJSON].self, from: data).map { $0.toDomain() }
    }

    func deleteRotation(id: UUID) async throws {
        _ = try await execute("DELETE", path: "/key-rotations/\(id)")
    }

    func pushHeartbeat(ownerKey: Data, secretIds: [UUID], optedOut: Bool, signature: Data) async throws {
        let body = PushHeartbeatJSON(
            ownerKey: ownerKey.base64URLEncoded,
            secretIds: secretIds.map { $0.uuidString },
            optedOut: optedOut,
            signature: signature.base64URLEncoded
        )
        _ = try await execute("POST", path: "/custody-heartbeats", body: body)
    }

    func listHeartbeats() async throws -> [CustodyHeartbeat] {
        let data = try await execute("GET", path: "/custody-heartbeats")
        return try JSONDecoder().decode([CustodyHeartbeatJSON].self, from: data).map { $0.toDomain() }
    }

    // MARK: - HTTP

    private func execute<Body: Encodable>(_ method: String, path: String, body: Body) async throws -> Data {
        let bodyData = try JSONEncoder().encode(body)
        return try await executeRaw(method, path: path, bodyData: bodyData)
    }

    private func execute(_ method: String, path: String) async throws -> Data {
        try await executeRaw(method, path: path, bodyData: nil)
    }

    private func executeRaw(_ method: String, path: String, bodyData: Data?) async throws -> Data {
        let nonce = generateNonce()
        let canonical = buildCanonical(nonce: nonce, method: method, path: path, body: bodyData ?? Data())
        let sig = try identity.sign(Data(canonical.utf8))

        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(identity.verifyKey.base64URLEncoded, forHTTPHeaderField: "X-Deposplit-Verify-Key")
        request.setValue(nonce, forHTTPHeaderField: "X-Deposplit-Nonce")
        request.setValue(sig.base64URLEncoded, forHTTPHeaderField: "X-Deposplit-Signature")
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as! HTTPURLResponse).statusCode
        if code == 204 { return Data() }
        guard code < 400 else {
            throw ApiError(statusCode: code, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func generateNonce() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let random = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        return "\(ms).\(random.map { String(format: "%02x", $0) }.joined())"
    }

    private func buildCanonical(nonce: String, method: String, path: String, body: Data) -> String {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "\(nonce)\n\(method.uppercased())\n\(path)\n\(bodyHash)"
    }

    // MARK: - JSON wire types

    private struct OpenShareRequestJSON: Encodable {
        let secretId: String
        let recipientKey: String
        let label: String
        let secretCreatedAt: String
        let transactionType: String
        let shareId: String?
        let ciphertext: String?
        let k: Int?
        let n: Int?
        let senderSignature: String
    }

    private struct RespondJSON: Encodable {
        let state: String
        let ciphertext: String?
        let recipientSignature: String
    }

    private struct ShareRequestJSON: Decodable {
        let id: String
        let secretId: String
        let senderKey: String
        let recipientKey: String
        let label: String
        let secretCreatedAt: String
        let transactionType: String
        let state: String
        let shareId: String?
        let requestedAt: String
        let respondedAt: String?
        let ciphertext: String?
        let k: Int?
        let n: Int?
        let senderSignature: String
        let recipientSignature: String?

        func toDomain() -> ShareRequest {
            ShareRequest(
                id: UUID(uuidString: id) ?? UUID(),
                secretId: UUID(uuidString: secretId) ?? UUID(),
                senderKey: Data(base64URLEncoded: senderKey) ?? Data(),
                recipientKey: Data(base64URLEncoded: recipientKey) ?? Data(),
                label: label,
                secretCreatedAt: parseISO8601(secretCreatedAt),
                transactionType: ShareTransactionType(rawValue: transactionType) ?? .retrieval,
                state: ShareRequestState(rawValue: state) ?? .pending,
                shareId: shareId.flatMap { UUID(uuidString: $0) },
                requestedAt: parseISO8601(requestedAt),
                respondedAt: respondedAt.map { parseISO8601($0) },
                ciphertext: ciphertext.flatMap { Data(base64Encoded: $0) },
                k: k, n: n,
                senderSignature: Data(base64URLEncoded: senderSignature) ?? Data(),
                recipientSignature: recipientSignature.flatMap { Data(base64URLEncoded: $0) }
            )
        }
    }

    private struct PushRotationJSON: Encodable {
        let recipientKey: String
        let newVerifyKey: String
        let newEncKey: String
        let newCipherSuite: String
        let signature: String
    }

    private struct KeyRotationJSON: Decodable {
        let id: String
        let oldVerifyKey: String
        let recipientKey: String
        let newVerifyKey: String
        let newEncKey: String
        let newCipherSuite: String
        let signature: String
        let createdAt: String

        func toDomain() -> KeyRotation {
            KeyRotation(
                id: UUID(uuidString: id) ?? UUID(),
                oldVerifyKey: Data(base64URLEncoded: oldVerifyKey) ?? Data(),
                recipientKey: Data(base64URLEncoded: recipientKey) ?? Data(),
                newVerifyKey: Data(base64URLEncoded: newVerifyKey) ?? Data(),
                newEncKey: Data(base64URLEncoded: newEncKey) ?? Data(),
                newCipherSuite: CipherSuite(rawValue: newCipherSuite) ?? .current,
                signature: Data(base64URLEncoded: signature) ?? Data(),
                createdAt: parseISO8601(createdAt)
            )
        }
    }

    private struct PushHeartbeatJSON: Encodable {
        let ownerKey: String
        let secretIds: [String]
        let optedOut: Bool
        let signature: String
    }

    private struct CustodyHeartbeatJSON: Decodable {
        let id: String
        let holderKey: String
        let ownerKey: String
        let secretIds: [String]
        let optedOut: Bool
        let signature: String
        let createdAt: String

        func toDomain() -> CustodyHeartbeat {
            CustodyHeartbeat(
                id: UUID(uuidString: id) ?? UUID(),
                holderKey: Data(base64URLEncoded: holderKey) ?? Data(),
                ownerKey: Data(base64URLEncoded: ownerKey) ?? Data(),
                secretIds: secretIds.compactMap { UUID(uuidString: $0) },
                optedOut: optedOut,
                signature: Data(base64URLEncoded: signature) ?? Data(),
                createdAt: parseISO8601(createdAt)
            )
        }
    }
}

// MARK: - Data base64url helpers

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: s)
    }
}

// MARK: - ISO 8601 date parsing

// Two formatters: the server may or may not include fractional seconds.
private let _iso8601Fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let _iso8601: ISO8601DateFormatter = ISO8601DateFormatter()

private func parseISO8601(_ string: String) -> Date {
    _iso8601Fractional.date(from: string) ?? _iso8601.date(from: string) ?? Date()
}
