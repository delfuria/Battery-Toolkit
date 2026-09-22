// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import IOKit
import IOPMPrivate

// Read-only by default. The explicit --test-limit mode temporarily programs a
// range using the production implementation, then restores all three SMC keys.
@main
@MainActor
enum PowerControlProbe {
    static func main() async {
        let status = await run()
        exit(status)
    }

    static func run() async -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let test = arguments.count == 3 && arguments[0] == "--test-limit"
        guard arguments.isEmpty || test else {
            print("Usage: power-control-probe [--test-limit LOWER UPPER]")
            return 2
        }
        guard SMCComm.start() else { print("Cannot open AppleSMC"); return 1 }
        defer { SMCComm.stop() }

        print("Charging controls available: \(SMCComm.Power.supported())")
        print("Firmware charge limits: \(SMCComm.Power.usesFirmwareChargeLimit)")
        print("Current limit: \(String(describing: SMCComm.Power.firmwareChargeLimit()))")
        sample()
        guard test else { return 0 }
        guard let lower = UInt8(arguments[1]), let upper = UInt8(arguments[2]),
              lower >= 20, upper >= 50, lower < upper, upper <= 100,
              geteuid() == 0, SMCComm.Power.usesFirmwareChargeLimit else {
            print("Test requires root and a valid 20–100% range on supported firmware")
            return 2
        }

        let keys = [SMCComm.Key("b", "f", "F", "0"),
                    SMCComm.Key("b", "f", "D", "0"),
                    SMCComm.Key("b", "f", "E", "0")]
        let sizes = [1, 4, 4]
        var original: [[UInt8]] = []
        for (key, size) in zip(keys, sizes) {
            guard let bytes = SMCComm.readKey(key: key, dataSize: size) else {
                print("Cannot snapshot charging controls; test cancelled")
                return 1
            }
            original.append(bytes)
        }
        guard let settings = IOPMCopySystemPowerSettings()?.takeRetainedValue()
                as? [String: Any] else {
            print("Cannot snapshot sleep settings; test cancelled")
            return 1
        }
        let sleepDisabled = settings[kIOPMSleepDisabledKey as String] as? Bool ?? false
        guard IOPMSetSystemPowerSetting(kIOPMSleepDisabledKey as CFString, kCFBooleanTrue) == kIOReturnSuccess else {
            print("Cannot prevent clamshell sleep during the test; test cancelled")
            return 1
        }

        func restore() -> Bool {
            var success = SMCComm.writeKey(key: keys[0], bytes: [0])
            if success {
                for index in [1, 2, 0] {
                    let restored = SMCComm.writeKey(key: keys[index], bytes: original[index])
                    success = restored && success
                }
            }
            let restoredSleep = IOPMSetSystemPowerSetting(
                kIOPMSleepDisabledKey as CFString, sleepDisabled ? kCFBooleanTrue : kCFBooleanFalse
            ) == kIOReturnSuccess
            print("Restored charging controls: \(success); sleep setting: \(restoredSleep)")
            return success && restoredSleep
        }
        var cleanupAttempted = false
        defer { if !cleanupAttempted { _ = restore() } }

        // Also restore on an ordinary interruption of the bounded test.
        let interrupts = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    _ = restore()
                    SMCComm.stop()
                    exit(1)
                }
            }
            source.resume()
            return source
        }
        defer { interrupts.forEach { $0.cancel() } }

        guard SMCComm.Power.setFirmwareChargeLimit(lower: lower, upper: upper) else {
            print("Firmware rejected the range")
            return 1
        }
        print("Testing \(lower)–\(upper)% for 30 seconds; adapter controls are unchanged")
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            sample()
        }
        cleanupAttempted = true
        return restore() ? 0 : 1
    }

    static func sample() {
        let battery = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(battery) }
        let properties = ["CurrentCapacity", "IsCharging", "ExternalConnected",
                          "ExternalChargeCapable", "InstantAmperage"]
        print(properties.map { key in
            let value = IORegistryEntryCreateCFProperty(battery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            return "\(key)=\(value.map { String(describing: $0) } ?? "unknown")"
        }.joined(separator: " "))
    }
}
