//
// Copyright (C) 2022 - 2025 Marvin Häuser. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
//

import Foundation

internal enum BTSettingsInfo {
    enum Defaults {
        static let minCharge: UInt8 = 75
        static let maxCharge: UInt8 = 80
        static let adapterSleep = false
        static let magSafeSync = false
        static let keepLimitOnShutdown = false
    }

    enum Bounds {
        static let minChargeMin: UInt8 = 20
        static let maxChargeMin: UInt8 = 50
    }

    enum Keys {
        static let minCharge = "MinCharge"
        static let maxCharge = "MaxCharge"
        static let adapterSleep = "AdapterSleep"
        static let magSafeSync = "MagSafeSync"
        static let keepLimitOnShutdown = "KeepLimitOnShutdown"
    }

    static func chargeLimitsValid(
        minCharge: Int,
        maxCharge: Int
    ) -> Bool {
        return self.Bounds.minChargeMin <= minCharge &&
            minCharge <= maxCharge &&
            maxCharge <= 100 &&
            self.Bounds.maxChargeMin <= maxCharge
    }
}
