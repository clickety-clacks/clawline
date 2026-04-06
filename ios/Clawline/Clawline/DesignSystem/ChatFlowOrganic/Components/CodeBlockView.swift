//
//  CodeBlockView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import HighlightSwift
import SwiftUI

struct CodeBlockView: View {
    let language: String?
    let code: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightedCode: AttributedString?

    private var isDark: Bool {
        return colorScheme == .dark
    }

    private var backgroundColor: Color {
        isDark
            ? Color(red: 0.118, green: 0.118, blue: 0.118)
            : Color(red: 0.945, green: 0.933, blue: 0.910)
    }

    private var labelColor: Color {
        isDark
            ? Color.white.opacity(0.6)
            : Color(red: 0.361, green: 0.290, blue: 0.239).opacity(0.6)
    }

    private var plainTextColor: Color {
        isDark
            ? Color.white.opacity(0.9)
            : Color(red: 0.2, green: 0.2, blue: 0.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.clawline(.secondaryLabel, design: .monospaced).weight(.semibold))
                    .foregroundColor(labelColor)
                    .tracking(0.5)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                if let highlighted = highlightedCode {
                    Text(highlighted)
                        .font(.clawline(.secondaryLabel, design: .monospaced))
                        .lineSpacing(4)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(code)
                        .font(.clawline(.secondaryLabel, design: .monospaced))
                        .foregroundColor(plainTextColor)
                        .lineSpacing(4)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: "\(code)\(isDark)") {
            await highlightCode()
        }
    }

    private func highlightCode() async {
        let colors: HighlightColors = isDark ? .dark(.atomOne) : .light(.atomOne)
        let highlight = Highlight()

        do {
            let langString = mapLanguageString(language)
            let attributed: AttributedString
            if let lang = langString {
                attributed = try await highlight.attributedText(code, language: lang, colors: colors)
            } else {
                attributed = try await highlight.attributedText(code, colors: colors)
            }
            highlightedCode = attributed
        } catch {
            highlightedCode = nil
        }
    }

    private func mapLanguageString(_ lang: String?) -> String? {
        guard let lang = lang?.lowercased() else { return nil }
        let mapping: [String: String] = [
            "swift": "swift", "python": "python", "py": "python",
            "javascript": "javascript", "js": "javascript",
            "typescript": "typescript", "ts": "typescript",
            "java": "java", "kotlin": "kotlin", "kt": "kotlin",
            "c": "c", "cpp": "cpp", "c++": "cpp",
            "csharp": "csharp", "c#": "csharp", "cs": "csharp",
            "go": "go", "golang": "go",
            "rust": "rust", "rs": "rust",
            "ruby": "ruby", "rb": "ruby",
            "php": "php", "html": "xml", "xml": "xml",
            "css": "css", "scss": "scss", "sass": "scss",
            "json": "json", "yaml": "yaml", "yml": "yaml",
            "sql": "sql", "bash": "bash", "sh": "bash", "shell": "bash", "zsh": "bash",
            "markdown": "markdown", "md": "markdown",
            "objective-c": "objectivec", "objc": "objectivec",
            "r": "r", "perl": "perl", "lua": "lua",
            "scala": "scala", "haskell": "haskell", "elixir": "elixir",
            "clojure": "clojure", "erlang": "erlang",
            "dockerfile": "dockerfile", "docker": "dockerfile",
            "makefile": "makefile", "make": "makefile",
            "graphql": "graphql", "gql": "graphql",
            "dart": "dart", "vue": "xml", "jsx": "javascript", "tsx": "typescript"
        ]
        return mapping[lang] ?? lang
    }
}
