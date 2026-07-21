import Foundation

#if os(iOS)
import AlarmKit
import SwiftUI
import UserNotifications
#endif

@MainActor
protocol TimerAlarmScheduling: AnyObject {
    func requestAuthorization() async throws
    func schedule(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws
    func pause(timerID: String) throws
    func resume(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws
    func cancel(timerID: String) throws
}

enum TimerAlarmError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Allow notifications or alarms in Settings to receive timer alerts when Pomodorough is not open."
        }
    }
}

@MainActor
final class TimerAlarmScheduler: TimerAlarmScheduling {
    func requestAuthorization() async throws {
#if os(iOS)
        let notificationsAllowed = (try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        )) ?? false
        var alarmsAllowed = false
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            switch manager.authorizationState {
            case .notDetermined:
                alarmsAllowed = (try? await manager.requestAuthorization()) == .authorized
            case .authorized:
                alarmsAllowed = true
            case .denied:
                break
            @unknown default:
                break
            }
        }
        guard notificationsAllowed || alarmsAllowed else {
            throw TimerAlarmError.authorizationDenied
        }
#endif
    }

    func schedule(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
#if os(iOS)
        if #available(iOS 26.0, *),
           let alarmID = Self.alarmID(for: timerID),
           AlarmManager.shared.authorizationState == .authorized {
            try await scheduleAlarm(id: alarmID, timerID: timerID, phase: phase, duration: duration)
            return
        }
        try await scheduleNotification(timerID: timerID, phase: phase, duration: duration)
#endif
    }

    func pause(timerID: String) throws {
#if os(iOS)
        if #available(iOS 26.0, *),
           AlarmManager.shared.authorizationState == .authorized,
           let alarmID = Self.alarmID(for: timerID) {
            try AlarmManager.shared.pause(id: alarmID)
        } else {
            removeNotification(timerID: timerID)
        }
#endif
    }

    func resume(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
#if os(iOS)
        if #available(iOS 26.0, *),
           AlarmManager.shared.authorizationState == .authorized,
           let alarmID = Self.alarmID(for: timerID) {
            try AlarmManager.shared.resume(id: alarmID)
        } else {
            try await scheduleNotification(timerID: timerID, phase: phase, duration: duration)
        }
#endif
    }

    func cancel(timerID: String) throws {
#if os(iOS)
        if #available(iOS 26.0, *),
           AlarmManager.shared.authorizationState == .authorized,
           let alarmID = Self.alarmID(for: timerID) {
            let manager = AlarmManager.shared
            guard try manager.alarms.contains(where: { $0.id == alarmID }) else { return }
            try manager.cancel(id: alarmID)
        } else {
            removeNotification(timerID: timerID)
        }
#endif
    }

    nonisolated static func alarmID(for timerID: String) -> UUID? {
        guard timerID.hasPrefix("timer-") else { return nil }
        return UUID(uuidString: String(timerID.dropFirst("timer-".count)))
    }
}

#if os(iOS)
@available(iOS 26.0, *)
private struct TimerAlarmMetadata: AlarmMetadata {
    let timerID: String
    let phase: String
}

@available(iOS 26.0, *)
private extension TimerAlarmScheduler {
    func scheduleAlarm(
        id: UUID,
        timerID: String,
        phase: TimerPhase,
        duration: TimeInterval
    ) async throws {
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: Self.alert(for: phase)),
            metadata: TimerAlarmMetadata(timerID: timerID, phase: phase.rawValue),
            tintColor: Color(red: 1, green: 96.0 / 255.0, blue: 79.0 / 255.0)
        )
        let configuration = AlarmManager.AlarmConfiguration<TimerAlarmMetadata>.timer(
            duration: max(1, duration),
            attributes: attributes
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    static func alert(for phase: TimerPhase) -> AlarmPresentation.Alert {
        let title: LocalizedStringResource = switch phase {
        case .focus: "Focus complete"
        case .shortBreak: "Short break complete"
        case .longBreak: "Long break complete"
        }
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(title: title)
        }
        return legacyAlert(title: title)
    }

    @available(iOS, introduced: 26.0, obsoleted: 26.1)
    static func legacyAlert(title: LocalizedStringResource) -> AlarmPresentation.Alert {
        AlarmPresentation.Alert(
            title: title,
            stopButton: AlarmButton(text: "Done", textColor: .white, systemImageName: "stop.circle.fill")
        )
    }
}

private extension TimerAlarmScheduler {
    func scheduleNotification(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else {
            throw TimerAlarmError.authorizationDenied
        }

        let content = UNMutableNotificationContent()
        content.title = switch phase {
        case .focus: "Focus complete"
        case .shortBreak: "Short break complete"
        case .longBreak: "Long break complete"
        }
        content.body = "Your next Pomodorough interval is ready."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.notificationID(for: timerID),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, duration), repeats: false)
        )
        try await center.add(request)
    }

    func removeNotification(timerID: String) {
        let identifier = Self.notificationID(for: timerID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    nonisolated static func notificationID(for timerID: String) -> String {
        "pomodorough.\(timerID)"
    }
}
#endif
