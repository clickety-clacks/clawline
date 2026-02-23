# Swift Safety Rules

Apply these rules in Clawline Swift code:

1. Do not use `try? await Task.sleep(...)` inside cancellable tasks unless cancellation is explicitly handled before any side effects.
2. Prefer:
   - `do { try await Task.sleep(...) } catch is CancellationError { return }`
3. Avoid postfix force unwrap (`!`) for optionals in production code.
4. Avoid new IUO (`Type!`) stored properties unless UIKit lifecycle wiring requires them and initialization order is guaranteed.
5. Do not silently drop optional decode/transform failures in protocol handlers; log or surface failures instead of ignoring them.
