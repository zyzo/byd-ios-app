import Foundation
import Observation
import UIKit

/// Locks the car over Bluetooth as you walk away from it.
///
/// Once the signal has been above the chosen distance's threshold for a moment you count as
/// at the car; when it then stays below for a few seconds, one lock goes out over Bluetooth
/// (never the cloud). If the link drops first, it locks on reconnect within two minutes.
/// A fresh server report saying the car is on or moving vetoes the lock; one saying a door is
/// open holds it, re-asking the car every few seconds and locking once the door is shut.
///
/// iOS can suspend or end the app in the background, so a walk-away can go unseen. Whenever
/// the link drops without a lock this visit, including a drop that relaunches an ended app,
/// the app asks the server whether the car was left unlocked and, if so, posts a notification
/// with a Lock button.
@MainActor
@Observable
final class AutoLock {
    enum Phase: Equatable {
        case idle
        case near
        case leaving(since: Date)
        /// Locked, or decided not to, for this visit.
        case done
        /// Link dropped while leaving; locks if it comes back by then.
        case awaitingReconnect(until: Date)
        /// Walked away with a door open; locks once a fresh report says it's shut.
        case doorOpen(until: Date)

        var name: String {
            switch self {
            case .idle: "waiting"
            case .near: "at the car"
            case .leaving: "leaving"
            case .done: "done"
            case .awaitingReconnect: "awaiting reconnect"
            case .doorOpen: "waiting for a door"
            }
        }

        /// You were at the car this visit, as far as a relaunched app needs to know.
        var atCar: Bool {
            switch self {
            case .near, .leaving, .doorOpen: true
            case .idle, .done, .awaitingReconnect: false
            }
        }

        var mayLock: Bool {
            switch self {
            case .leaving, .awaitingReconnect, .doorOpen: true
            case .idle, .near, .done: false
            }
        }
    }

    /// The car drops the link at about -80 dBm, so a longer distance's weak level is never reached.
    static let distances = [50, 100, 200]
    static let defaultDistance = 200
    /// dB below the distance's threshold before the signal counts as weak.
    private static let hysteresis = 6.0
    private static let nearHold: TimeInterval = 1.5
    /// Short, since the link often drops within seconds of the signal turning weak.
    private static let holdTime: TimeInterval = 3
    /// No auto-lock within this long of any Bluetooth command.
    private static let cooldown: TimeInterval = 60
    private static let reconnectWindow: TimeInterval = 2 * 60
    /// A server report older than this can't veto a lock.
    private static let statusFreshness: TimeInterval = 5 * 60
    private static let statusTimeout: TimeInterval = 3
    /// How long the left-unlocked check waits for the car's own report; iOS allows about 30 s.
    private static let refreshTimeout: TimeInterval = 20
    /// One left-unlocked notification per this long.
    private static let leftUnlockedQuiet: TimeInterval = 10 * 60
    /// How long a walk-away waits for an open door to be shut.
    private static let doorWait: TimeInterval = 2 * 60
    private static let doorRecheck: TimeInterval = 10
    private static let recheckTimeout: TimeInterval = 8

    private enum Keys {
        static let wanted = "autoLock.wanted"
        static let distance = "autoLock.distance"
        static let atCar = "autoLock.atCar"
    }

    private(set) var isOn: Bool
    var distance: Int {
        didSet { defaults.set(distance, forKey: Keys.distance) }
    }
    private(set) var phase: Phase = .idle {
        didSet { if phase.atCar != oldValue.atCar { defaults.set(phase.atCar, forKey: Keys.atCar) } }
    }
    /// Seconds until the lock goes out while leaving.
    private(set) var countdown: Int?

    private let link: BleCarLink
    private let api: CarAPI
    /// Fallback when the server doesn't answer in time.
    private let cachedStatus: () -> CarStatus?
    /// Another phone is driving the car (it holds the server's lease): don't watch for a walk-away.
    private let otherPhoneLeads: () -> Bool
    private let defaults = UserDefaults.standard
    private var smoothed: Double?
    private var readings = 0
    private var strongSince: Date?
    private var timer: Timer?
    private var lockPendingUntil: Date?
    private var leftUnlockedNoticeAt: Date?
    private var checking = false
    private var nextDoorCheck: Date?

    init(link: BleCarLink, api: CarAPI, cachedStatus: @escaping () -> CarStatus?, otherPhoneLeads: @escaping () -> Bool = { false }) {
        self.link = link
        self.api = api
        self.cachedStatus = cachedStatus
        self.otherPhoneLeads = otherPhoneLeads
        isOn = defaults.bool(forKey: Keys.wanted)
        let saved = defaults.integer(forKey: Keys.distance)
        distance = Self.distances.contains(saved) ? saved : Self.defaultDistance
        if AppConfig.demo { isOn = true }
        // iOS ended the last process mid-visit; its link drop is still to come.
        if link.orphanedSession, defaults.bool(forKey: Keys.atCar) { phase = .near }

        link.onReady.append { [weak self] in self?.sessionStarted() }
        link.onLinkLost.append { [weak self] in self?.linkLost() }
        link.onRSSI.append { [weak self] in self?.evaluate($0) }
        if link.state == .ready { sessionStarted() }
    }

    func enable() {
        isOn = true
        defaults.set(true, forKey: Keys.wanted)
        CarNotifications.requestQuietPermission()
        link.note("Auto-lock switched on (beyond ≈\(AutoUnlock.label(distance)))")
        if link.state == .ready { sessionStarted() }
    }

    func disable() {
        isOn = false
        defaults.set(false, forKey: Keys.wanted)
        lockPendingUntil = nil
        nextDoorCheck = nil
        stopWatching()
        phase = .idle
        link.note("Auto-lock switched off")
    }

    /// A lock or unlock was sent by hand: forget any walk-away in progress.
    func manualCommandSent() {
        guard isOn else { return }
        switch phase {
        case .near, .leaving, .awaitingReconnect, .doorOpen:
            link.note("Auto-lock: reset by a manual command")
            lockPendingUntil = nil
            nextDoorCheck = nil
            resetSignal()
            phase = .idle
        case .idle, .done:
            break
        }
    }

    var statusText: String {
        guard link.state == .ready else {
            if case .awaitingReconnect = phase { return "Lost the car's signal · locks if it comes back within 2 min" }
            return "Not connected to the car"
        }
        switch phase {
        case .idle: return "Waiting to see you at the car"
        case .near: return "At the car"
        case .leaving: return "Walking away · locks in \(countdown ?? Int(Self.holdTime)) s"
        case .done: return "Done for this visit"
        case .awaitingReconnect: return "Reconnected · checking the signal"
        case .doorOpen: return "A door is open · locks once it's shut"
        }
    }

    private func sessionStarted() {
        guard isOn else { return }
        guard !otherPhoneLeads() else {
            phase = .idle
            link.note("Auto-lock: another phone is driving the car; not watching")
            return
        }
        resetSignal()
        if let until = lockPendingUntil, Date() < until {
            phase = .awaitingReconnect(until: until)
            link.note("Auto-lock: reconnected; locking if you're still away")
        } else {
            lockPendingUntil = nil
            phase = .idle
        }
        startWatching()
    }

    private func linkLost() {
        stopWatching()
        guard isOn else { return }
        link.note("Auto-lock: link lost while \(phase.name)")
        if phase != .done, !otherPhoneLeads() { checkLeftUnlocked() }
        nextDoorCheck = nil
        switch phase {
        case .near, .leaving, .doorOpen:
            let until = Date().addingTimeInterval(Self.reconnectWindow)
            lockPendingUntil = until
            phase = .awaitingReconnect(until: until)
            link.note("Auto-lock: lost the car while leaving; will lock if it reconnects within 2 min")
        case .awaitingReconnect:
            break
        case .idle, .done:
            phase = .idle
        }
    }

    private func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.link.readRSSI() }
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        countdown = nil
    }

    private func resetSignal() {
        smoothed = nil
        readings = 0
        strongSince = nil
        countdown = nil
    }

    private func evaluate(_ rssi: Int) {
        guard isOn, timer != nil, let threshold = AutoUnlock.thresholds[distance] else { return }
        let value = smoothed.map { 0.3 * Double(rssi) + 0.7 * $0 } ?? Double(rssi)
        smoothed = value
        readings += 1
        let now = Date()

        switch phase {
        case .idle:
            guard value >= threshold else { strongSince = nil; return }
            let since = strongSince ?? now
            strongSince = since
            if now.timeIntervalSince(since) >= Self.nearHold {
                phase = .near
                link.note("Auto-lock: you're at the car (\(Int(value)) dBm)")
            }

        case .near:
            if value < threshold - Self.hysteresis {
                phase = .leaving(since: now)
                link.note("Auto-lock: signal weak (\(Int(value)) dBm), you may be leaving")
            }

        case .leaving(let since):
            if value >= threshold {
                phase = .near
                countdown = nil
                link.note("Auto-lock: you're back at the car")
                return
            }
            let remaining = max(Self.holdTime - now.timeIntervalSince(since), cooldownRemaining(at: now))
            countdown = Int(remaining.rounded(.up))
            if remaining <= 0 { lock(signal: Int(value)) }

        case .awaitingReconnect(let until):
            if now > until {
                lockPendingUntil = nil
                phase = .idle
                link.note("Auto-lock: reconnect window passed; not locking")
            } else if value >= threshold {
                lockPendingUntil = nil
                phase = .near
                link.note("Auto-lock: you came back to the car")
            } else if readings >= 3, cooldownRemaining(at: now) <= 0 {
                lock(signal: Int(value))
            }

        case .doorOpen(let until):
            if value >= threshold {
                phase = .near
                nextDoorCheck = nil
                link.note("Auto-lock: you're back at the car")
            } else if now > until {
                phase = .done
                nextDoorCheck = nil
                stopWatching()
                link.note("Auto-lock: the door stayed open; not locking")
                CarNotifications.post("Didn't lock the car as you walked away: a door is still open.")
            } else if let next = nextDoorCheck, now >= next {
                nextDoorCheck = nil
                lock(signal: Int(value))
            }

        case .done:
            break
        }
    }

    private func cooldownRemaining(at now: Date) -> TimeInterval {
        guard let last = link.lastCommandAt else { return 0 }
        return Self.cooldown - now.timeIntervalSince(last)
    }

    private func lock(signal: Int) {
        guard !checking else { return }
        checking = true
        lockPendingUntil = nil
        let recheck = if case .doorOpen = phase { true } else { false }
        if !recheck { link.note("Auto-lock: you've walked away (\(signal) dBm), checking the car") }
        Task {
            let reason = await vetoReason(refresh: recheck)
            checking = false
            guard link.state == .ready, phase.mayLock else { return }
            if reason == Self.doorOpen {
                if recheck {
                    nextDoorCheck = Date().addingTimeInterval(Self.doorRecheck)
                } else {
                    // The report may predate the door being shut: ask the car again straight away.
                    phase = .doorOpen(until: Date().addingTimeInterval(Self.doorWait))
                    countdown = nil
                    nextDoorCheck = Date()
                    link.note("Auto-lock: a door is open; locking once it's shut (up to 2 min)")
                }
                return
            }
            // One lock per visit, whatever the outcome.
            phase = .done
            nextDoorCheck = nil
            stopWatching()
            if let reason {
                if reason == Self.alreadyLocked {
                    link.note("Auto-lock: the car is already locked")
                } else {
                    link.note("Auto-lock: not locking, \(reason)")
                    CarNotifications.post("Didn't lock the car as you walked away: \(reason).")
                }
                return
            }
            if recheck { link.note("Auto-lock: the door is shut now") }
            do {
                try await link.send(.lock)
                if AppConfig.demo { DemoCar.apply(.lock) }
                CarNotifications.post("Locked as you walked away")
            } catch BleCarLink.CommandError.unconfirmed {
                CarNotifications.post("Sent lock as you walked away, but the car didn't confirm. Check the car.")
            } catch {
                CarNotifications.post("Auto-lock didn't go through: \(error.localizedDescription)")
            }
        }
    }

    private static let alreadyLocked = "already locked"
    private static let doorOpen = "a door is open"

    /// Asks the server, as the car sees it now, whether it was left unlocked; notifies if so.
    private func checkLeftUnlocked() {
        if let last = leftUnlockedNoticeAt, Date().timeIntervalSince(last) < Self.leftUnlockedQuiet { return }
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "auto-lock check") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        Task {
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            var status = await fetchStatus(refresh: true, timeout: Self.refreshTimeout)
            if status == nil { status = await fetchStatus() }
            guard link.state != .ready else {
                link.note("Auto-lock: reconnected to the car; skipping the left-unlocked check")
                return
            }
            guard let status, let at = status.receivedAt ?? status.updatedAt,
                  Date().timeIntervalSince(at) < Self.statusFreshness else {
                link.note("Auto-lock: no fresh report after losing the car; can't tell if it's locked")
                return
            }
            if status.locked != false {
                link.note("Auto-lock: the car is \(status.locked == true ? "locked" : "of unknown lock state")")
                return
            }
            if status.powerOn == true || (status.speedKmh ?? 0) > 0 {
                link.note("Auto-lock: the car is unlocked but on or moving; not notifying")
                return
            }
            leftUnlockedNoticeAt = Date()
            if status.anyDoorOpen == true || status.trunkOpen == true {
                link.note("Auto-lock: the car was left unlocked with a door open")
                CarNotifications.post("The car is unlocked and a door is open.")
            } else {
                link.note("Auto-lock: the car was left unlocked; offering to lock it")
                CarNotifications.postLeftUnlocked("The car is unlocked. Lock it through BYD's cloud?")
            }
        }
    }

    /// Why not to lock, according to a fresh server report; nil to go ahead.
    /// `refresh` asks the car for a new report first, falling back to the server's last one.
    private func vetoReason(refresh: Bool = false) async -> String? {
        var status = refresh ? await fetchStatus(refresh: true, timeout: Self.recheckTimeout) : nil
        if status == nil { status = await fetchStatus() }
        guard let status = status ?? cachedStatus(), let at = status.receivedAt ?? status.updatedAt,
              Date().timeIntervalSince(at) < Self.statusFreshness else { return nil }
        if status.powerOn == true { return "the car is on" }
        if let speed = status.speedKmh, speed > 0 { return "the car is moving" }
        if status.anyDoorOpen == true || status.trunkOpen == true { return Self.doorOpen }
        if status.locked == true { return Self.alreadyLocked }
        return nil
    }

    private func fetchStatus(refresh: Bool = false, timeout: TimeInterval = AutoLock.statusTimeout) async -> CarStatus? {
        let fetch = Task { try? await api.status(refresh: refresh) }
        let limit = Task {
            try? await Task.sleep(for: .seconds(timeout))
            fetch.cancel()
        }
        defer { limit.cancel() }
        return await fetch.value
    }
}
