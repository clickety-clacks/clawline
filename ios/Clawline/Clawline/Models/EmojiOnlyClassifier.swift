import Foundation

enum EmojiOnlyClassifier {
    nonisolated static let maxAmplifiedEmojiCount = 3

    nonisolated static func isEmojiOnly(_ text: String) -> Bool {
        emojiCharacters(in: text) != nil
    }

    nonisolated static func emojiCharacters(in text: String) -> [Character]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let characters = Array(trimmed)
        guard characters.count >= 1, characters.count <= maxAmplifiedEmojiCount else { return nil }
        guard characters.allSatisfy({ $0.isUnifiedEmojiOnlyCharacter }) else { return nil }
        return characters
    }
}

private extension Character {
    nonisolated var isUnifiedEmojiOnlyCharacter: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmoji && (
                scalar.properties.generalCategory == .otherSymbol
                    || scalar.properties.generalCategory == .modifierSymbol
                    || scalar.properties.generalCategory == .nonspacingMark
                    || scalar.properties.generalCategory == .enclosingMark
            )
        }
    }
}
