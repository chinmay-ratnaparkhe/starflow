import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - PlannedReminder

/// One local notification the planner wants on the calendar.
public struct PlannedReminder: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let fireDate: Date

    public init(id: String, title: String, body: String, fireDate: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.fireDate = fireDate
    }
}

// MARK: - Notification-center seam (mockable in tests)

public protocol EventNotifying: Sendable {
    func requestAuthorization() async -> Bool
    func pendingIdentifiers() async -> [String]
    func removePending(identifiers: [String]) async
    func add(_ reminder: PlannedReminder) async
}

// MARK: - Planner (pure)

/// Decides which events deserve a reminder and when it should fire. Pure —
/// everything (events, now, calendar) is injected.
public enum EventReminderPlanner {

    /// Only events peaking within this many days get scheduled.
    public static let horizonDays = 30
    /// Evening-of reminders fire at 18:00 local.
    public static let eveningHour = 18
    /// Daytime (solar-eclipse) reminders fire at 09:00 local on the day itself.
    public static let morningHour = 9

    public static func plan(events: [SkyEvent], now: Date,
                            calendar: Calendar = .current) -> [PlannedReminder] {
        let horizon = now.addingTimeInterval(Double(horizonDays) * 86_400.0)
        return events.compactMap { event in
            // Gate on the fire moment, not the peak instant: a shower whose 12:00 UT
            // peak stamp has passed still owns tonight's observing night, and its
            // 18:00 reminder must survive an afternoon resync. `fire > now` (below)
            // keeps genuinely past events out.
            guard event.date <= horizon else { return nil }
            let rarity = RarityScorer.score(for: event, calendar: calendar)
            guard rarity.score >= RarityScorer.notifyThreshold else { return nil }
            guard let fire = fireDate(for: event, calendar: calendar), fire > now else {
                return nil
            }
            let title: String
            if event.kind == .solarEclipse {
                // The 09:00 nudge normally lands the morning of the eclipse; when
                // mid-eclipse comes before 09:00 the planner fell back to the evening
                // before, and "today" would be a lie.
                let mid = event.visibility.bestTime ?? event.date
                title = calendar.isDate(fire, inSameDayAs: mid)
                    ? "\(event.name) today"
                    : "\(event.name) tomorrow morning"
            } else {
                title = "\(event.name) tonight"
            }
            return PlannedReminder(id: EventReminderScheduler.idPrefix + event.id,
                                   title: title,
                                   body: rarity.reason,
                                   fireDate: fire)
        }
    }

    /// Night events: 18:00 on the evening of the observing night (a 2 am best time
    /// belongs to the previous evening — same anchoring as the reason line).
    /// Solar eclipses are daytime events: 09:00 on the day of mid-eclipse — unless
    /// mid-eclipse itself comes before 09:00 local, in which case a "today" nudge
    /// would fire after the show; those fall back to 18:00 the evening before.
    static func fireDate(for event: SkyEvent, calendar: Calendar) -> Date? {
        var anchor = event.visibility.bestTime ?? event.date
        if event.kind == .solarEclipse {
            if let morning = calendar.date(bySettingHour: morningHour, minute: 0,
                                           second: 0, of: anchor),
               morning < anchor {
                return morning
            }
            return calendar.date(bySettingHour: eveningHour, minute: 0, second: 0,
                                 of: anchor.addingTimeInterval(-86_400.0))
        }
        if calendar.component(.hour, from: anchor) < 12 {
            anchor = anchor.addingTimeInterval(-43_200)
        }
        return calendar.date(bySettingHour: eveningHour, minute: 0, second: 0, of: anchor)
    }
}

// MARK: - Scheduler (idempotent)

/// Reconciles the pending-notification set with the planner's desired set.
/// Idempotent: running it twice with the same inputs changes nothing, and it never
/// touches notifications outside its own `starflow.event.` namespace.
public final class EventReminderScheduler {

    public static let idPrefix = "starflow.event."

    private let center: EventNotifying

    public init(center: EventNotifying) {
        self.center = center
    }

    public func requestAuthorization() async -> Bool {
        await center.requestAuthorization()
    }

    public func reschedule(events: [SkyEvent], now: Date = Date(),
                           calendar: Calendar = .current) async {
        let planned = EventReminderPlanner.plan(events: events, now: now, calendar: calendar)
        let desiredIDs = Set(planned.map { $0.id })
        let pending = await center.pendingIdentifiers().filter { $0.hasPrefix(Self.idPrefix) }
        let stale = pending.filter { !desiredIDs.contains($0) }
        if !stale.isEmpty {
            await center.removePending(identifiers: stale)
        }
        let pendingSet = Set(pending)
        for reminder in planned where !pendingSet.contains(reminder.id) {
            await center.add(reminder)
        }
    }

    public func cancelAll() async {
        let ours = await center.pendingIdentifiers().filter { $0.hasPrefix(Self.idPrefix) }
        if !ours.isEmpty {
            await center.removePending(identifiers: ours)
        }
    }
}

// MARK: - Real center

#if canImport(UserNotifications)
/// Production wrapper over UNUserNotificationCenter.
public struct UserNotificationEventCenter: EventNotifying {

    public init() {}

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .map { $0.identifier }
    }

    public func removePending(identifiers: [String]) async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func add(_ reminder: PlannedReminder) async {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: reminder.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: reminder.id,
                                            content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif

/// No-op fallback for platforms without UserNotifications.
public struct NoopEventCenter: EventNotifying {
    public init() {}
    public func requestAuthorization() async -> Bool { false }
    public func pendingIdentifiers() async -> [String] { [] }
    public func removePending(identifiers: [String]) async {}
    public func add(_ reminder: PlannedReminder) async {}
}

// MARK: - App-facing service

/// User-toggleable, permission-gated event reminders. Tonight feeds it the freshly
/// computed event list; Settings flips it on and off. All scheduling is idempotent,
/// so repeated syncs never duplicate notifications.
@MainActor
public final class EventReminderService: ObservableObject {

    public static let shared = EventReminderService()
    public static let enabledDefaultsKey = "eventReminders"

    /// True after the user tried to enable reminders but iOS said no — Settings
    /// shows the fix-it hint off this.
    @Published public private(set) var authorizationDenied = false

    private let scheduler: EventReminderScheduler
    private var lastEvents: [SkyEvent] = []

    private init() {
        #if canImport(UserNotifications)
        scheduler = EventReminderScheduler(center: UserNotificationEventCenter())
        #else
        scheduler = EventReminderScheduler(center: NoopEventCenter())
        #endif
    }

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    /// Turn reminders on (asks iOS for notification permission first) or off
    /// (cancels every StarFlow event reminder). Returns the resulting enabled state.
    @discardableResult
    public func setEnabled(_ on: Bool) async -> Bool {
        guard on else {
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            await scheduler.cancelAll()
            return false
        }
        let granted = await scheduler.requestAuthorization()
        authorizationDenied = !granted
        UserDefaults.standard.set(granted, forKey: Self.enabledDefaultsKey)
        if granted {
            await scheduler.reschedule(events: lastEvents)
        }
        return granted
    }

    /// Called whenever Tonight recomputes the upcoming-event list.
    public func sync(events: [SkyEvent]) async {
        lastEvents = events
        guard isEnabled else { return }
        await scheduler.reschedule(events: events)
    }
}
