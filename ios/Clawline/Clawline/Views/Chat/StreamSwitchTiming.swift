import Foundation

@MainActor
enum StreamSwitchTiming {
    private static var gestureBeganTime: CFAbsoluteTime?

    static func markGestureBegan(sessionKey: String?) {
        gestureBeganTime = CFAbsoluteTimeGetCurrent()
        log("pan_gesture_began", sessionKey: sessionKey)
    }

    static func log(_ stepName: String, sessionKey: String?) {
        let elapsedMs: Double
        if let gestureBeganTime {
            elapsedMs = max(0, (CFAbsoluteTimeGetCurrent() - gestureBeganTime) * 1000)
        } else {
            elapsedMs = 0
        }
        let session = sessionKey ?? ""
        NSLog("[STREAM_SWITCH] %@ t=%.2f sessionKey=%@", stepName, elapsedMs, session)
    }
}
