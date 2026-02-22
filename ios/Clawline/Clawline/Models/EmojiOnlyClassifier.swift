import Foundation

enum EmojiOnlyClassifier {
    static let maxAmplifiedEmojiCount = 3

    static func isEmojiOnly(_ text: String) -> Bool {
        emojiCharacters(in: text) != nil
    }

    static func emojiCharacters(in text: String) -> [Character]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let characters = Array(trimmed)
        guard characters.count >= 1, characters.count <= maxAmplifiedEmojiCount else { return nil }
        guard characters.allSatisfy({ $0.isUnifiedEmojiOnlyCharacter }) else { return nil }
        return characters
    }
}

private extension Character {
    var isUnifiedEmojiOnlyCharacter: Bool {
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
