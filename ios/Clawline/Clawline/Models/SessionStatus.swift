//
//  SessionStatus.swift
//  Clawline
//
//  Created by Codex on 4/29/26.
//

import Foundation

struct SessionStatus: Decodable, Equatable {
    let sessionKey: String
    let display: Display
    let run: Run
    let context: Context?
    let approval: Approval?
    let capabilities: Capabilities
    let modelCatalog: ModelCatalog?
    let metadataContextGeneration: String?

    init(
        sessionKey: String,
        display: Display,
        run: Run,
        context: Context?,
        approval: Approval?,
        capabilities: Capabilities,
        modelCatalog: ModelCatalog?,
        metadataContextGeneration: String? = nil
    ) {
        self.sessionKey = sessionKey
        self.display = display
        self.run = run
        self.context = context
        self.approval = approval
        self.capabilities = capabilities
        self.modelCatalog = modelCatalog
        self.metadataContextGeneration = metadataContextGeneration
    }

    struct Display: Decodable, Equatable {
        let model: String?
        let fallbackModels: [String]?
        let provider: String?
        let harness: String?
        let host: String?
        let authMode: String?
        let reasoningLevel: String?
        let thinkingLevel: String?
        let fastMode: Bool?
        let mode: String?
        let verbosity: String?
        let codexUsage: CodexUsage?

        init(
            model: String?,
            fallbackModels: [String]?,
            provider: String?,
            harness: String?,
            host: String? = nil,
            authMode: String? = nil,
            reasoningLevel: String?,
            thinkingLevel: String?,
            fastMode: Bool?,
            mode: String?,
            verbosity: String?,
            codexUsage: CodexUsage? = nil
        ) {
            self.model = model
            self.fallbackModels = fallbackModels
            self.provider = provider
            self.harness = harness
            self.host = host
            self.authMode = authMode
            self.reasoningLevel = reasoningLevel
            self.thinkingLevel = thinkingLevel
            self.fastMode = fastMode
            self.mode = mode
            self.verbosity = verbosity
            self.codexUsage = codexUsage
        }

        struct CodexUsage: Decodable, Equatable {
            enum Freshness: String, Decodable, Equatable {
                case loading
                case fresh
                case stale
                case unavailable
            }

            enum UnavailableReason: String, Decodable, Equatable {
                case accountBindingUnavailable = "account_binding_unavailable"
                case providerUnavailable = "provider_unavailable"
                case timeout
                case invalidUsage = "invalid_usage"
                case staleExpired = "stale_expired"
                case resetElapsed = "reset_elapsed"
            }

            struct Window: Decodable, Equatable {
                enum Label: String, Decodable, Equatable {
                    case fiveHour = "5h"
                    case week = "Week"
                }

                let label: Label
                let remainingPercent: Int
                let resetAt: TimeInterval?
            }

            let freshness: Freshness
            let fetchedAt: TimeInterval?
            let windows: [Window]
            let unavailableReason: UnavailableReason?
        }
    }

    struct Run: Decodable, Equatable {
        enum State: String, Decodable {
            case idle
            case queued
            case running
            case unknown

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let raw = try container.decode(String.self)
                self = State(rawValue: raw) ?? .unknown
            }
        }

        let state: State
        let runId: String?
        let messageId: String?
        let startedAt: TimeInterval?
        let queueDepth: Int?
    }

    struct Context: Decodable, Equatable {
        let available: Bool?
        let compaction: JSONValue?
    }

    struct Approval: Decodable, Equatable {
        let state: String?
    }

    struct Capabilities: Decodable, Equatable {
        let cancelCurrentRun: Capability?
        let setModel: Capability?
        let setThinking: Capability?
        let setReasoning: Capability?
        let setFastMode: Capability?
        let setMode: Capability?
        let setVerbosity: Capability?
        let canCancelCurrentRun: Bool?
        let canChangeModel: Bool?
        let canChangeReasoning: Bool?
        let canChangeFastMode: Bool?
        let canChangeVerbosity: Bool?
        let readOnlyStatus: Bool?
    }

    struct Capability: Decodable, Equatable {
        let supported: Bool
        let reason: String?
        let options: [Option]?

        init(supported: Bool, reason: String?, options: [Option]? = nil) {
            self.supported = supported
            self.reason = reason
            self.options = options
        }

        struct Option: Decodable, Equatable {
            let title: String?
            let value: String?
            let enabled: Bool?
        }
    }

    struct ModelCatalog: Decodable, Equatable {
        let available: Bool
        let reason: String?
        let models: [Model]

        enum CodingKeys: String, CodingKey {
            case available
            case reason
            case models
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            models = try container.decodeIfPresent([Model].self, forKey: .models) ?? []
        }

        struct Model: Decodable, Equatable {
            let id: String
            let provider: String
            let ref: String
            let name: String?
            let alias: String?
        }
    }
}

enum SessionControlAction: String, Encodable, Equatable {
    case cancelCurrentRun = "cancel_current_run"
    case setModel = "set_model"
    case setThinking = "set_thinking"
    case setReasoning = "set_reasoning"
    case setFastMode = "set_fast_mode"
    case setMode = "set_mode"
}

struct SessionControlResponse: Decodable, Equatable {
    let ok: Bool
    let sessionKey: String
    let action: String
    let code: String?
    let message: String?
    let status: SessionStatus?
    let capabilities: SessionStatus.Capabilities?
}
