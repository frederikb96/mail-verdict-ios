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

/// Replaces the whole pipeline document. `baseRevision` makes the write fail with a `409` when the
/// rules changed since the proposal was made.
public struct PipelineWriteRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "PipelineWriteRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case baseRevision = "base_revision", enabled, stages
    }
    public typealias CodingKeys = ContractKeys

    public let baseRevision: Int?
    @MVDefaulted<MVDefaultTrue> public var enabled: Bool
    @MVDefaulted<MVDefaultEmptyArray<StageOut>> public var stages: [StageOut]

    public init(baseRevision: Int?, enabled: Bool, stages: [StageOut]) {
        self.baseRevision = baseRevision
        self.enabled = enabled
        self.stages = stages
    }
}

/// One sentence about the open mail, for the assistant to turn into one proposed change to the rules.
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

/// One rule the proposal adds, changes, moves or removes, each text the whole stage as JSON.
public struct RuleAssistantRuleChange: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "RuleAssistantRuleChange"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case kind, stageId = "stage_id", name, beforeText = "before_text", afterText = "after_text"
    }
    public typealias CodingKeys = ContractKeys

    /// `added`, `changed`, `moved` or `removed`.
    public let kind: String
    public let stageId: String
    public let name: String
    /// `nil` for an added or moved rule.
    public let beforeText: String?
    /// `nil` for a removed rule.
    public let afterText: String?

    public init(kind: String, stageId: String, name: String, beforeText: String?, afterText: String?) {
        self.kind = kind
        self.stageId = stageId
        self.name = name
        self.beforeText = beforeText
        self.afterText = afterText
    }

    /// "New", "Changed", "Moved" or "Removed".
    public var kindLabel: String {
        switch kind {
        case "added": "New"
        case "changed": "Changed"
        case "moved": "Moved"
        case "removed": "Removed"
        default: kind.capitalized
        }
    }
}

/// The change the assistant proposes: the complete pipeline document as it should be after Accept,
/// and the rules in it that differ. Accept replaces the document, carrying `baseRevision`.
public struct RuleAssistantChange: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "RuleAssistantChange"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case baseRevision = "base_revision", enabled, stages, title, rules
    }
    public typealias CodingKeys = ContractKeys

    public let baseRevision: Int
    public let enabled: Bool
    public let stages: [StageOut]
    public let title: String
    public let rules: [RuleAssistantRuleChange]

    public init(baseRevision: Int, enabled: Bool, stages: [StageOut], title: String, rules: [RuleAssistantRuleChange]) {
        self.baseRevision = baseRevision
        self.enabled = enabled
        self.stages = stages
        self.title = title
        self.rules = rules
    }

    /// What Accept sends.
    public var writeRequest: PipelineWriteRequest {
        PipelineWriteRequest(baseRevision: baseRevision, enabled: enabled, stages: stages)
    }
}

/// One recent mail the changed rules newly catch.
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

/// What the rules the change touches catch among the account's newest mails, together, before and after.
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
