import ServiceManagement
import UserNotifications
import XCTest
@testable import ConvertApp

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testNotificationPermissionBatchingAndDeliveryErrors() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        defer { settings.stop() }
        var authorization = UNAuthorizationStatus.notDetermined
        var requests = 0
        var delivered: [UNNotificationRequest] = []
        settings.readAuthorization = { authorization }
        settings.readLoginStatus = { .notRegistered }
        settings.requestAuthorization = { requests += 1; authorization = .denied; return false }
        settings.deliver = { delivered.append($0) }
        let saved = defaults.persistentDomain(forName: suite) as NSDictionary?
        await settings.refresh()
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(settings.showNotifications)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, saved)
        await settings.setNotifications(true)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(settings.showNotifications)
        XCTAssertTrue(AppSettings(defaults: defaults).showNotifications)
        XCTAssertEqual(settings.notificationAuthorization, .denied)
        XCTAssertTrue(settings.notificationDescription.contains("System Settings"))
        await settings.failed("A refused conversion")?.value
        XCTAssertTrue(delivered.isEmpty)
        await settings.setNotifications(false)
        await settings.setNotifications(true)
        XCTAssertEqual(requests, 1)

        authorization = .authorized
        let batch = expectation(description: "One grouped completion")
        settings.deliver = { delivered.append($0); batch.fulfill() }
        for number in 1...5 { settings.converted(URL(fileURLWithPath: "/temporary/file-\(number).png")) }
        let batchResult = await XCTWaiter.fulfillment(of: [batch], timeout: 3)
        XCTAssertEqual(batchResult, .completed)
        XCTAssertEqual(delivered.count, 1)
        let content = try XCTUnwrap(delivered.first?.content)
        XCTAssertEqual(content.title, "5 Conversions Complete")
        XCTAssertEqual(content.body, "file-1.png\nfile-2.png\nfile-3.png\nAnd 2 more files.")
        XCTAssertEqual(content.userInfo["tab"] as? String, "history")
        XCTAssertNil(delivered.first?.trigger)

        settings.deliver = { delivered.append($0) }
        await settings.failed("An Undo error", undo: true)?.value
        await settings.failed("A manual error", manual: true)?.value
        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(Set(delivered.map(\.identifier)).count, 3)
        XCTAssertEqual(delivered[1].content.userInfo["tab"] as? String, "history")
        XCTAssertEqual(delivered[2].content.userInfo["tab"] as? String, "manual")
        authorization = .provisional
        let manual = expectation(description: "Manual completion")
        settings.deliver = { delivered.append($0); manual.fulfill() }
        settings.converted(URL(fileURLWithPath: "/temporary/manual.png"), manual: true)
        let manualResult = await XCTWaiter.fulfillment(of: [manual], timeout: 2)
        XCTAssertEqual(manualResult, .completed)
        XCTAssertEqual(delivered.last?.content.title, "Conversion Complete")
        XCTAssertEqual(delivered.last?.content.userInfo["tab"] as? String, "manual")
        settings.deliver = { _ in throw NSError(domain: "Test", code: 1) }
        await settings.failed("A delivery error")?.value
        XCTAssertNotNil(settings.notificationError)
        XCTAssertTrue(settings.showNotifications)

        authorization = .denied
        await settings.refresh()
        XCTAssertEqual(settings.notificationAuthorization, .denied)
        settings.deliver = { _ in XCTFail("Revoked permission must suppress delivery") }
        await settings.failed("Permission was revoked")?.value

        authorization = .notDetermined
        settings.requestAuthorization = { throw NSError(domain: "Test", code: 3) }
        await settings.setNotifications(false)
        await settings.setNotifications(true)
        XCTAssertNotNil(settings.notificationError)
        XCTAssertEqual(settings.notificationAuthorization, .notDetermined)
        XCTAssertFalse(settings.changingNotifications)
    }

    @MainActor
    func testDisablingNotificationsDropsPendingAndSuspendedWork() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        defer { settings.stop() }
        settings.readAuthorization = { .authorized }
        settings.requestAuthorization = { XCTFail("Existing permission must be reused"); return true }
        settings.deliver = { _ in XCTFail("Disabled notifications must not be delivered") }
        await settings.setNotifications(true)
        settings.converted(URL(fileURLWithPath: "/temporary/pending.png"))
        await settings.setNotifications(false)
        settings.flushCompletions()
        XCTAssertNil(settings.failed("Disabled"))

        await settings.setNotifications(true)
        let started = expectation(description: "Authorization read suspended")
        var continuation: CheckedContinuation<UNAuthorizationStatus, Never>?
        settings.readAuthorization = {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        let posting = try XCTUnwrap(settings.failed("Waiting for permission state"))
        let readResult = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(readResult, .completed)
        await settings.setNotifications(false)
        try XCTUnwrap(continuation).resume(returning: .authorized)
        await posting.value

        settings.readAuthorization = { .authorized }
        await settings.setNotifications(true)
        settings.converted(URL(fileURLWithPath: "/temporary/quit.png"))
        settings.stop()
        settings.flushCompletions()
        XCTAssertNil(settings.failed("After quitting"))
        XCTAssertTrue(settings.showNotifications)
    }

    @MainActor
    func testLoginStateAndNotificationWindowRouting() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ConversionModel(defaults: defaults)
        let settings = model.appSettings
        settings.readAuthorization = { .denied }
        var status = SMAppService.Status.notRegistered
        var changes: [Bool] = []
        settings.readLoginStatus = { status }
        settings.registerLogin = { enabled in
            changes.append(enabled)
            status = enabled ? .requiresApproval : .notRegistered
        }
        await settings.refresh()
        XCTAssertTrue(changes.isEmpty)
        await settings.setLaunchAtLogin(true)
        XCTAssertEqual(changes, [true])
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.loginStatus, .requiresApproval)
        XCTAssertTrue(settings.loginDescription.contains("Allow"))
        await settings.setLaunchAtLogin(true)
        XCTAssertEqual(changes, [true])
        status = .enabled
        await settings.refresh()
        XCTAssertEqual(settings.loginStatus, .enabled)
        status = .requiresApproval
        await settings.refresh()
        XCTAssertEqual(settings.loginStatus, .requiresApproval)
        await settings.setLaunchAtLogin(false)
        XCTAssertEqual(changes, [true, false])
        XCTAssertFalse(settings.launchAtLogin)
        settings.registerLogin = { _ in throw NSError(domain: "Test", code: 2) }
        await settings.setLaunchAtLogin(true)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertNotNil(settings.loginError)
        status = .notFound
        await settings.refresh()
        XCTAssertTrue(settings.loginDescription.contains("Applications"))
        XCTAssertNil(defaults.object(forKey: "launchAtLogin"))

        let delegate = AppDelegate()
        var openings = 0
        delegate.openNotification(tab: "manual")
        delegate.connect(model: model) { openings += 1 }
        XCTAssertEqual(model.tab, .manual)
        XCTAssertEqual(openings, 1)
        delegate.openNotification(tab: "automatic")
        XCTAssertEqual(model.tab, .automatic)
        delegate.openNotification(tab: "history")
        XCTAssertEqual(model.tab, .history)
        delegate.openNotification(tab: "unknown")
        XCTAssertEqual(model.tab, .history)
        XCTAssertEqual(openings, 4)
    }
}
