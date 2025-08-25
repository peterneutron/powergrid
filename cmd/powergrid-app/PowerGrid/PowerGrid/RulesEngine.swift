//
//  RulesEngine.swift
//  PowerGrid
//
//
//
// File: RulesEngine.swift

import Foundation

struct RuleContext {
    let previousStatus: Rpc_StatusResponse?
    let currentStatus: Rpc_StatusResponse
    let previousIntent: UserIntent?
    let currentIntent: UserIntent

    // Derived values used by rules
    var adapterPresent: Bool { Int(currentStatus.adapterMaxWatts) > 0 }
    var userLimit: Int {
        let active = Int(currentStatus.chargeLimit)
        return active < 100 ? active : currentIntent.preferredChargeLimit
    }
    var autoCutoff: Int { min(max(userLimit, 60), 99) }
    var pausedAtOrAboveLimit: Bool {
        currentStatus.isConnected && !currentStatus.isCharging && Int(currentStatus.chargeLimit) < 100 && Int(currentStatus.currentCharge) >= Int(currentStatus.chargeLimit)
    }
}

enum RuleAction {
    case disableForceDischargeAndNotify(limit: Int)
    case notifyLowPower(threshold: Int)
}

protocol Rule {
    var id: String { get }
    func isArmed(_ ctx: RuleContext) -> Bool
    func shouldFire(_ ctx: RuleContext) -> RuleAction?
}

struct ForceDischargeAutoCutoffRule: Rule {
    let id = "forceDischarge.autoCutoff"
    func isArmed(_ ctx: RuleContext) -> Bool {
        ctx.currentIntent.forceDischargeMode == .auto && ctx.currentStatus.forceDischargeActive
    }
    func shouldFire(_ ctx: RuleContext) -> RuleAction? {
        // Only fire if Auto was and still is the selected mode, FD is active,
        // and charge is at/below the user cutoff.
        guard ctx.currentIntent.forceDischargeMode == .auto,
              ctx.previousIntent?.forceDischargeMode == .auto,
              ctx.currentStatus.forceDischargeActive,
              Int(ctx.currentStatus.currentCharge) <= ctx.autoCutoff else { return nil }
        return .disableForceDischargeAndNotify(limit: ctx.autoCutoff)
    }
}

final class RulesEngine {
    private var armed: [String: Bool] = [:]
    private let rules: [Rule] = [ForceDischargeAutoCutoffRule(), LowBattery20Rule(), LowBattery10Rule()]
    // Debounce state for low-power notifications
    private var didNotifyBelow20 = false
    private var didNotifyBelow10 = false

    func evaluate(_ ctx: RuleContext) -> [RuleAction] {
        // Update armed states
        for rule in rules {
            let isNowArmed = rule.isArmed(ctx)
            armed[rule.id] = (armed[rule.id] ?? false) || isNowArmed
        }

        // Collect actions, only when previously armed for that rule
        var actions: [RuleAction] = []
        for rule in rules {
            if (armed[rule.id] ?? false), let action = rule.shouldFire(ctx) {
                actions.append(action)
                armed[rule.id] = false // consume arm on fire
            }
            // If rule is not armed due to mode changes, disarm
            if !rule.isArmed(ctx) && ctx.previousIntent?.forceDischargeMode != .auto {
                armed[rule.id] = false
            }
        }
        // Reset debouncers with hysteresis bands
        let charge = Int(ctx.currentStatus.currentCharge)
        if charge >= 22 { didNotifyBelow20 = false }
        if charge >= 12 { didNotifyBelow10 = false }
        return actions
    }
}

struct LowBattery20Rule: Rule {
    let id = "lowBattery.20"
    func isArmed(_ ctx: RuleContext) -> Bool {
        ctx.currentIntent.lowPowerNotificationsEnabled && !ctx.currentStatus.isCharging && !ctx.pausedAtOrAboveLimit
    }
    func shouldFire(_ ctx: RuleContext) -> RuleAction? {
        guard ctx.previousStatus != nil else { return nil }
        let prev = Int(ctx.previousStatus!.currentCharge)
        let curr = Int(ctx.currentStatus.currentCharge)
        // Edge-triggered on crossing below 20%
        if prev > 20 && curr <= 20 {
            // Debounce check via engine state
            // The engine resets when charge >= 22%
            // We can't access engine flags here; DaemonClient will filter duplicates if needed.
            return .notifyLowPower(threshold: 20)
        }
        return nil
    }
}

struct LowBattery10Rule: Rule {
    let id = "lowBattery.10"
    func isArmed(_ ctx: RuleContext) -> Bool {
        ctx.currentIntent.lowPowerNotificationsEnabled && !ctx.currentStatus.isCharging && !ctx.pausedAtOrAboveLimit
    }
    func shouldFire(_ ctx: RuleContext) -> RuleAction? {
        guard ctx.previousStatus != nil else { return nil }
        let prev = Int(ctx.previousStatus!.currentCharge)
        let curr = Int(ctx.currentStatus.currentCharge)
        if prev > 10 && curr <= 10 {
            return .notifyLowPower(threshold: 10)
        }
        return nil
    }
}
