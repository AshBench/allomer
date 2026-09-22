import AppKit

extension ConversionModel {
    func prepareToQuit(_ application: NSApplication) -> NSApplication.TerminateReply {
        isQuitting = true
        appSettings.stop()
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        cleanupWorker?.cancel()
        automatic?.stop()
        guard worker != nil || cleanupWorker != nil || activeJobs > 0 || manualCompletion != nil || historyWriter != nil else { return .terminateNow }
        worker?.cancel()
        let worker = worker
        let cleanup = cleanupWorker
        let completion = manualCompletion
        Task {
            _ = try? await worker?.value
            _ = try? await cleanup?.value
            await completion?.value
            await automatic?.stopAndWait()
            await historyWriter?.value
            application.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

}
