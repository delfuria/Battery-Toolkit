# macOS 15.8 charging compatibility

Battery Toolkit previously required either `CHTE` or `CH0C` for charging
control. On the tested MacBook Pro M4 Max running macOS 15.8 (24H23), firmware
`mBoot-20457.1.29` returns SMC error `0x84` for both keys. The installed 1.8
daemon consequently logged `Machine is unsupported`.

This fork falls back to these controls when neither legacy key is available:

| Key | Format | Purpose |
| --- | --- | --- |
| `bfF0` | one byte | `00` deactivates the range; `02` activates it |
| `bfD0` | four bytes, little-endian | Upper charge percentage |
| `bfE0` | four bytes, little-endian | Lower charge percentage |

All three keys must have the expected metadata. Updates deactivate the
range, set the upper and lower percentages, and reactivate it. Every write
is read back, and a failed update attempts to restore the previous range.
Unchanged ranges do not cause writes. A failed restore also attempts to
clear activation rather than leaving a partially programmed range active.

The daemon installs the range while on battery as well as on external power,
checks it every 30 seconds while awake, and repairs it after wake. It does
not wake the Mac to poll. Pausing background activity or normally stopping
the release daemon clears the range. The existing debug-build behavior of
leaving charging controls in place on exit is retained.

Manual charge-to-limit temporarily raises the lower bound to just below the
upper bound. Charge-to-full temporarily clears the range; once full, it
holds a 100% upper bound until charge naturally falls back into the normal
range. Manual stop installs a fixed upper target at the current percentage
(capped at the configured maximum). As with automatic limits, the firmware
may discharge toward that target rather than immediately hold the charge.
Equal lower/upper settings use a one-percentage-point band, since the firmware
requires the lower bound to be strictly below the upper bound.

## Adapter power and clamshell mode

For 30–80% operation, set the app's thresholds to 30 and 80 and keep the power
adapter enabled. The new charging path never writes the adapter-disable keys
(`CHIE`/`CH0J`). Existing explicit adapter commands still work separately.

However, the firmware can itself discharge a battery that starts above the
upper limit. In the hardware test below, macOS continued reporting external
power connected and charge-capable while the battery current became negative.
This differs from the old charging-inhibit switch. Do not equate an active
range, or an adapter-connected flag, with zero battery current.

Holding an arbitrary above-limit percentage without discharging is not
established. A second test at a displayed 97% with a 30–96% range continued
charging throughout the 30-second observation. Programming a range does not
guarantee an immediate state transition, nor exact agreement between the
displayed percentage and the firmware's thresholds.

Some newer macOS versions restrict access to these keys even as root. The
[batt compatibility report](https://github.com/charlie0129/batt/issues/152)
describes those restrictions. They were **not** observed on the tested macOS
15.8 installation; avoid assuming support solely from a firmware version.

## Validation

On the M4 Max / macOS 15.8 machine:

- Both old charging keys were missing; all three new keys were readable and
  writable with administrator privileges.
- The complete daemon compiled and linked using Swift 6 and the Command Line
  Tools. The GUI app has not been built or installed.
- The production firmware backend accepted and read back a 30–80% range.
  During the 30-second test at 96%, `IsCharging` changed from true to false,
  current changed from +2561 mA to -2180 mA, and `ExternalConnected` and
  `ExternalChargeCapable` remained true.
- Both hardware tests restored the original three firmware keys and the
  previous system sleep setting. No helper was installed by the tests.

Still requiring hardware validation: stopping near 80%, restarting below
30%, sustained adapter-only operation within the band, unplug/replug,
closed-lid sleep/wake, and reboot. Automated tests exercise control decisions
and failures; they do not simulate the firmware's electrical behavior.

Run the regression checks without root or hardware writes:

```sh
bash Tests/run.sh
```

The tests compile the production power backend, state tracker and event loop
with substitutes for hardware, preferences, notifications and sleep changes.
They cover capability detection, legacy hysteresis, write order and encoding,
rollback, read failures, idempotence, wake recovery, manual commands, adapter
isolation and sleep accounting.

Build the diagnostic tool using only the Command Line Tools:

```sh
bash Tools/build-power-probe.sh
build/power-probe/power-control-probe
```

The default invocation only reads controls and battery status. To run the
explicit 30-second hardware test:

```sh
sudo build/power-probe/power-control-probe --test-limit 30 80
```

This temporarily applies the range and disables system sleep to protect an
ongoing clamshell session. It restores the original controls and sleep setting
when finished or interrupted with SIGINT/SIGTERM. Do not force-kill the test:
SIGKILL or a machine crash prevents cleanup. Charging status can take time to
refresh after settings are restored. This tool is a diagnostic, not a
replacement for the installed app or a persistent background service.

## Building the app

The GUI requires full Xcode with a Swift 6 toolchain; Command Line Tools alone
do not include the storyboard and asset compilers. This project's privileged
helper also authenticates the app using an Apple Development certificate.
Ad-hoc signing is not sufficient for the existing XPC security checks.

1. Open `Battery Toolkit.xcodeproj` in Xcode.
2. Configure your own development team and Apple Development signing identity
   for all targets. Set the project build setting `BT_CODESIGN_CN` to the exact
   Common Name of that certificate. The repository defaults name the upstream
   developer, whose certificate you cannot use to sign your own build.
3. Build the **Battery Toolkit** scheme in **Release** configuration. Debug
   builds deliberately leave charging controls in place when the helper exits.
4. Disable background activity in the old app before replacing it with the new
   build, especially when changing the signing identity. Launch the new app,
   enable its background activity, and approve it in macOS settings if prompted.
5. Set the thresholds to 30% and 80%, keep the adapter enabled, and disable
   macOS Optimized Battery Charging to avoid competing policies.

Do not replace only the helper inside the upstream signed app: changing its
contents invalidates the bundle signature, and mismatched signing identities
prevent the GUI and helper from authenticating each other.
