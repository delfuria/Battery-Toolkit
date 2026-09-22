#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_build_dir="${1:-build/power-probe}"
mkdir -p "$probe_build_dir"
xcrun clang -c Modules/MachTaskSelf/MachTaskSelf.c -o "$probe_build_dir/MachTaskSelf.o"
xcrun swiftc -swift-version 6 -I Modules \
    -module-cache-path "$probe_build_dir/module-cache" \
    Libraries/SMCComm.swift Libraries/SMCComm+Power.swift Libraries/IOPSPrivate.swift \
    Tools/PowerControlProbe.swift "$probe_build_dir/MachTaskSelf.o" \
    -framework IOKit -o "$probe_build_dir/power-control-probe"
printf 'Built %s/power-control-probe\n' "$probe_build_dir"
