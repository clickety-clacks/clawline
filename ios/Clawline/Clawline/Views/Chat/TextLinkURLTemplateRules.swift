import Foundation
import OSLog
import UIKit

enum TextLinkResolvedURLDisplayMode: String, Codable, CaseIterable, Equatable {
    case direct
    case modal
    case popup

    var label: String {
        switch self {
        case .direct: "Open directly"
        case .modal: "Show in modal"
        case .popup: "Show in popup"
        }
    }
}

struct TextLinkURLTemplateRule: Codable, Equatable, Identifiable {
    var id: String
    var enabled: Bool
    var pattern: String
    var urlTemplate: String
    var displayMode: TextLinkResolvedURLDisplayMode

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case pattern
        case urlTemplate
        case displayMode
    }

    init(
        id: String,
        enabled: Bool,
        pattern: String,
        urlTemplate: String,
        displayMode: TextLinkResolvedURLDisplayMode = .direct
    ) {
        self.id = id
        self.enabled = enabled
        self.pattern = pattern
        self.urlTemplate = urlTemplate
        self.displayMode = displayMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.pattern = try container.decode(String.self, forKey: .pattern)
        self.urlTemplate = try container.decode(String.self, forKey: .urlTemplate)
        self.displayMode = try container.decodeIfPresent(
            TextLinkResolvedURLDisplayMode.self,
            forKey: .displayMode
        ) ?? .direct
    }

    static let janusTrackerExample = TextLinkURLTemplateRule(
        id: "janus-ticket",
        enabled: true,
        pattern: #"\bT([0-9]+)\b"#,
        urlTemplate: "https://tars.tail4105e8.ts.net:19443/tracker.html?id={match}"
    )
}

struct TextLinkURLTemplateDiagnostic: Equatable {
    enum Kind: Equatable {
        case invalidPattern
        case unresolvedPlaceholder
        case invalidGeneratedURL
    }

    let ruleID: String
    let kind: Kind
}

enum TextLinkURLTemplateRules {
    static let generatedRuleIDAttribute = NSAttributedString.Key("co.clicketyclacks.Clawline.generatedTextLinkRuleID")
    static let generatedDisplayModeAttribute = NSAttributedString.Key("co.clicketyclacks.Clawline.generatedTextLinkDisplayMode")
    static var configuredRules: [TextLinkURLTemplateRule] = [] {
        didSet { configurationVersion += 1 }
    }
    static var diagnosticSink: ((TextLinkURLTemplateDiagnostic) -> Void)?
    private static var configurationVersion = 0
    private static let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "TextLinkURLTemplateRules")

    static var cacheKeyComponent: String {
        String(configurationVersion)
    }

    static func applyConfiguredRules(to attributed: NSMutableAttributedString) -> [TextLinkURLTemplateDiagnostic] {
        apply(configuredRules, to: attributed)
    }

    @discardableResult
    static func apply(
        _ rules: [TextLinkURLTemplateRule],
        to attributed: NSMutableAttributedString
    ) -> [TextLinkURLTemplateDiagnostic] {
        var diagnostics: [TextLinkURLTemplateDiagnostic] = []
        let text = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)

        for rule in rules where rule.enabled {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else {
                recordDiagnostic(.invalidPattern, ruleID: rule.id, diagnostics: &diagnostics)
                continue
            }

            let matches = regex.matches(in: attributed.string, options: [], range: fullRange)
            for match in matches {
                guard match.range.location != NSNotFound, match.range.length > 0 else { continue }
                guard rangeIsUnlinked(match.range, in: attributed) else { continue }

                switch generatedURL(for: match, in: text, rule: rule) {
                case .url(let url):
                    attributed.addAttribute(.link, value: url, range: match.range)
                    attributed.addAttribute(generatedRuleIDAttribute, value: rule.id, range: match.range)
                    attributed.addAttribute(generatedDisplayModeAttribute, value: rule.displayMode.rawValue, range: match.range)
                case .failure(let kind):
                    recordDiagnostic(kind, ruleID: rule.id, diagnostics: &diagnostics)
                }
            }
        }

        return diagnostics
    }

    static func isGeneratedLink(in attributed: NSAttributedString, characterRange: NSRange) -> Bool {
        guard characterRange.location != NSNotFound, characterRange.location < attributed.length else {
            return false
        }
        return attributed.attribute(generatedRuleIDAttribute, at: characterRange.location, effectiveRange: nil) != nil
    }

    static func displayMode(in attributed: NSAttributedString, characterRange: NSRange) -> TextLinkResolvedURLDisplayMode {
        guard characterRange.location != NSNotFound, characterRange.location < attributed.length else {
            return .direct
        }
        guard let rawValue = attributed.attribute(
            generatedDisplayModeAttribute,
            at: characterRange.location,
            effectiveRange: nil
        ) as? String else {
            return .direct
        }
        return TextLinkResolvedURLDisplayMode(rawValue: rawValue) ?? .direct
    }

    static func validationMessage(for rule: TextLinkURLTemplateRule) -> String? {
        guard rule.enabled else { return nil }
        guard let regex = try? NSRegularExpression(pattern: rule.pattern) else {
            return "Rule \(rule.id) has an invalid regex pattern."
        }

        for placeholder in placeholders(in: rule.urlTemplate) {
            if placeholder == "match" || placeholder == "0" {
                continue
            }
            guard let index = Int(placeholder), index <= regex.numberOfCaptureGroups else {
                return "Rule \(rule.id) has an unresolved placeholder."
            }
        }

        var sampleURLString = rule.urlTemplate
        for placeholderMatch in placeholderMatches(in: rule.urlTemplate).reversed() {
            sampleURLString = (sampleURLString as NSString).replacingCharacters(
                in: placeholderMatch.range,
                with: "T1135"
            )
        }
        guard let url = URL(string: sampleURLString),
              url.scheme != nil,
              url.host != nil else {
            return "Rule \(rule.id) does not generate an absolute URL."
        }
        return nil
    }

    static func containsGeneratedLink(to url: URL, in attributed: NSAttributedString) -> Bool {
        let fullRange = NSRange(location: 0, length: attributed.length)
        var found = false
        attributed.enumerateAttribute(.link, in: fullRange, options: []) { value, range, stop in
            let currentURL: URL?
            if let value = value as? URL {
                currentURL = value
            } else if let value = value as? String {
                currentURL = URL(string: value)
            } else {
                currentURL = nil
            }
            guard currentURL == url else { return }
            guard attributed.attribute(generatedRuleIDAttribute, at: range.location, effectiveRange: nil) != nil else {
                return
            }
            found = true
            stop.pointee = true
        }
        return found
    }

    private static func rangeIsUnlinked(_ range: NSRange, in attributed: NSAttributedString) -> Bool {
        var isUnlinked = true
        attributed.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
            if value != nil {
                isUnlinked = false
                stop.pointee = true
            }
        }
        return isUnlinked
    }

    private static func recordDiagnostic(
        _ kind: TextLinkURLTemplateDiagnostic.Kind,
        ruleID: String,
        diagnostics: inout [TextLinkURLTemplateDiagnostic]
    ) {
        let diagnostic = TextLinkURLTemplateDiagnostic(ruleID: ruleID, kind: kind)
        diagnostics.append(diagnostic)
        diagnosticSink?(diagnostic)
        logger.error("text link URL template rule failed ruleID=\(ruleID, privacy: .public) kind=\(String(describing: kind), privacy: .public)")
    }

    private enum GeneratedURLResult {
        case url(URL)
        case failure(TextLinkURLTemplateDiagnostic.Kind)
    }

    private static func generatedURL(
        for match: NSTextCheckingResult,
        in text: NSString,
        rule: TextLinkURLTemplateRule
    ) -> GeneratedURLResult {
        var output = rule.urlTemplate
        let template = rule.urlTemplate as NSString
        let matches = placeholderMatches(in: rule.urlTemplate)

        for placeholderMatch in matches.reversed() {
            let key = template.substring(with: placeholderMatch.range(at: 1))
            guard let replacement = replacementValue(for: key, match: match, text: text) else {
                return .failure(.unresolvedPlaceholder)
            }
            output = (output as NSString).replacingCharacters(
                in: placeholderMatch.range,
                with: percentEncode(replacement)
            )
        }

        guard let url = URL(string: output),
              url.scheme != nil,
              url.host != nil else {
            return .failure(.invalidGeneratedURL)
        }
        return .url(url)
    }

    private static func replacementValue(for key: String, match: NSTextCheckingResult, text: NSString) -> String? {
        let captureIndex: Int
        if key == "match" {
            captureIndex = 0
        } else if let numericIndex = Int(key) {
            captureIndex = numericIndex
        } else {
            return nil
        }

        guard captureIndex < match.numberOfRanges else { return nil }
        let range = match.range(at: captureIndex)
        guard range.location != NSNotFound else { return nil }
        return text.substring(with: range)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func placeholders(in template: String) -> [String] {
        let nsTemplate = template as NSString
        return placeholderMatches(in: template).map { nsTemplate.substring(with: $0.range(at: 1)) }
    }

    private static func placeholderMatches(in template: String) -> [NSTextCheckingResult] {
        let placeholderRegex = try? NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_]*|[0-9]+)\}"#)
        let nsTemplate = template as NSString
        return placeholderRegex?.matches(
            in: template,
            options: [],
            range: NSRange(location: 0, length: nsTemplate.length)
        ) ?? []
    }
}
