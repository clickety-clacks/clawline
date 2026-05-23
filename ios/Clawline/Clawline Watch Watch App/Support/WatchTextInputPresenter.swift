import Foundation
import WatchKit

@MainActor
enum WatchTextInputPresenter {
    static func requestPlainTextInput() async -> String? {
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            return nil
        }

        let values = await controller.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .plain
        )

        return values?
            .compactMap { value in
                if let text = value as? String {
                    return text
                }
                if let text = value as? NSString {
                    return text as String
                }
                return nil
            }
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
