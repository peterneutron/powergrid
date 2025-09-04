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
        // Fire once on the edge: when crossing from above cutoff to <= cutoff
        guard ctx.currentIntent.forceDischargeMode == .auto,
              ctx.previousIntent?.forceDischargeMode == .auto,
              ctx.currentStatus.forceDischargeActive,
              let prev = ctx.previousStatus?.currentCharge else { return nil }
        let prevCharge = Int(prev)
        let curr = Int(ctx.currentStatus.currentCharge)
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
        guard ctx.previousStatus != nil else { return nil }
        let prev = Int(ctx.previousStatus!.currentCharge)
        let curr = Int(ctx.currentStatus.currentCharge)
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
        guard ctx.previousStatus != nil else { return nil }
        let prev = Int(ctx.previousStatus!.currentCharge)
        let curr = Int(ctx.currentStatus.currentCharge)
        if prev > 10 && curr <= 10 {
            return .notifyLowPower(threshold: 10)
        }
        return nil
    }
}
