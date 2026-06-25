//
//  RulesEngine.swift
//  PowerGrid
//
//
//
// File: RulesEngine.swift

import Foundation

func roundedHardwareBatteryPercent(for status: Rpc_StatusResponse) -> Int? {
    guard status.batteryHardwareChargeAvailable else { return nil }
    let precise = Double(status.batteryHardwareChargePercentPrecise)
    if precise > 0 {
        return Int(floor(precise + 0.5))
    }
    return Int(status.batteryHardwareChargePercent)
}

func currentBatteryPercent(for status: Rpc_StatusResponse, usingHardwareBatteryPercentage: Bool) -> Int {
    if usingHardwareBatteryPercentage,
       let hardwarePercent = roundedHardwareBatteryPercent(for: status) {
        return hardwarePercent
    }
    return Int(status.currentCharge)
}

func currentBatteryPercent(for status: Rpc_StatusResponse, intent: UserIntent) -> Int {
    currentBatteryPercent(
        for: status,
        usingHardwareBatteryPercentage: intent.showHardwareBatteryPercentage
    )
}

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
    var currentCharge: Int {
        currentBatteryPercent(for: currentStatus, intent: currentIntent)
    }
    var pausedAtOrAboveLimit: Bool {
        currentStatus.isChargeLimited && currentStatus.isConnected && !currentStatus.isCharging && Int(currentStatus.chargeLimit) < 100 && currentCharge >= Int(currentStatus.chargeLimit)
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
        // Fire once on the edge: when crossing from above cutoff to <= cutoff
        guard ctx.currentIntent.forceDischargeMode == .auto,
              ctx.previousIntent?.forceDischargeMode == .auto,
              ctx.currentStatus.forceDischargeActive,
              let previousStatus = ctx.previousStatus else { return nil }
        let prevCharge = currentBatteryPercent(for: previousStatus, intent: ctx.currentIntent)
        let curr = ctx.currentCharge
        guard prevCharge > ctx.autoCutoff && curr <= ctx.autoCutoff else { return nil }
        return .disableForceDischargeAndNotify(limit: ctx.autoCutoff)
    }
}

final class RulesEngine {
    private let rules: [Rule] = [ForceDischargeAutoCutoffRule(), LowBattery20Rule(), LowBattery10Rule()]

    func evaluate(_ ctx: RuleContext) -> [RuleAction] {
        var actions: [RuleAction] = []
        for rule in rules {
            if rule.isArmed(ctx), let action = rule.shouldFire(ctx) {
                actions.append(action)
            }
        }
        return actions
    }
}

struct LowBattery20Rule: Rule {
    let id = "lowBattery.20"
    func isArmed(_ ctx: RuleContext) -> Bool {
        ctx.currentIntent.lowPowerNotificationsEnabled && !ctx.currentStatus.isCharging && !ctx.pausedAtOrAboveLimit
    }
    func shouldFire(_ ctx: RuleContext) -> RuleAction? {
        guard let previous = ctx.previousStatus else { return nil }
        let prev = currentBatteryPercent(for: previous, intent: ctx.currentIntent)
        let curr = ctx.currentCharge
        if prev > 20 && curr <= 20 {
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
        guard let previous = ctx.previousStatus else { return nil }
        let prev = currentBatteryPercent(for: previous, intent: ctx.currentIntent)
        let curr = ctx.currentCharge
        if prev > 10 && curr <= 10 {
            return .notifyLowPower(threshold: 10)
        }
        return nil
    }
}
