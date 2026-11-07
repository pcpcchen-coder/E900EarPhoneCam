import XCTest
@testable import E900Control

private func cmd(_ id: String) -> DeviceCommand { CommandCatalog.all.first { $0.id == id }! }

final class CommandCoordinatorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testReplyMatchesOnlyInFlightCommand() {
        let c = CommandCoordinator()
        _ = c.enqueue(cmd("battery")); _ = c.enqueue(cmd("photo"))
        let first = c.next(now: t0)!
        XCTAssertEqual(first.ticket.command.id, "battery")
        XCTAssertNil(c.next(now: t0), "only one command in flight")
        XCTAssertEqual(c.reply(code: 0x22, now: t0), .unsolicited, "photo reply cannot complete battery")
        guard case let .matched(t, confirmed) = c.reply(code: 0x17, now: t0) else { return XCTFail() }
        XCTAssertEqual(t.command.id, "battery"); XCTAssertTrue(confirmed)
        XCTAssertEqual(c.next(now: t0)?.ticket.command.id, "photo")
    }

    func testLateReplyAfterTimeoutDoesNotConfirmNextSameCommand() {
        let c = CommandCoordinator(timeout: 5, lateWindow: 10)
        _ = c.enqueue(cmd("photo"))
        let a = c.next(now: t0)!
        XCTAssertNil(c.timeout(serial: a.ticket.serial, now: t0.addingTimeInterval(4)), "deadline not reached")
        XCTAssertNotNil(c.timeout(serial: a.ticket.serial, now: t0.addingTimeInterval(5)))
        // Late reply with nothing in flight is reported as late.
        XCTAssertEqual(c.reply(code: 0x22, now: t0.addingTimeInterval(6)), .late(code: 0x22))
        // A second photo sent inside a still-open window is flagged ambiguous.
        _ = c.enqueue(cmd("photo")); _ = c.enqueue(cmd("photo"))
        let b = c.next(now: t0.addingTimeInterval(6.5))!
        XCTAssertFalse(b.ticket.ambiguous, "the earlier window was consumed by the late reply")
        _ = c.timeout(serial: b.ticket.serial, now: t0.addingTimeInterval(12))
        let d = c.next(now: t0.addingTimeInterval(12.1))!
        XCTAssertTrue(d.ticket.ambiguous)
        guard case let .matched(_, confirmed) = c.reply(code: 0x22, now: t0.addingTimeInterval(12.2)) else { return XCTFail() }
        XCTAssertFalse(confirmed, "reply may belong to the timed-out photo")
    }

    func testLateWindowExpires() {
        let c = CommandCoordinator(timeout: 5, lateWindow: 10)
        _ = c.enqueue(cmd("battery"))
        let a = c.next(now: t0)!
        _ = c.timeout(serial: a.ticket.serial, now: t0.addingTimeInterval(5))
        XCTAssertEqual(c.reply(code: 0x17, now: t0.addingTimeInterval(16)), .unsolicited)
        _ = c.enqueue(cmd("battery"))
        XCTAssertFalse(c.next(now: t0.addingTimeInterval(16))!.ticket.ambiguous)
    }

    func testStaleTimerIgnored() {
        let c = CommandCoordinator()
        _ = c.enqueue(cmd("battery"))
        let a = c.next(now: t0)!
        _ = c.reply(code: 0x17, now: t0)
        _ = c.enqueue(cmd("photo"))
        let b = c.next(now: t0)!
        XCTAssertNil(c.timeout(serial: a.ticket.serial, now: t0.addingTimeInterval(60)), "old timer must not cancel the new command")
        XCTAssertEqual(c.inFlight?.ticket.serial, b.ticket.serial)
    }

    func testStopBypassesFullQueueAndPreempts() {
        let c = CommandCoordinator(maxQueue: 3)
        _ = c.enqueue(cmd("videoStart"))
        let running = c.next(now: t0)!
        for _ in 0..<3 { XCTAssertNotEqual(c.enqueue(cmd("battery")), .queueFull) }
        XCTAssertEqual(c.enqueue(cmd("battery")), .queueFull)
        guard case .queued = c.enqueue(cmd("videoStop")) else { return XCTFail("stop must not be rejected by a full queue") }
        XCTAssertEqual(c.enqueue(cmd("videoStop")), .duplicateStop)
        XCTAssertEqual(c.preemptForStop(now: t0)?.serial, running.ticket.serial)
        XCTAssertEqual(c.next(now: t0)?.ticket.command.id, "videoStop", "stop is written before queued normal commands")
        XCTAssertEqual(c.enqueue(cmd("videoStop")), .duplicateStop, "in-flight stop also de-duplicates")
        // The pre-empted start's late reply is not credited to the stop.
        XCTAssertEqual(c.reply(code: 0x23, now: t0.addingTimeInterval(1)), .late(code: 0x23))
    }

    func testStopsKeepFifoAmongThemselves() {
        let c = CommandCoordinator()
        _ = c.enqueue(cmd("battery"))
        _ = c.enqueue(cmd("audioStop")); _ = c.enqueue(cmd("voiceStop"))
        XCTAssertEqual(c.queue.map(\.command.id), ["audioStop", "voiceStop", "battery"])
    }

    func testWriteFailureClearsWithoutLateWindow() {
        let c = CommandCoordinator()
        _ = c.enqueue(cmd("photo"))
        _ = c.next(now: t0)
        XCTAssertEqual(c.writeFailed()?.command.id, "photo")
        XCTAssertEqual(c.reply(code: 0x22, now: t0), .unsolicited)
    }

    func testDisconnectDropsEverythingAndForgetsWindows() {
        let c = CommandCoordinator()
        _ = c.enqueue(cmd("photo"))
        let a = c.next(now: t0)!
        _ = c.timeout(serial: a.ticket.serial, now: t0.addingTimeInterval(5))
        _ = c.enqueue(cmd("videoStart")); _ = c.enqueue(cmd("battery"))
        _ = c.next(now: t0.addingTimeInterval(5))
        XCTAssertEqual(c.reset().map(\.command.id), ["videoStart", "battery"])
        XCTAssertTrue(c.isIdle)
        XCTAssertNil(c.next(now: t0.addingTimeInterval(6)), "nothing replays after reconnect")
        XCTAssertEqual(c.reply(code: 0x22, now: t0.addingTimeInterval(6)), .unsolicited)
    }

    func testReplyCodeAliases() {
        XCTAssertEqual(cmd("wifi").replyCodes, [0x25])
        XCTAssertTrue(cmd("count").replyCodes.contains(0x42))
        XCTAssertTrue(cmd("status").replyCodes.contains(0x07))
        XCTAssertTrue(cmd("videoStop").isStop && cmd("audioStop").isStop && cmd("voiceStop").isStop && cmd("voiceCancel").isStop)
        XCTAssertFalse(cmd("audioStart").isStop || cmd("videoStart").isStop || cmd("photo").isStop)
    }
}

final class VoiceSessionTests: XCTestCase {
    func testActiveUntilStopConfirmed() {
        var v = VoiceSession()
        let token = v.startSent()
        XCTAssertTrue(v.isActive); XCTAssertEqual(v.state, .starting(token))
        v.packetReceived(); XCTAssertEqual(v.state, .streaming(token))
        XCTAssertTrue(v.stopRequested())
        XCTAssertTrue(v.isActive, "queued stop is not a stopped stream")
        XCTAssertFalse(v.stopRequested(), "no duplicate stop while one is pending")
        XCTAssertFalse(v.autoStopFired(token: token), "auto-stop does not double-send while stopping")
        v.stopConfirmed(); XCTAssertFalse(v.isActive)
    }

    func testStopRetryIsBounded() {
        var v = VoiceSession(maxStopAttempts: 3)
        _ = v.startSent(); _ = v.stopRequested()
        XCTAssertTrue(v.stopFailed()); XCTAssertTrue(v.isActive)
        XCTAssertTrue(v.stopRequested()); XCTAssertEqual(v.state.attempt, 2)
        XCTAssertTrue(v.stopFailed()); XCTAssertTrue(v.stopRequested())
        XCTAssertFalse(v.stopFailed(), "third failure stops automatic retries")
        XCTAssertTrue(v.isActive, "still possibly streaming; manual stop stays available")
        XCTAssertTrue(v.stopRequested(), "user can still press stop")
    }

    func testStaleAutoStopIgnored() {
        var v = VoiceSession()
        let old = v.startSent(); _ = v.stopRequested(); v.stopConfirmed()
        let current = v.startSent()
        XCTAssertFalse(v.autoStopFired(token: old))
        XCTAssertEqual(v.state, .starting(current))
        XCTAssertTrue(v.autoStopFired(token: current))
    }

    func testPassiveWakeAndDisconnect() {
        var v = VoiceSession()
        XCTAssertNotNil(v.wakeStarted()); XCTAssertTrue(v.isPassive && v.acceptsPackets)
        XCTAssertNil(v.wakeStarted())
        v.wakeEnded(); XCTAssertFalse(v.isActive)
        _ = v.startSent(); XCTAssertNil(v.wakeStarted(), "wake notice does not hijack an active stream")
        v.disconnected(); XCTAssertEqual(v.state, .idle)
    }
}

private extension VoiceSession.State {
    var attempt: Int? {
        switch self { case let .stopping(_, n), let .stopUnconfirmed(_, n): return n; default: return nil }
    }
}
