import Foundation

@main struct SessionSmoke {
    @MainActor static func main() throws {
        var state = DictationSessionState(); state.ready()
        let first = state.begin()!; assert(state.process(first))
        assert(state.hold("Keep my words", for: first)); assert(state.begin() == nil)
        let failedPlacement = state.beginPlacement()!; state.cancel()
        assert(state.pendingText == "Keep my words" && state.phase == .pending)
        assert(!state.didDispatch("Late result", for: failedPlacement))
        state.resolvePending(copied: true)
        assert(state.lastText == "Keep my words")
        let delivery = state.begin()!; state.process(delivery)
        assert(state.didDispatch("Once", for: delivery))
        assert(!state.didDispatch("Twice", for: delivery))
        assert(!state.hold("Duplicate", for: delivery))
        let next = state.begin()!
        assert(!state.finishDelivery(delivery))
        assert(state.phase == .listening && state.id == next)
        state.process(next); state.cancel()
        assert(!state.hold("Stale", for: next))
        assert(state.lastText == "Once" && state.pendingText == nil)
        let discard = state.begin()!; state.process(discard)
        state.hold("Never copied", for: discard); state.resolvePending(copied: false)
        assert(state.lastText == "Once" && state.pendingText == nil)
        assert(state.begin() != nil)
        let metrics = InteractionMetrics(); let metricID = UUID()
        metrics.begin(metricID); metrics.mark("stopped", metricID)
        metrics.mark("dispatched", metricID); metrics.mark("nextCaptureReady", metricID)
        metrics.finish("verified", metricID)
        let data = try metrics.export()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let row = (object["sessions"] as! [[String: Any]])[0]
        assert((row["milliseconds"] as! [String: Double])["stopTo_dispatched"] != nil)
        assert(row["outcome"] as? String == "verified")
        assert(!String(decoding: data, as: UTF8.self).contains("Keep my words"))
        var feedback = CompletionFeedback()
        feedback.begin(delivery)
        assert(feedback.isVisible(for: delivery))
        feedback.dismiss(delivery)
        assert(!feedback.confirm(delivery)) // late verification must not reopen
        assert(!feedback.isVisible(for: delivery))
        feedback.begin(next)
        feedback.dismiss(delivery) // an old timer cannot dismiss a new delivery
        assert(feedback.isVisible(for: next))
        assert(!feedback.confirm(delivery))
        assert(feedback.confirm(next))
        assert(!feedback.confirm(next)) // only one brief confirmation per paste
        feedback.dismiss(next)
        assert(!feedback.isVisible(for: next))
        var recovery = DictationSessionState(); recovery.ready()
        let capture = recovery.begin()!; assert(recovery.process(capture))
        assert(recovery.failRecording(capture)); assert(recovery.phase == .failedRecording)
        assert(recovery.begin() == nil && recovery.pendingText == nil)
        let retry = recovery.beginRetry()!
        assert(recovery.phase == .processing && recovery.hasFailedRecording)
        assert(!recovery.hold("Stale capture", for: capture))
        recovery.cancel()
        assert(recovery.phase == .failedRecording && recovery.hasFailedRecording)
        assert(!recovery.didDispatch("Canceled retry", for: retry))
        let nextRetry = recovery.beginRetry()!
        assert(recovery.failRecording(nextRetry))
        let successfulRetry = recovery.beginRetry()!
        recovery.recognized(successfulRetry)
        assert(!recovery.hasFailedRecording)
        assert(recovery.hold("Recovered words", for: successfulRetry))
        assert(recovery.phase == .pending && recovery.begin() == nil)
        recovery.resolvePending(copied: true)
        assert(recovery.lastText == "Recovered words" && recovery.phase == .idle)
        let another = recovery.begin()!; recovery.process(another); recovery.failRecording(another)
        recovery.discardRecording()
        assert(!recovery.hasFailedRecording && recovery.phase == .idle)
        assert(recovery.lastText == "Recovered words")
        assert(!recovery.failRecording(another))
        assert(recovery.begin() != nil)
        metrics.recording(mode: "verbatim", duration: 300, retry: true, metricID)
        metrics.cleanup(completed: 1, total: 2, fallbacks: ["deadline", "private transcript should never enter diagnostics"], metricID)
        let extendedData = try metrics.export()
        let extended = try JSONSerialization.jsonObject(with: extendedData) as! [String: Any]
        assert(extended["schemaVersion"] as? Int == 2)
        assert(!String(decoding: extendedData, as: UTF8.self).contains("private transcript"))
        let extendedRow = (extended["sessions"] as! [[String: Any]])[0]
        assert((extendedRow["categories"] as! [String: String])["mode"] == "verbatim")
        assert((extendedRow["measurements"] as! [String: Double])["audioSeconds"] == 300)
        print("Passed session, failed-recording recovery, completion feedback, and numeric diagnostics regressions")
    }
}
