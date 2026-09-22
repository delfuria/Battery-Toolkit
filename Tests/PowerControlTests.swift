// SPDX-License-Identifier: BSD-3-Clause
import Foundation

@main
@MainActor
enum PowerControlTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                       file: StaticString = #file, line: UInt = #line) {
        checks += 1
        precondition(condition(), message, file: file, line: line)
    }
    static func range(_ lower: UInt8, _ upper: UInt8) {
        expect(SMCComm.Power.firmwareChargeLimit() ==
            .init(active: true, lower: lower, upper: upper), "Expected range \(lower)–\(upper)")
    }
    static func percentage(_ percent: UInt8, charging: Bool = false) {
        IOPSPrivate.reading = (percent, charging, percent == 100)
        BTDispatcher.percent?(0)
    }
    static func main() throws {
        SMCComm.fixture()
        expect(SMCComm.Power.supported(), "15.8 keys must be detected")
        expect(SMCComm.Power.usesFirmwareChargeLimit, "Use firmware ranges without a version check")
        expect(SMCComm.Power.setFirmwareChargeLimit(lower: 30, upper: 80), "Program 30–80")
        range(30, 80)
        expect(SMCComm.writes.map(\.0) == ["bfF0", "bfD0", "bfE0", "bfF0"], "Write ordering")
        expect(SMCComm.values["bfD0"] == [80, 0, 0, 0], "Little-endian upper")
        expect(SMCComm.values["bfE0"] == [30, 0, 0, 0], "Little-endian lower")
        SMCComm.writes = []
        expect(SMCComm.Power.setFirmwareChargeLimit(lower: 30, upper: 80), "Idempotent update")
        expect(SMCComm.writes.isEmpty, "Do not restart a charge cycle on repeated events")
        expect(!SMCComm.Power.setFirmwareChargeLimit(lower: 80, upper: 80), "Reject empty range")
        expect(!SMCComm.Power.setFirmwareChargeLimit(lower: 30, upper: 101), "Reject unsafe upper")
        expect(SMCComm.writes.isEmpty, "Invalid inputs must not write")

        // Each failed stage must restore the previously active range.
        for failure in 1...4 {
            SMCComm.writes = []; SMCComm.failWrite = failure
            expect(!SMCComm.Power.setFirmwareChargeLimit(lower: 40, upper: 90), "Report failed write \(failure)")
            range(30, 80)
        }
        SMCComm.failWrite = nil; SMCComm.writes = []
        SMCComm.unreadable = "bfE0"
        expect(!SMCComm.Power.setFirmwareChargeLimit(lower: 40, upper: 90), "Reject unreadable snapshot")
        expect(SMCComm.writes.isEmpty, "Do not overwrite unknown state")
        SMCComm.unreadable = nil; SMCComm.ignoreWrites = true
        expect(!SMCComm.Power.setFirmwareChargeLimit(lower: 40, upper: 90), "Reject false write success")
        SMCComm.ignoreWrites = false

        // Partial or malformed firmware support is not sufficient.
        SMCComm.fixture(); SMCComm.info.removeValue(forKey: "bfE0")
        expect(!SMCComm.Power.supported(), "All three firmware keys are required")
        SMCComm.fixture()
        SMCComm.info["bfD0"] = .init(dataSize: 1, dataType: "ui8 ", dataAttributes: 0xD4)
        expect(!SMCComm.Power.supported(), "Validate firmware key layout")

        // Exercise the production event loop, including closed-lid sleep policy.
        SMCComm.fixture()
        GlobalSleep.disables = 0
        try BTPowerEvents.start()
        range(30, 80)
        expect(GlobalSleep.disables == 0, "Firmware control does not inhibit normal sleep")
        SMCComm.writes = []
        for level: UInt8 in [80, 79, 60, 30, 29] { percentage(level) }
        range(30, 80)
        expect(SMCComm.writes.isEmpty, "Firmware owns hysteresis across both bounds")
        IOPSPrivate.external = false; BTDispatcher.power?(0)
        range(30, 80)
        expect(BTDispatcher.percent != nil, "Keep limits on unplug and firmware discharge")
        IOPSPrivate.external = true; BTDispatcher.power?(0)
        expect(SMCComm.writes.allSatisfy { !$0.0.hasPrefix("CH") }, "Range control never disables adapter")
        SMCComm.values["bfF0"] = [0]
        BTPowerEvents.wakeFromSleep()
        range(30, 80)
        expect(GlobalSleep.disables == 0, "Wake preserves clamshell sleep settings")
        let oldValues = SMCComm.values
        IOPSPrivate.reading = nil
        BTPowerEvents.settingsChanged()
        expect(SMCComm.values == oldValues, "Missing telemetry preserves the last good range")
        percentage(60)
        expect(BTPowerEvents.chargeToLimit(), "Manual charge to limit")
        range(79, 80)
        percentage(80)
        range(30, 80)
        expect(BTPowerEvents.chargingMode == .standard, "Return to standard at limit")
        expect(BTPowerEvents.chargeToFull(), "Manual full charge")
        expect(SMCComm.values["bfF0"] == [0], "Full charge releases range")
        percentage(99, charging: true)
        expect(SMCComm.values["bfF0"] == [0], "Keep full-charge override below 100")
        percentage(100)
        range(30, 100)
        percentage(99)
        range(30, 100)
        percentage(80)
        range(30, 80)
        percentage(60)
        expect(BTPowerEvents.disableCharging(), "Manual stop")
        range(30, 60)
        percentage(59)
        range(30, 60)
        percentage(29)
        range(30, 80)
        expect(BTPowerEvents.disableCharging(), "Honor explicit stop even below the minimum")
        range(28, 29)
        percentage(28)
        range(30, 80)
        SMCComm.writes = []; SMCComm.failWrite = 1
        expect(!BTPowerEvents.chargeToFull(), "Report a failed manual command")
        expect(BTPowerEvents.chargingMode == .standard, "Do not retain a failed command")
        range(30, 80)
        SMCComm.failWrite = nil
        BTSettings.minCharge = 50; BTSettings.maxCharge = 50
        BTPowerEvents.settingsChanged()
        range(49, 50)
        BTPowerEvents.stop()
        expect(SMCComm.values["bfF0"] == [0], "Pause removes range even if battery was charging")
        expect(GlobalSleep.count == 0, "No leaked sleep override")

        // Both existing firmware generations retain software hysteresis.
        for legacy in ["CHTE", "CH0C"] {
            SMCComm.fixture(firmware: false, legacy: legacy)
            expect(SMCComm.Power.supported(), "Legacy \(legacy) remains supported")
            expect(!SMCComm.Power.usesFirmwareChargeLimit, "Use legacy control")
            try BTPowerEvents.start()
            percentage(80)
            expect(BTPowerState.isChargingDisabled(), "Stop at 80 on \(legacy)")
            percentage(30)
            expect(BTPowerState.isChargingDisabled(), "Do not restart at exactly 30")
            percentage(29, charging: false)
            expect(!BTPowerState.isChargingDisabled(), "Restart below 30")
            percentage(60, charging: true)
            expect(!BTPowerState.isChargingDisabled(), "Continue charge to upper bound")
            BTPowerEvents.stop()
            expect(GlobalSleep.count == 0, "Restore sleep after legacy stop")
        }
        print("Passed \(checks) power-control checks")
    }
}
