import Foundation
import Testing

struct MessageFlowStreamStateSeamTests {
    @Test("T103: materialized stream revisits re-arm persisted restore")
    func materializedStreamRevisitsRearmPersistedRestore() throws {
        let contents = try messageFlowSource()
        let seam = try functionBody(named: "runStreamContextSwitchSeam", in: contents)

        #expect(
            seam.contains("let allowTailStage = materializationStateBySessionKey[incomingSessionKey] == nil"),
            "The stream switch seam should choose tail staging separately from restore setup."
        )
        #expect(
            seam.contains("prepareIncomingStateOnSwitch(sessionKey: incomingSessionKey, allowTailStage: allowTailStage)"),
            "Materialized revisits must still reload persisted scroll state before rendering."
        )
        #expect(
            !seam.contains("materializedRevisitReset"),
            "Materialized revisits must not clear pending restore state instead of restoring it."
        )
    }

    @Test("T103: same-key re-read does not write stale geometry before restore")
    func sameKeyRereadDoesNotPersistBeforeRestore() throws {
        let contents = try messageFlowSource()
        let seam = try functionBody(named: "runStreamContextSwitchSeam", in: contents)
        guard let branchRange = seam.range(of: "if isSameKeyReRead"),
              let returnRange = seam[branchRange.lowerBound...].range(of: "return")
        else {
            Issue.record("Unable to locate same-key re-read branch.")
            return
        }
        let branch = seam[branchRange.lowerBound..<returnRange.upperBound]

        #expect(
            !branch.contains("persistScrollStateNow"),
            "Same-key re-read must reload persisted state, not overwrite it with current geometry first."
        )
        #expect(
            branch.contains("prepareSameKeyReread(sessionKey: incomingSessionKey)"),
            "Same-key re-read should route through the dedicated restore preparation path."
        )
    }

    @Test("T103: legacy preview remeasure debounce is session-owned")
    func legacyPreviewRemeasureDebounceCapturesSessionGeneration() throws {
        let contents = try messageFlowSource()
        let schedule = try functionBody(named: "scheduleDeferredPreviewRemeasureFlushAfterRest", in: contents)

        #expect(schedule.contains("guard let token = activeSessionGenerationToken() else { return }"))
        #expect(schedule.contains("guard self.callbackSessionKey() == token.sessionKey else { return }"))
        #expect(schedule.contains("guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }"))
        #expect(schedule.contains("self.withBoundSessionKey(token.sessionKey)"))
    }

    @Test("T103: deleted-stream cleanup cancels legacy preview timers")
    func deletedStreamCleanupCancelsLegacyPreviewTimers() throws {
        let contents = try messageFlowSource()
        let cancel = try functionBody(named: "cancelDeferredWork", in: contents)

        #expect(cancel.contains("state.deferredPreviewRemeasureTimer?.invalidate()"))
        #expect(cancel.contains("state.deferredPreviewRemeasureTimer = nil"))
    }

    private func messageFlowSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Clawline/Views/Chat/MessageFlowCollectionView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func functionBody(named name: String, in contents: String) throws -> String {
        guard let signatureRange = contents.range(of: "private func \(name)") else {
            throw SourceLookupError.missingFunction(name)
        }
        guard let openingBrace = contents[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw SourceLookupError.missingFunctionBody(name)
        }

        var depth = 0
        var index = openingBrace
        while index < contents.endIndex {
            let character = contents[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(contents[openingBrace...index])
                }
            }
            index = contents.index(after: index)
        }
        throw SourceLookupError.missingFunctionBody(name)
    }

    private enum SourceLookupError: Error {
        case missingFunction(String)
        case missingFunctionBody(String)
    }
}
