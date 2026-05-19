import Foundation
import CryptoKit

struct ApiError: Error, LocalizedError {
    let statusCode: Int
    let body: String
    var errorDescription: String? { "HTTP \(statusCode): \(body)" }
}

final class DeposplitApiAdapter: ShareTransport {

    private let auth: any Identity
    private let baseURL: String

    init(auth: any Identity, baseURL: String = "https://api.deposplit.com") {
        self.auth = auth
        self.baseURL = baseURL
    }

    // MARK: - ShareTransport

    func depositShare(secretId: UUID, label: String, recipientKey: Data, ciphertext: Data) async throws -> ShareMetadata {
        let body = ShareDepositJSON(
            secretId: secretId.uuidString,
            label: label,
            recipientKey: recipientKey.base64URLEncoded,
            ciphertext: ciphertext.base64EncodedString()
        )
        let data = try await execute("POST", path: "/shares", body: body)
        return try JSONDecoder().decode(ShareMetadataJSON.self, from: data).toDomain()
    }

    func listShares(role: Role, counterpartyKey: Data?) async throws -> [ShareMetadata] {
        var query = "?role=\(role.rawValue)"
        if let key = counterpartyKey { query += "&counterpartyKey=\(key.base64URLEncoded)" }
        let data = try await execute("GET", path: "/shares\(query)")
        return try JSONDecoder().decode([ShareMetadataJSON].self, from: data).map { $0.toDomain() }
    }

    func deleteShare(shareId: UUID) async throws {
        _ = try await execute("DELETE", path: "/shares/\(shareId)")
    }

    func openShareRequest(shareId: UUID, type: ShareRequestType) async throws -> ShareRequest {
        let body = OpenShareRequestJSON(shareId: shareId.uuidString, requestType: type.rawValue)
        let data = try await execute("POST", path: "/share-requests", body: body)
        return try JSONDecoder().decode(ShareRequestJSON.self, from: data).toDomain()
    }

    func listShareRequests(role: Role, state: ShareRequestState?) async throws -> [ShareRequest] {
        var query = "?role=\(role.rawValue)"
        if let s = state { query += "&state=\(s.rawValue)" }
        let data = try await execute("GET", path: "/share-requests\(query)")
        return try JSONDecoder().decode([ShareRequestJSON].self, from: data).map { $0.toDomain() }
    }

    func getShareRequest(requestId: UUID) async throws -> ShareRequest {
        let data = try await execute("GET", path: "/share-requests/\(requestId)")
        return try JSONDecoder().decode(ShareRequestJSON.self, from: data).toDomain()
    }

    func pickUpShare(shareId: UUID) async throws -> Data {
        let data = try await execute("GET", path: "/shares/\(shareId)")
        let json = try JSONDecoder().decode(PickUpShareResponseJSON.self, from: data)
        return Data(base64Encoded: json.ciphertext) ?? Data()
    }

    func respondToShareRequest(requestId: UUID, approved: Bool, ciphertext: Data?) async throws -> ShareRequest {
        let body = RespondJSON(
            state: approved ? "approved" : "denied",
            ciphertext: ciphertext?.base64EncodedString()
        )
        let data = try await execute("PATCH", path: "/share-requests/\(requestId)", body: body)
        return try JSONDecoder().decode(ShareRequestJSON.self, from: data).toDomain()
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
        let sig = try auth.sign(Data(canonical.utf8))

        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(auth.edPublicKey.base64URLEncoded, forHTTPHeaderField: "X-Deposplit-Public-Key")
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

    private struct ShareDepositJSON: Encodable {
        let secretId: String
        let label: String
        let recipientKey: String
        let ciphertext: String
    }

    private struct ShareMetadataJSON: Decodable {
        let id: String
        let secretId: String
        let label: String
        let senderKey: String
        let recipientKey: String
        let createdAt: String

        func toDomain() -> ShareMetadata {
            ShareMetadata(
                id: UUID(uuidString: id) ?? UUID(),
                secretId: UUID(uuidString: secretId) ?? UUID(),
                label: label,
                senderKey: Data(base64URLEncoded: senderKey) ?? Data(),
                recipientKey: Data(base64URLEncoded: recipientKey) ?? Data(),
                createdAt: createdAt
            )
        }
    }

    private struct OpenShareRequestJSON: Encodable {
        let shareId: String
        let requestType: String
    }

    private struct PickUpShareResponseJSON: Decodable {
        let ciphertext: String
    }

    private struct RespondJSON: Encodable {
        let state: String
        let ciphertext: String?
    }

    private struct ShareRequestJSON: Decodable {
        let id: String
        let share: ShareMetadataJSON
        let requestType: String
        let state: String
        let requestedAt: String
        let respondedAt: String?
        let ciphertext: String?

        func toDomain() -> ShareRequest {
            ShareRequest(
                id: UUID(uuidString: id) ?? UUID(),
                share: share.toDomain(),
                requestType: ShareRequestType(rawValue: requestType) ?? .retrieve,
                state: ShareRequestState(rawValue: state) ?? .pending,
                requestedAt: requestedAt,
                respondedAt: respondedAt,
                ciphertext: ciphertext.flatMap { Data(base64Encoded: $0) }
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
