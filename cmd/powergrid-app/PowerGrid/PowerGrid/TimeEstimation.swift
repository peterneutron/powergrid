//
//  TimeEstimation.swift
//  PowerGrid
//
//
//
// File: TimeEstimation.swift

import Foundation

enum TimeEstimateKind { case toFull, toEmpty }

struct TimeEstimate: Equatable {
    let kind: TimeEstimateKind
    let minutes: Int
    var formatted: String {
        guard minutes > 0 else { return "—" }
        let hrs = minutes / 60
        let mins = minutes % 60
        return String(format: "%d:%02d", hrs, mins)
    }
}

func computeTimeEstimate(status: Rpc_StatusResponse, intent: UserIntent) -> TimeEstimate? {
    let adapterPresent = Int(status.adapterMaxWatts) > 0
    let charge = Int(status.currentCharge)
    let limit = Int(status.chargeLimit)
    let smcChargingEnabled = status.smcChargingEnabled

    // Hide when paused at/above target or full
    let target = (limit < 100) ? limit : 100
    if !status.isCharging && charge >= target { return nil }
    if status.isConnected && charge >= 100 { return nil }
    if !smcChargingEnabled { return nil }

    // Discharging (on battery or forced discharge)
    if !status.isCharging {
        let tte = Int(status.timeToEmptyMinutes)
        if tte > 0, tte < 24 * 60 { return TimeEstimate(kind: .toEmpty, minutes: tte) }
        return nil
    }

    // Charging: require adapter present and below target
    guard adapterPresent, charge < target else { return nil }
    let rawTTF = Int(status.timeToFullMinutes)
    guard rawTTF > 0, rawTTF < 24 * 60 else { return nil }

    if limit < 100 {
        let remainingToFull = max(100 - charge, 1)
        let remainingToLimit = max(limit - charge, 0)
        if remainingToLimit <= 0 { return nil }
        let scaled = Int(round(Double(rawTTF) * Double(remainingToLimit) / Double(remainingToFull)))
        return scaled > 0 ? TimeEstimate(kind: .toFull, minutes: scaled) : nil
    }

    return TimeEstimate(kind: .toFull, minutes: rawTTF)
}

