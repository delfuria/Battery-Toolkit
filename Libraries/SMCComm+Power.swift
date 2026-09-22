//
// Copyright (C) 2022 - 2025 Marvin Häuser. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
//

import os.log

public extension SMCComm {
    @MainActor
    enum Power {
        private static let chargeKeys = [
            KeyControl.CHTE,
            KeyControl.CH0C
        ]
        private static let adapterKeys = [
            KeyControl.CHIE,
            KeyControl.CH0J
        ]

        private static var chargeKey: Int?
        private static var adapterKey: Int?
        private(set) static var usesFirmwareChargeLimit = false

        static func supported() -> Bool {
            //
            // Ensure all required SMC keys are present and well-formed.
            //
            self.chargeKey = self.chargeKeys.firstIndex { key in
                SMCComm.keySupported(keyInfo: key.keyInfo)
            }
            // Firmware updates can introduce these keys on older macOS releases,
            // including 15.8. Detect capabilities, not the OS version.
            self.usesFirmwareChargeLimit = self.chargeKey == nil &&
                [Keys.bfF0, Keys.bfD0, Keys.bfE0].allSatisfy {
                    SMCComm.keySupported(keyInfo: $0)
                }

            self.adapterKey = self.adapterKeys.firstIndex { key in
                SMCComm.keySupported(keyInfo: key.keyInfo)
            }

            return (self.chargeKey != nil || self.usesFirmwareChargeLimit) &&
                self.adapterKey != nil
        }

        static func enableCharging() -> Bool {
            if self.usesFirmwareChargeLimit {
                return self.clearFirmwareChargeLimit()
            }
            guard let chargeKey = self.chargeKey else { return false }
            return SMCComm.writeKey(
                key: self.chargeKeys[chargeKey].keyInfo.key,
                bytes: self.chargeKeys[chargeKey].onBytes
            )
        }

        static func disableCharging() -> Bool {
            // The firmware backend requires a range, not an on/off write.
            guard let chargeKey = self.chargeKey else { return false }
            return SMCComm.writeKey(
                key: self.chargeKeys[chargeKey].keyInfo.key,
                bytes: self.chargeKeys[chargeKey].offBytes
            )
        }

        static func isChargingDisabled() -> Bool {
            if self.usesFirmwareChargeLimit {
                guard let limit = self.firmwareChargeLimit(),
                      let (_, charging, _) = IOPSPrivate.GetPercentRemaining() else {
                    return false
                }
                return limit.active && !charging
            }
            guard let chargeKey = self.chargeKey else { return false }
            let value = SMCComm.readKey(
                key: self.chargeKeys[chargeKey].keyInfo.key,
                dataSize: self.chargeKeys[chargeKey].onBytes.count
            )
            guard let value else {
                return false
            }

            return value != self.chargeKeys[chargeKey].onBytes
        }

        static func enablePowerAdapter() -> Bool {
            guard let adapterKey = self.adapterKey else { return false }
            return SMCComm.writeKey(
                key: self.adapterKeys[adapterKey].keyInfo.key,
                bytes: self.adapterKeys[adapterKey].onBytes
            )
        }

        static func disablePowerAdapter() -> Bool {
            guard let adapterKey = self.adapterKey else { return false }
            return SMCComm.writeKey(
                key: self.adapterKeys[adapterKey].keyInfo.key,
                bytes: self.adapterKeys[adapterKey].offBytes
            )
        }

        static func isPowerAdapterDisabled() -> Bool {
            guard let adapterKey = self.adapterKey else { return false }
            let value = SMCComm.readKey(
                key: self.adapterKeys[adapterKey].keyInfo.key,
                dataSize: self.adapterKeys[adapterKey].onBytes.count
            )
            guard let value else {
                return false
            }

            return value != self.adapterKeys[adapterKey].onBytes
        }

        struct FirmwareChargeLimit: Equatable {
            let active: Bool
            let lower: UInt8
            let upper: UInt8
        }

        static func firmwareChargeLimit() -> FirmwareChargeLimit? {
            guard self.usesFirmwareChargeLimit,
                  let activation = SMCComm.readKey(key: Keys.bfF0.key, dataSize: 1),
                  activation == [0] || activation == [2],
                  let lower = self.readPercentage(key: Keys.bfE0.key),
                  let upper = self.readPercentage(key: Keys.bfD0.key) else {
                return nil
            }
            guard activation == [0] || lower < upper else { return nil }
            return FirmwareChargeLimit(active: activation == [2], lower: lower, upper: upper)
        }

        static func setFirmwareChargeLimit(lower: UInt8, upper: UInt8) -> Bool {
            guard lower < upper, upper <= 100,
                  let previous = self.firmwareChargeLimit() else { return false }
            let requested = FirmwareChargeLimit(active: true, lower: lower, upper: upper)
            if previous == requested { return true }

            guard self.writeFirmwareChargeLimit(requested),
                  self.firmwareChargeLimit() == requested else {
                // Do not leave a partially programmed range active after an error.
                if !self.writeFirmwareChargeLimit(previous) {
                    os_log("Failed to restore firmware charging limits; clearing activation")
                    _ = self.clearFirmwareChargeLimit()
                }
                return false
            }
            return true
        }

        static func clearFirmwareChargeLimit() -> Bool {
            guard self.usesFirmwareChargeLimit,
                  let activation = SMCComm.readKey(key: Keys.bfF0.key, dataSize: 1) else {
                return false
            }
            return activation == [0] || self.writeVerified(key: Keys.bfF0.key, bytes: [0])
        }

        private static func readPercentage(key: SMCComm.Key) -> UInt8? {
            guard let bytes = SMCComm.readKey(key: key, dataSize: 4),
                  bytes.count == 4, bytes[0] <= 100,
                  bytes[1...3].allSatisfy({ $0 == 0 }) else { return nil }
            return bytes[0]
        }

        private static func writeVerified(key: SMCComm.Key, bytes: [UInt8]) -> Bool {
            return SMCComm.writeKey(key: key, bytes: bytes) &&
                SMCComm.readKey(key: key, dataSize: bytes.count) == bytes
        }

        private static func writeFirmwareChargeLimit(_ limit: FirmwareChargeLimit) -> Bool {
            // These ui32 percentages are little-endian. Deactivate before changing
            // either bound, and activate only after both writes have been verified.
            return self.writeVerified(key: Keys.bfF0.key, bytes: [0]) &&
                self.writeVerified(key: Keys.bfD0.key, bytes: [limit.upper, 0, 0, 0]) &&
                self.writeVerified(key: Keys.bfE0.key, bytes: [limit.lower, 0, 0, 0]) &&
                self.writeVerified(key: Keys.bfF0.key, bytes: [limit.active ? 2 : 0])
        }
    }
}

private extension SMCComm.Power {
    private enum Keys {
        static let bfF0 = SMCComm.KeyInfo(
            key: SMCComm.Key("b", "f", "F", "0"),
            info: SMCComm.KeyInfoData(dataSize: 1, dataType: SMCComm.KeyTypes.ui8, dataAttributes: 0xD4)
        )
        static let bfD0 = SMCComm.KeyInfo(
            key: SMCComm.Key("b", "f", "D", "0"),
            info: SMCComm.KeyInfoData(dataSize: 4, dataType: SMCComm.KeyTypes.ui32, dataAttributes: 0xD4)
        )
        static let bfE0 = SMCComm.KeyInfo(
            key: SMCComm.Key("b", "f", "E", "0"),
            info: SMCComm.KeyInfoData(dataSize: 4, dataType: SMCComm.KeyTypes.ui32, dataAttributes: 0xD4)
        )
        static let CHTE = SMCComm.KeyInfo(
            key: SMCComm.Key("C", "H", "T", "E"),
            info: SMCComm.KeyInfoData(
                dataSize: 4,
                dataType: SMCComm.KeyTypes.ui32,
                dataAttributes: 0xD4
            )
        )
        static let CH0C = SMCComm.KeyInfo(
            key: SMCComm.Key("C", "H", "0", "C"),
            info: SMCComm.KeyInfoData(
                dataSize: 1,
                dataType: SMCComm.KeyTypes.hex,
                dataAttributes: 0xD4
            )
        )
        static let CHIE = SMCComm.KeyInfo(
            key: SMCComm.Key("C", "H", "I", "E"),
            info: SMCComm.KeyInfoData(
                dataSize: 1,
                dataType: SMCComm.KeyTypes.hex,
                dataAttributes: 0xD4
            )
        )
        static let CH0J = SMCComm.KeyInfo(
            key: SMCComm.Key("C", "H", "0", "J"),
            info: SMCComm.KeyInfoData(
                dataSize: 1,
                dataType: SMCComm.KeyTypes.ui8,
                dataAttributes: 0xD4
            )
        )
    }
    
    private struct KeyControl {
        let keyInfo: SMCComm.KeyInfo
        let onBytes: [UInt8]
        let offBytes: [UInt8]

        static let CHTE = KeyControl(
            keyInfo: Keys.CHTE,
            onBytes: [0x00, 0x00, 0x00, 0x00],
            offBytes: [0x01, 0x00, 0x00, 0x00]
        )
        static let CH0C = KeyControl(
            keyInfo: Keys.CH0C,
            onBytes: [0x00],
            offBytes: [0x01]
        )
        static let CHIE = KeyControl(
            keyInfo: Keys.CHIE,
            onBytes: [0x00],
            offBytes: [0x08]
        )
        static let CH0J = KeyControl(
            keyInfo: Keys.CH0J,
            onBytes: [0x00],
            offBytes: [0x20]
        )
    }
}
