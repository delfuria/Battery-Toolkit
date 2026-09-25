// SPDX-License-Identifier: BSD-3-Clause
import Foundation

// Replace only hardware, preferences, notifications and sleep side effects.
// The tests compile the production SMC power backend and daemon control loop.
@MainActor
public enum SMCComm {
    struct Key: Hashable, Sendable {
        let name: String
        init(_ a: Character, _ b: Character, _ c: Character, _ d: Character) {
            self.name = String([a, b, c, d])
        }
    }
    struct KeyInfoData: Equatable, Sendable {
        let dataSize: Int
        let dataType: String
        let dataAttributes: UInt8
    }
    struct KeyInfo: Sendable {
        let key: Key
        let info: KeyInfoData
    }
    enum KeyTypes {
        static let ui8 = "ui8 "
        static let ui32 = "ui32"
        static let hex = "hex_"
    }
    static var info: [String: KeyInfoData] = [:]
    static var values: [String: [UInt8]] = [:]
    static var writes: [(String, [UInt8])] = []
    static var failWrite: Int?
    static var unreadable: String?
    static var ignoreWrites = false
    static func start() -> Bool { true }
    static func stop() {}
    static func keySupported(keyInfo: KeyInfo) -> Bool { info[keyInfo.key.name] == keyInfo.info }
    static func readKey(key: Key, dataSize: Int) -> [UInt8]? {
        guard key.name != unreadable, let value = values[key.name], value.count == dataSize else { return nil }
        return value
    }
    static func writeKey(key: Key, bytes: [UInt8]) -> Bool {
        writes.append((key.name, bytes))
        if writes.count == failWrite { return false }
        guard info[key.name]?.dataSize == bytes.count else { return false }
        if !ignoreWrites { values[key.name] = bytes }
        return true
    }
    static func fixture(firmware: Bool = true, legacy: String? = nil) {
        info = [:]; values = [:]; writes = []
        failWrite = nil; unreadable = nil; ignoreWrites = false
        func add(_ name: String, _ type: String, _ value: [UInt8]) {
            info[name] = KeyInfoData(dataSize: value.count, dataType: type, dataAttributes: 0xD4)
            values[name] = value
        }
        add("CHIE", KeyTypes.hex, [0])
        if firmware {
            add("bfF0", KeyTypes.ui8, [0])
            add("bfD0", KeyTypes.ui32, [0, 0, 0, 0])
            add("bfE0", KeyTypes.ui32, [0, 0, 0, 0])
        }
        if let legacy {
            add(legacy, legacy == "CHTE" ? KeyTypes.ui32 : KeyTypes.hex,
                legacy == "CHTE" ? [0, 0, 0, 0] : [0])
        }
        IOPSPrivate.reading = (60, false, false)
        IOPSPrivate.external = true
        BTSettings.minCharge = 30; BTSettings.maxCharge = 80
        BTSettings.keepLimitOnShutdown = false
    }
}

@MainActor enum IOPSPrivate {
    static var reading: (UInt8, Bool, Bool)? = (60, false, false)
    static var external = true
    static func GetPercentRemaining() -> (UInt8, Bool, Bool)? { reading }
    static func DrawingUnlimitedPower() -> Bool { external }
}

@MainActor enum BTSettings {
    static var minCharge: UInt8 = 30
    static var maxCharge: UInt8 = 80
    static let adapterSleep = false
    static let magSafeSync = false
    static var keepLimitOnShutdown = false
    static func keepsLimitOnExit() -> Bool { keepLimitOnShutdown }
}

@MainActor enum GlobalSleep {
    static var count = 0
    static var disables = 0
    static func disable() { count += 1; disables += 1 }
    static func restore() { precondition(count > 0); count -= 1 }
    static func forceRestore() { count = 0 }
}

@MainActor enum BTDispatcher {
    static var power: (@MainActor (Int32) -> Void)?
    static var percent: (@MainActor (Int32) -> Void)?
    static func registerLimitedPowerNotification(_ handler: @MainActor @escaping (Int32) -> Void) -> Bool {
        power = handler; return true
    }
    static func registerPercentChangeNotification(_ handler: @MainActor @escaping (Int32) -> Void) -> Bool {
        percent = handler; return true
    }
    static func unregisterLimitedPowerNotification() { power = nil }
    static func unregisterPercentChangeNotification() { percent = nil }
}
