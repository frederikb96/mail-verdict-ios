import Foundation
import Observation

/// One sentence about the open mail becomes one proposed change to the rules -- any number of rules
/// added, changed, moved or removed -- which is accepted or declined as a whole, with no history and
/// no second prompt. Dismissing the sheet calls `cancel()`, which
/// drops a request still running; the server stops before its next model call once the
/// connection closes.
@Observable
@MainActor
public final class RuleAssistantStore {
    public enum Phase: Equatable, Sendable {
        case prompt
        case running
        case result(RuleAssistantResponse, RuleAssistantChange)
        /// The assistant answered without a change; the text says why.
        case empty(String)
        case failed(String)
        case accepted
    }

    /// What `409` means here: someone (or something) edited the rules after the proposal was made.
    public static let rulesChangedMessage = "Rules changed meanwhile — ask again."
    public static let timedOutMessage = "The assistant took too long. Try again."

    public let messageId: UUID
    public var promptText = ""
    public private(set) var phase: Phase = .prompt
    public private(set) var isAccepting = false
    /// The request currently running, for a caller (or a test) that needs to wait for it.
    public private(set) var inFlight: Task<Void, Never>?

    private let apiClient: MVApiClient
    /// Set synchronously: `phase` is a render snapshot, so two fast taps reaching a handler would
    /// both read it as idle.
    private var isBusy = false
    /// Bumped whenever a request is superseded or cancelled, so a late answer from the old one
    /// never lands.
    private var generation = 0

    public init(messageId: UUID, apiClient: MVApiClient) {
        self.messageId = messageId
        self.apiClient = apiClient
    }

    public var trimmedPrompt: String { promptText.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var canSend: Bool {
        !trimmedPrompt.isEmpty && trimmedPrompt.count <= RuleAssistantRequest.maxPromptLength && !isBusy
    }

    public func send() {
        guard canSend else { return }
        isBusy = true
        phase = .running
        generation += 1
        let token = generation
        let prompt = trimmedPrompt
        inFlight = Task { [apiClient, messageId] in
            let outcome: Phase
            do {
                let response = try await apiClient.proposeRule(messageId: messageId, prompt: prompt)
                outcome = response.change.map { .result(response, $0) } ?? .empty(response.message)
            } catch {
                if error.mvIsCancellation { return }
                outcome = .failed(Self.message(for: error))
            }
            guard token == self.generation else { return }
            self.phase = outcome
            self.isBusy = false
        }
    }

    /// Writes the proposed document through the ordinary pipeline route, with the revision the
    /// proposal was made against.
    public func accept() {
        guard case .result(_, let change) = phase, !isBusy else { return }
        isBusy = true
        isAccepting = true
        generation += 1
        let token = generation
        inFlight = Task { [apiClient] in
            let outcome: Phase
            do {
                try await apiClient.replacePipeline(change.writeRequest)
                outcome = .accepted
            } catch {
                if error.mvIsCancellation { return }
                outcome = .failed(Self.message(for: error))
            }
            guard token == self.generation else { return }
            self.phase = outcome
            self.isAccepting = false
            self.isBusy = false
        }
    }

    /// Back to an empty prompt, dropping whatever is running or shown. Called when the sheet goes
    /// away, and by Decline.
    public func cancel() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        isBusy = false
        isAccepting = false
        promptText = ""
        phase = .prompt
    }

    private static func message(for error: Error) -> String {
        if let error = error as? MVError {
            switch error {
            case .detail(_, let statusCode), .http(let statusCode, _):
                if statusCode == 409 { return rulesChangedMessage }
            default: break
            }
        }
        if (error as? URLError)?.code == .timedOut { return timedOutMessage }
        return error.mvUserMessage
    }
}
