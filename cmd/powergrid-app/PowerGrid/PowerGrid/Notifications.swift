//
//  Notifications.swift
//  PowerGrid
//

import Foundation
import UserNotifications

actor NotificationsService {
    static let shared = NotificationsService()
    private var didRequestAuth = false

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
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        _ = try? await UNUserNotificationCenter.current().add(request)
    }
}

