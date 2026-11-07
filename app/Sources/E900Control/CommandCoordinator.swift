import Foundation

/// Serial command queue for the AA13 write / AA14 reply channel, free of CoreBluetooth and timers so
/// its lifecycle can be unit-tested. The owner calls `next` to obtain the command to write, schedules
/// a timer for `deadline`, and reports replies, timeouts, GATT write errors and disconnects.
///
/// Rules:
/// - One command in flight. A reply matches only the in-flight command's `replyCodes`.
/// - Timeout = result unknown. The command's reply codes enter a "late window"; a reply arriving in
///   that window with nothing matching in flight is reported as `.late`, never as success of another
///   command. If a command with the same reply code is sent while the window is open, its reply is
///   reported as unconfirmed (it may be the previous command's late reply).
/// - No automatic resend of normal commands.
/// - Stop/cancel commands bypass the queue limit, jump ahead of normal commands, are de-duplicated
///   and pre-empt an in-flight normal command (whose result becomes unknown).
/// - A protocol reply only means the headset answered; it is never treated as "setting applied".
final class CommandCoordinator {
    struct Ticket: Equatable {
        let serial: Int
        let command: DeviceCommand
        /// Sent while a late window for one of its reply codes was open.
        var ambiguous = false
    }
    enum Enqueue: Equatable { case queued(serial: Int), duplicateStop, queueFull }
    enum Reply: Equatable {
        /// `confirmed == false` when the reply may belong to an earlier timed-out command.
        case matched(Ticket, confirmed: Bool)
        case late(code: UInt8)
        case unsolicited
    }
    struct InFlight: Equatable { let ticket: Ticket; let deadline: Date }

    let maxQueue: Int
    let timeout: TimeInterval
    let lateWindow: TimeInterval
    private(set) var queue: [Ticket] = []
    private(set) var inFlight: InFlight?
    private var windows: [(codes: Set<UInt8>, until: Date)] = []
    private var serial = 0

    init(maxQueue: Int = 20, timeout: TimeInterval = 5, lateWindow: TimeInterval = 10) {
        self.maxQueue = maxQueue; self.timeout = timeout; self.lateWindow = lateWindow
    }

    var isIdle: Bool { inFlight == nil && queue.isEmpty }
    var pendingCount: Int { queue.count + (inFlight == nil ? 0 : 1) }

    func enqueue(_ command: DeviceCommand) -> Enqueue {
        if command.isStop {
            let same: (Ticket) -> Bool = { $0.command.code == command.code && $0.command.payload == command.payload }
            if queue.contains(where: same) || inFlight.map({ same($0.ticket) }) == true { return .duplicateStop }
            serial += 1
            let ticket = Ticket(serial: serial, command: command)
            let insertAt = queue.firstIndex { !$0.command.isStop } ?? queue.count
            queue.insert(ticket, at: insertAt)
            return .queued(serial: serial)
        }
        guard queue.filter({ !$0.command.isStop }).count < maxQueue else { return .queueFull }
        serial += 1
        queue.append(Ticket(serial: serial, command: command))
        return .queued(serial: serial)
    }

    /// If a stop is waiting behind an in-flight normal command, abandon the latter (result unknown)
    /// so the stop can be written immediately.
    func preemptForStop(now: Date) -> Ticket? {
        guard let current = inFlight, !current.ticket.command.isStop, queue.first?.command.isStop == true else { return nil }
        openWindow(current.ticket.command.replyCodes, now: now)
        inFlight = nil
        return current.ticket
    }

    /// Pops the next command to write. Returns nil while one is in flight or the queue is empty.
    func next(now: Date) -> InFlight? {
        guard inFlight == nil, !queue.isEmpty else { return nil }
        prune(now)
        var ticket = queue.removeFirst()
        ticket.ambiguous = windows.contains { !$0.codes.isDisjoint(with: ticket.command.replyCodes) }
        let flight = InFlight(ticket: ticket, deadline: now.addingTimeInterval(timeout))
        inFlight = flight
        return flight
    }

    func reply(code: UInt8, now: Date) -> Reply {
        prune(now)
        if let current = inFlight, current.ticket.command.replyCodes.contains(code) {
            inFlight = nil
            if current.ticket.ambiguous { consumeWindow(code) }
            return .matched(current.ticket, confirmed: !current.ticket.ambiguous)
        }
        if consumeWindow(code) { return .late(code: code) }
        return .unsolicited
    }

    /// Called by the owner's timer. Ignored if the serial is stale or the deadline not reached.
    func timeout(serial: Int, now: Date) -> Ticket? {
        guard let current = inFlight, current.ticket.serial == serial, now >= current.deadline else { return nil }
        openWindow(current.ticket.command.replyCodes, now: now)
        inFlight = nil
        return current.ticket
    }

    /// The GATT write itself failed: the headset never received it, so no late window is needed.
    func writeFailed() -> Ticket? {
        defer { inFlight = nil }
        return inFlight?.ticket
    }

    /// Disconnect / power-off: everything pending is cancelled and late windows are forgotten, so a
    /// reconnect never replays an old shutter or matches a reply from the previous link.
    func reset() -> [Ticket] {
        let dropped = (inFlight.map { [$0.ticket] } ?? []) + queue
        queue = []; inFlight = nil; windows = []
        return dropped
    }

    private func openWindow(_ codes: Set<UInt8>, now: Date) { windows.append((codes, now.addingTimeInterval(lateWindow))) }
    private func prune(_ now: Date) { windows.removeAll { $0.until <= now } }
    @discardableResult private func consumeWindow(_ code: UInt8) -> Bool {
        guard let i = windows.firstIndex(where: { $0.codes.contains(code) }) else { return false }
        windows.remove(at: i)
        return true
    }
}

/// Microphone-stream session (0x57 / 0x0A start, 0x56 / 0x49 stop) plus passive wake-word captures
/// announced by AA14 0x97 … 0x99. `isActive` stays true until the headset confirms the stop, so the
/// auto-stop and the stop button remain armed while a stop is merely queued or unanswered.
struct VoiceSession: Equatable {
    enum State: Equatable {
        case idle
        case starting(UUID)
        case streaming(UUID)
        case stopping(UUID, attempt: Int)
        case stopUnconfirmed(UUID, attempt: Int)
        case passive(UUID)
    }
    private(set) var state: State = .idle
    let maxStopAttempts: Int
    init(maxStopAttempts: Int = 3) { self.maxStopAttempts = maxStopAttempts }

    var token: UUID? {
        switch state {
        case .idle: return nil
        case let .starting(t), let .streaming(t), let .stopping(t, _), let .stopUnconfirmed(t, _), let .passive(t): return t
        }
    }
    /// Stream may still be running on the headset.
    var isActive: Bool { if case .idle = state { return false }; return true }
    var acceptsPackets: Bool { isActive }
    var isPassive: Bool { if case .passive = state { return true }; return false }
    var label: String {
        switch state {
        case .idle: return "未串流"
        case .starting: return "啟動中（等待音訊）"
        case .streaming: return "串流中"
        case let .stopping(_, n): return n > 1 ? "停止中（第 \(n) 次）" : "停止中"
        case .stopUnconfirmed: return "停止未確認，可能仍在串流"
        case .passive: return "耳機喚醒中（被動接收）"
        }
    }

    /// The start command was written. Returns the token that an auto-stop timer must carry.
    mutating func startSent() -> UUID {
        let t = UUID(); state = .starting(t); return t
    }
    mutating func packetReceived() {
        if case let .starting(t) = state { state = .streaming(t) }
    }
    /// AA14 0x97 (voice data start) while idle → passive capture.
    mutating func wakeStarted() -> UUID? {
        guard case .idle = state else { return nil }
        let t = UUID(); state = .passive(t); return t
    }
    /// AA14 0x99 (voice data end).
    mutating func wakeEnded() { if case .passive = state { state = .idle } }
    /// Returns true when a stop command should be (re)queued.
    mutating func stopRequested() -> Bool {
        switch state {
        case let .starting(t), let .streaming(t): state = .stopping(t, attempt: 1); return true
        case let .stopUnconfirmed(t, n): state = .stopping(t, attempt: n + 1); return true
        case let .passive(t): state = .stopping(t, attempt: 1); return true
        case .stopping, .idle: return false
        }
    }
    /// Auto-stop timer fired; stale tokens (from an earlier session) are ignored.
    mutating func autoStopFired(token: UUID) -> Bool {
        guard self.token == token else { return false }
        if case .stopping = state { return false }
        return stopRequested()
    }
    /// Headset replied to 0x56 / 0x49.
    mutating func stopConfirmed() { state = .idle }
    /// The stop command timed out or its write failed. Returns true if another attempt is allowed.
    mutating func stopFailed() -> Bool {
        guard case let .stopping(t, n) = state else { return false }
        state = .stopUnconfirmed(t, attempt: n)
        return n < maxStopAttempts
    }
    mutating func disconnected() { state = .idle }
}
