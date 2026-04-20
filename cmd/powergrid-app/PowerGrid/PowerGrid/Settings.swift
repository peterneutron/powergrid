//
//  Settings.swift
//  PowerGrid
//
//
//
// File: Settings.swift

import Foundation

enum MenuBarDisplayStyle: String, CaseIterable, Codable {
    case iconAndText
    case iconOnly
    case textOnly
    
    func next() -> MenuBarDisplayStyle {
        let allCases = Self.allCases
        guard let currentIndex = allCases.firstIndex(of: self) else {
            return .iconAndText
        }
        let nextIndex = allCases.index(after: currentIndex)
        return allCases.indices.contains(nextIndex) ? allCases[nextIndex] : allCases[0]
    }
}

struct AppSettings {
    static let appPreferencesDomain = "com.neutronstar.PowerGrid.ui"
    static let menuBarDisplayStyleKey = "menuBarDisplayStyle"
    static let preferredChargeLimitKey = "preferredChargeLimit"
    static let lowPowerNotificationsEnabledKey = "lowPowerNotificationsEnabled"
    static let showBatteryDetailsKey = "showBatteryDetails"
}

struct AppPreferences {
    static let shared = AppPreferences()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: AppSettings.appPreferencesDomain) ?? .standard) {
        self.defaults = defaults
    }

    func menuBarDisplayStyle() -> MenuBarDisplayStyle? {
        guard let rawValue = defaults.string(forKey: AppSettings.menuBarDisplayStyleKey) else { return nil }
        return MenuBarDisplayStyle(rawValue: rawValue)
    }

    func setMenuBarDisplayStyle(_ style: MenuBarDisplayStyle) {
        defaults.set(style.rawValue, forKey: AppSettings.menuBarDisplayStyleKey)
    }

    func preferredChargeLimit() -> Int? {
        defaults.object(forKey: AppSettings.preferredChargeLimitKey) as? Int
    }

    func setPreferredChargeLimit(_ limit: Int) {
        defaults.set(limit, forKey: AppSettings.preferredChargeLimitKey)
    }

    func lowPowerNotificationsEnabled() -> Bool? {
        guard defaults.object(forKey: AppSettings.lowPowerNotificationsEnabledKey) != nil else { return nil }
        return defaults.bool(forKey: AppSettings.lowPowerNotificationsEnabledKey)
    }

    func setLowPowerNotificationsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: AppSettings.lowPowerNotificationsEnabledKey)
    }

    func showBatteryDetails() -> Bool? {
        guard defaults.object(forKey: AppSettings.showBatteryDetailsKey) != nil else { return nil }
        return defaults.bool(forKey: AppSettings.showBatteryDetailsKey)
    }

    func setShowBatteryDetails(_ enabled: Bool) {
        defaults.set(enabled, forKey: AppSettings.showBatteryDetailsKey)
    }
}

enum SleepQuickMode: String, Equatable {
    case off
    case preventSystem
    case preventDisplay
}
