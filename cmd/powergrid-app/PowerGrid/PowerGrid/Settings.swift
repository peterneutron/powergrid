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
    static let menuBarDisplayStyleKey = "menuBarDisplayStyle"
    static let showBatteryDetailsKey = "showBatteryDetails"
}
