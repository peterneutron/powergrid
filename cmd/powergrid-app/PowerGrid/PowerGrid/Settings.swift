//
//  Settings.swift
//  PowerGrid
//
//
//
import Foundation

// Defines the possible display styles for the menu bar item.
// It's RawRepresentable with a String to make it easy to save to UserDefaults.
enum MenuBarDisplayStyle: String, CaseIterable, Codable {
    case iconAndText
    case iconOnly
    case textOnly
    
    // This helper function provides the logic for cycling to the next state.
    func next() -> MenuBarDisplayStyle {
        // Get all possible cases in the defined order.
        let allCases = Self.allCases
        // Find the index of the current case.
        guard let currentIndex = allCases.firstIndex(of: self) else {
            return .iconAndText // Fallback, should never happen
        }
        // Calculate the next index, wrapping around to the beginning if at the end.
        let nextIndex = allCases.index(after: currentIndex)
        return allCases.indices.contains(nextIndex) ? allCases[nextIndex] : allCases[0]
    }
}

// A struct to hold keys for UserDefaults to prevent typos.
struct AppSettings {
    static let menuBarDisplayStyleKey = "menuBarDisplayStyle"
}
