#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir="${1:-build/power-tests}"
mkdir -p "$test_build_dir"
xcrun swiftc -swift-version 6 -module-cache-path "$test_build_dir/module-cache" \
    Tests/PowerControlDoubles.swift Tests/PowerControlTests.swift \
    Libraries/SMCComm+Power.swift Libraries/SMCComm+MagSafe.swift \
    Common/BTError.swift Common/BTStateInfo.swift \
    com.delfuria.batterytoolkitd/BTPowerState.swift \
    com.delfuria.batterytoolkitd/BTPowerEvents.swift \
    -o "$test_build_dir/power-tests"
"$test_build_dir/power-tests"
