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
        print("Session and numeric diagnostics: 22 assertions passed")
    }
}
