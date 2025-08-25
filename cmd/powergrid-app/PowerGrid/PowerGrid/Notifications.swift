//
//  Notifications.swift
//  PowerGrid
//

import Foundation
import UserNotifications

actor NotificationsService {
    static let shared = NotificationsService()
    private var didRequestAuth = false
    static let lowPowerCategoryID = "LOW_POWER"
    static let enableLowPowerActionID = "ENABLE_LOW_POWER"

    func requestAuthOnce() async {
        guard !didRequestAuth else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        didRequestAuth = true
    }

    func post(title: String, body: String) async {
        await requestAuthOnce()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        _ = try? await UNUserNotificationCenter.current().add(request)
    }

    func registerLowPowerCategory() {
        let action = UNNotificationAction(identifier: Self.enableLowPowerActionID,
                                          title: "Enable Low Power Mode",
                                          options: [])
        let category = UNNotificationCategory(identifier: Self.lowPowerCategoryID,
                                              actions: [action],
                                              intentIdentifiers: [],
                                              options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func postLowPowerAlert(threshold: Int, includeEnableAction: Bool) async {
        await requestAuthOnce()
        let content = UNMutableNotificationContent()
        if threshold <= 10 {
            content.title = "Critical Battery"
            content.body = "Battery at \(threshold)%. Consider enabling Low Power Mode."
        } else {
            content.title = "Battery Low"
            content.body = "Battery at \(threshold)%."
        }
        content.sound = .default
        if includeEnableAction {
            content.categoryIdentifier = Self.lowPowerCategoryID
        }
        if #available(macOS 12.0, *) {
            content.interruptionLevel = threshold <= 10 ? .timeSensitive : .timeSensitive
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        _ = try? await UNUserNotificationCenter.current().add(request)
    }
}

final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    weak var client: DaemonClient?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == NotificationsService.enableLowPowerActionID {
            await client?.setPowerFeature(feature: .lowPowerMode, enable: true)
        }
    }
}
