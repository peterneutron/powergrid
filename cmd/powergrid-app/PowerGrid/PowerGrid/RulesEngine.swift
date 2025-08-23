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
}

enum RuleAction {
    case disableForceDischargeAndNotify(limit: Int)
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
    private let rules: [Rule] = [ForceDischargeAutoCutoffRule()]

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
        return actions
    }
}
