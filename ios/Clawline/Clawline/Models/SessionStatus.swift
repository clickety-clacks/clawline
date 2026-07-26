//
//  SessionStatus.swift
//  Clawline
//
//  Created by Codex on 4/29/26.
//

import Foundation
import OSLog

private let sessionStatusLogger = Logger(
    subsystem: "co.clicketyclacks.Clawline",
    category: "SessionStatus"
)

/// Decode posture for models we read off the gateway wire: **resilient with
/// explicit defaults, never silent** (client convention, adopted 2026-07-25).
///
/// Swift's synthesized `Decodable` is all-or-nothing. With every section
/// declared non-optional, one renamed or flag-gated field anywhere in the
/// payload throws the whole decode, the view model's status stays nil, and the
/// model footer renders "Model loading" forever against a 200 response that is
/// well-formed by the gateway's own contract — nothing to notice on either
/// side. That is the failure this initializer exists to prevent.
///
/// The rule: a section that is missing or undecodable falls back to an empty
/// value of its own type, so a partial payload still yields a usable status;
/// every fallback is logged with the field that caused it, because a silently
/// defaulted field is the same invisible failure wearing a different hat.
///
/// One field stays strict: `sessionKey`. It is not display material, it is the
/// identity of what the status describes and the target of every
/// session-control action the footer's pickers post. Defaulting it would build
/// a picker that sends `set_model` at an empty session, which is worse than a
/// decode failure the status refresh already surfaces as `unavailable`.
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

    enum CodingKeys: String, CodingKey {
        case sessionKey
        case display
        case run
        case context
        case approval
        case capabilities
        case modelCatalog
        case metadataContextGeneration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)

        var defaulted: [String] = []
        display = Self.section(container, .display, fallback: .empty, defaulted: &defaulted)
        run = Self.section(container, .run, fallback: .empty, defaulted: &defaulted)
        capabilities = Self.section(container, .capabilities, fallback: .empty, defaulted: &defaulted)
        context = Self.optionalSection(container, .context, defaulted: &defaulted)
        approval = Self.optionalSection(container, .approval, defaulted: &defaulted)
        modelCatalog = Self.optionalSection(container, .modelCatalog, defaulted: &defaulted)
        metadataContextGeneration = Self.optionalSection(
            container,
            .metadataContextGeneration,
            defaulted: &defaulted
        )

        if !defaulted.isEmpty {
            // Bound to locals first: the logger's autoclosure would otherwise
            // capture `self` while the initializer is still mutating it.
            let key = sessionKey
            let fields = defaulted.joined(separator: ", ")
            sessionStatusLogger.error(
                "session status decoded with defaults sessionKey=\(key, privacy: .public) fields=\(fields, privacy: .public)"
            )
        }
    }

    /// Decodes a required section, falling back to `fallback` when the key is
    /// absent or its contents no longer decode. Records what it defaulted.
    private static func section<T: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        fallback: T,
        defaulted: inout [String]
    ) -> T {
        do {
            guard let value = try container.decodeIfPresent(T.self, forKey: key) else {
                defaulted.append(key.stringValue)
                return fallback
            }
            return value
        } catch {
            defaulted.append("\(key.stringValue) (\(error))")
            return fallback
        }
    }

    /// Decodes an already-optional section. Absence is normal and is not
    /// reported; a present-but-undecodable value is.
    private static func optionalSection<T: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        defaulted: inout [String]
    ) -> T? {
        do {
            return try container.decodeIfPresent(T.self, forKey: key)
        } catch {
            defaulted.append("\(key.stringValue) (\(error))")
            return nil
        }
    }

    struct Display: Decodable, Equatable {
        /// The fallback a missing or undecodable `display` section decodes to:
        /// every field nil, which the footer already renders truthfully.
        static let empty = Display(
            model: nil,
            fallbackModels: nil,
            provider: nil,
            harness: nil,
            reasoningLevel: nil,
            thinkingLevel: nil,
            fastMode: nil,
            mode: nil,
            verbosity: nil
        )

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

        /// The fallback for a missing or undecodable `run` section. `.unknown`
        /// is the honest state: the client does not know, and the enum already
        /// carries that case for unrecognized server values.
        static let empty = Run(
            state: .unknown,
            runId: nil,
            messageId: nil,
            startedAt: nil,
            queueDepth: nil
        )
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

        /// The fallback for a missing or undecodable `capabilities` section:
        /// nothing advertised, which the footer renders as disabled controls
        /// rather than as controls that post actions the gateway may refuse.
        static let empty = Capabilities(
            cancelCurrentRun: nil,
            setModel: nil,
            setThinking: nil,
            setReasoning: nil,
            setFastMode: nil,
            setMode: nil,
            setVerbosity: nil,
            canCancelCurrentRun: nil,
            canChangeModel: nil,
            canChangeReasoning: nil,
            canChangeFastMode: nil,
            canChangeVerbosity: nil,
            readOnlyStatus: nil
        )
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
    case setHarness = "set_harness"
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
