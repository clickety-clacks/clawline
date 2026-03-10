import Foundation

@MainActor
enum StreamSwitchTiming {
    private static let isVerboseLoggingEnabled = false
    private static var gestureBeganTime: CFAbsoluteTime?

    static func markGestureBegan(sessionKey: String?) {
        gestureBeganTime = CFAbsoluteTimeGetCurrent()
        log("pan_gesture_began", sessionKey: sessionKey)
    }

    static func log(_ stepName: String, sessionKey: String?) {
        guard isVerboseLoggingEnabled else { return }
        let elapsedMs: Double
        if let gestureBeganTime {
            elapsedMs = max(0, (CFAbsoluteTimeGetCurrent() - gestureBeganTime) * 1000)
        } else {
            elapsedMs = 0
        }
        let session = sessionKey ?? ""
        print(String(format: "[STREAM_SWITCH] %@ t=%.2f sessionKey=%@", stepName, elapsedMs, session))
    }
}
