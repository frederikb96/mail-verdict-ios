import Foundation
import MailVerdictKit

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The push relay's answer to a registration: a sealed ticket bound to this device's APNs token,
/// which only the relay can open. Stored and forwarded verbatim, never parsed.
public struct PushTicket: Sendable, Equatable {
    public let ticket: String
    /// A non-secret fingerprint of the ticket, safe to log.
    public let ticketId: String
    public let expiresAt: Date

    public init(ticket: String, ticketId: String, expiresAt: Date) {
        self.ticket = ticket
        self.ticketId = ticketId
        self.expiresAt = expiresAt
    }
}

public enum PushRelayError: Error, Equatable, Sendable {
    case rateLimited
    case rejected(String)
    case http(statusCode: Int)
    case transport(String)
    case malformedResponse

    public var userMessage: String {
        switch self {
        case .rateLimited: return "The push relay is busy. Try again in a few minutes."
        case .rejected(let detail): return "The push relay refused this device: \(detail)"
        case .http(let code): return "The push relay answered HTTP \(code)."
        case .transport(let detail): return "The push relay could not be reached: \(detail)"
        case .malformedResponse: return "The push relay sent a response this app does not understand."
        }
    }
}

public protocol PushRelayRegistering: Sendable {
    func register(apnsToken: String) async throws -> PushTicket
}

/// `POST /v1/register` on the push relay (its contract: `relay/README.md` in this repository).
///
/// The relay takes no credential and is a different service from the MailVerdict server, so this
/// deliberately does not go through `MVApiClient`: the backend's credential must never reach it.
public struct PushRelayClient: PushRelayRegistering {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .mvDefault) {
        self.baseURL = baseURL
        self.session = session
    }

    public func register(apnsToken: String) async throws -> PushTicket {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["apns_token": apnsToken])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PushRelayError.transport(error.mvUserMessage)
        }
        guard let http = response as? HTTPURLResponse else { throw PushRelayError.malformedResponse }

        switch http.statusCode {
        case 200:
            guard let body = try? JSONDecoder().decode(RegisterResponse.self, from: data),
                let expiresAt = Self.parseDate(body.expiresAt)
            else {
                throw PushRelayError.malformedResponse
            }
            return PushTicket(ticket: body.ticket, ticketId: body.ticketId, expiresAt: expiresAt)
        case 429:
            throw PushRelayError.rateLimited
        case 400:
            // The relay answers 400 with a short plain-text reason, not JSON.
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PushRelayError.rejected(detail)
        default:
            throw PushRelayError.http(statusCode: http.statusCode)
        }
    }

    private struct RegisterResponse: Decodable {
        let ticket: String
        let ticketId: String
        let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case ticket, ticketId = "ticket_id", expiresAt = "expires_at"
        }
    }

    /// RFC 3339, with or without fractional seconds.
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
