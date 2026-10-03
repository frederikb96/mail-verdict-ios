import Foundation

// Mirrors mail_verdict/api/schemas.py's pipeline stage and rule-assistant shapes
// (api/pipeline.py). Only the pieces the rule assistant reads or writes are modeled.

/// One stage as stored in a pipeline revision. `config` is the stage's own free-form settings --
/// carried through untouched, since only the server interprets it.
public struct StageOut: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "StageOut"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case stageId = "stage_id", type, name, config, enabled, halt, accounts
    }
    public typealias CodingKeys = ContractKeys

    public let stageId: String
    public let type: String
    public let name: String
    public let config: [String: MVAnyJSON]
    public let enabled: Bool
    public let halt: Bool
    /// `nil` means every account.
    public let accounts: [UUID]?

    public init(
        stageId: String, type: String, name: String, config: [String: MVAnyJSON], enabled: Bool,
        halt: Bool, accounts: [UUID]? = nil
    ) {
        self.stageId = stageId
        self.type = type
        self.name = name
        self.config = config
        self.enabled = enabled
        self.halt = halt
        self.accounts = accounts
    }
}

/// Adds one stage at the end of the current pipeline. `baseRevision` makes the write fail with a
/// `409` when the rules changed since the proposal was made.
public struct StageCreateRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "StageCreateRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case stageId = "stage_id", type, name, config, enabled, halt, accounts,
            baseRevision = "base_revision", position
    }
    public typealias CodingKeys = ContractKeys

    public let stageId: String
    public let type: String
    public let name: String?
    @MVDefaulted<MVDefaultEmptyObject> public var config: [String: MVAnyJSON]
    @MVDefaulted<MVDefaultTrue> public var enabled: Bool
    @MVDefaulted<MVDefaultFalse> public var halt: Bool
    public let accounts: [UUID]?
    public let baseRevision: Int?
    public let position: Int?

    public init(
        stageId: String, type: String, name: String? = nil, config: [String: MVAnyJSON] = [:],
        enabled: Bool = true, halt: Bool = false, accounts: [UUID]? = nil, baseRevision: Int? = nil,
        position: Int? = nil
    ) {
        self.stageId = stageId
        self.type = type
        self.name = name
        self.config = config
        self.enabled = enabled
        self.halt = halt
        self.accounts = accounts
        self.baseRevision = baseRevision
        self.position = position
    }
}

/// A partial update to one stage: an omitted (`nil`) field is left as it is.
public struct StageUpdateRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "StageUpdateRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case name, config, enabled, halt, accounts, baseRevision = "base_revision"
    }
    public typealias CodingKeys = ContractKeys

    public let name: String?
    public let config: [String: MVAnyJSON]?
    public let enabled: Bool?
    public let halt: Bool?
    public let accounts: [UUID]?
    public let baseRevision: Int?

    public init(
        name: String? = nil, config: [String: MVAnyJSON]? = nil, enabled: Bool? = nil, halt: Bool? = nil,
        accounts: [UUID]? = nil, baseRevision: Int? = nil
    ) {
        self.name = name
        self.config = config
        self.enabled = enabled
        self.halt = halt
        self.accounts = accounts
        self.baseRevision = baseRevision
    }
}

/// One sentence about the open mail, for the assistant to turn into one rule change.
public struct RuleAssistantRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "RuleAssistantRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable { case messageId = "message_id", prompt }
    public typealias CodingKeys = ContractKeys

    /// The server refuses a longer prompt.
    public static let maxPromptLength = 1000

    public let messageId: UUID
    public let prompt: String

    public init(messageId: UUID, prompt: String) {
        self.messageId = messageId
        self.prompt = prompt
    }
}

/// The one change the assistant proposes. `stage` is the complete stage as it should be after
/// Accept; Accept is an ordinary pipeline write (create when `isNew`, else update) carrying
/// `baseRevision`.
public struct RuleAssistantChange: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "RuleAssistantChange"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case kind, baseRevision = "base_revision", isNew = "is_new", stage, title,
            beforeText = "before_text", afterText = "after_text", effectsText = "effects_text"
    }
    public typealias CodingKeys = ContractKeys

    /// `add_condition`, `new_rule` or `replace_rule`.
    public let kind: String
    public let baseRevision: Int
    public let isNew: Bool
    public let stage: StageOut
    public let title: String
    /// The rule as it reads today; present for a replaced rule only.
    public let beforeText: String?
    public let afterText: String
    /// An `add_condition` proposal's existing rule effects as JSON text -- what the rule being
    /// widened actually does.
    public let effectsText: String?

    public init(
        kind: String, baseRevision: Int, isNew: Bool, stage: StageOut, title: String, beforeText: String?,
        afterText: String, effectsText: String? = nil
    ) {
        self.effectsText = effectsText
        self.kind = kind
        self.baseRevision = baseRevision
        self.isNew = isNew
        self.stage = stage
        self.title = title
        self.beforeText = beforeText
        self.afterText = afterText
    }
}

/// One recent mail the changed rule newly catches.
public struct RuleAssistantPreviewExample: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "RuleAssistantPreviewExample"
    public enum ContractKeys: String, CodingKey, CaseIterable { case fromAddr = "from_addr", subject }
    public typealias CodingKeys = ContractKeys

    public let fromAddr: String
    public let subject: String

    public init(fromAddr: String, subject: String) {
        self.fromAddr = fromAddr
        self.subject = subject
    }
}

/// What the change would have done to the account's newest mails.
public struct RuleAssistantPreview: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "RuleAssistantPreview"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case sampleSize = "sample_size", matchedBefore = "matched_before", matchedAfter = "matched_after",
            examples
    }
    public typealias CodingKeys = ContractKeys

    public let sampleSize: Int
    public let matchedBefore: Int
    public let matchedAfter: Int
    public let examples: [RuleAssistantPreviewExample]

    public init(
        sampleSize: Int, matchedBefore: Int, matchedAfter: Int, examples: [RuleAssistantPreviewExample]
    ) {
        self.sampleSize = sampleSize
        self.matchedBefore = matchedBefore
        self.matchedAfter = matchedAfter
        self.examples = examples
    }

    /// "Would have caught N of your last M mails (now: K)".
    public var summaryLine: String {
        "Would have caught \(matchedAfter) of your last \(sampleSize) mails (now: \(matchedBefore))"
    }
}

/// The assistant's answer. `change` is `nil` when there is nothing to accept; `message` then says
/// why.
public struct RuleAssistantResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "RuleAssistantResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case message, change, preview, warnings, model, modelCalls = "model_calls"
    }
    public typealias CodingKeys = ContractKeys

    public let message: String
    public let change: RuleAssistantChange?
    public let preview: RuleAssistantPreview?
    @MVDefaulted<MVDefaultEmptyArray<String>> public var warnings: [String]
    public let model: String
    public let modelCalls: Int

    public init(
        message: String, change: RuleAssistantChange?, preview: RuleAssistantPreview?, warnings: [String],
        model: String, modelCalls: Int
    ) {
        self.message = message
        self.change = change
        self.preview = preview
        self.warnings = warnings
        self.model = model
        self.modelCalls = modelCalls
    }
}
