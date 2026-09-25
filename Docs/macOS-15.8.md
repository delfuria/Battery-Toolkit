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
(including above the configured maximum). As with automatic limits, the
firmware may need time to settle around that target.
Equal lower/upper settings use a one-percentage-point band, since the firmware
requires the lower bound to be strictly below the upper bound.

## Automatic sustain above the configured limit

To approximate the legacy app's behavior, the daemon captures the current
percentage as a temporary ceiling when starting, waking, reconnecting power,
or changing settings above the configured maximum. For a configured 30–80%
range, starting at 87% therefore installs a 30–87% range instead of immediately
asking the firmware to discharge toward 80%.

The configured maximum remains 80%. Ordinary percentage notifications cannot
raise the captured ceiling if charging briefly overshoots. While disconnected
from power, the temporary ceiling follows natural battery use downward. When
charge falls to 80% or below, the normal 30–80% range resumes. This is not a
request to top up to 87% whenever charge falls by one percent.

An installed sustain ceiling survives a daemon restart, and the menu reports
“Sustaining near 87 %” when charging is on hold with that verified target.
Manual full charging releases the ceiling; stopping it captures the current
level again. Requesting charge-to-limit when already above the limit sustains
the current level rather than initiating discharge.

Sustain is a firmware target, not a guarantee of an electrically inactive
battery or an exactly constant displayed percentage. A small charge/discharge
adjustment while the firmware settles is possible. The software policy is
covered by regression checks; an 87% hardware hold remains to be verified.

## No new charging session above the minimum

The firmware does not reproduce the legacy switch's hysteresis: whenever a
range is (re)installed, e.g. on daemon start or after a reboot, it charges
towards the upper bound even when the battery is already above the lower one.
With a 20–83% range, a Mac connected at 42% therefore charged to 83%, while the
legacy app would only have resumed charging below 20%.

The capture described above therefore applies to every level at or above the
configured minimum, not only above the maximum. Starting, waking, reconnecting
power or changing settings at 42% installs a 20–42% range. Once charge falls
below the minimum, the normal 20–83% range is installed and the resumed charge
continues to 83%, also across wake and settings changes, as with the legacy
switch. Reconnecting power ends a resumed charge, again as before. The menu
shows “Sustaining near …” only for holds above the configured maximum.

## No limit while shut down

The firmware range does not survive a full power-off. Version 2.0.2 offered an
option to leave `bfF0`/`bfD0`/`bfE0` installed when the daemon exits on
shutdown. In a hardware test with the option enabled and a 20–83% range, a Mac
shut down at 35% with the adapter connected was at 94% after one hour, above
the programmed upper bound. The SMC therefore resets the range while the Mac is
off, and the option was removed in 2.0.3. The daemon again clears the range on
exit, so a Mac that is shut down with the adapter connected charges to 100%.
Sleep keeps the range enforced; use sleep, or disconnect the adapter, instead
of shutting down.

## Adapter power and clamshell mode

For 30–80% operation, set the app's thresholds to 30 and 80 and keep the power
adapter enabled. The new charging path never writes the adapter-disable keys
(`CHIE`/`CH0J`). Existing explicit adapter commands still work separately.

However, the firmware can itself discharge a battery that starts above the
programmed upper limit. In the hardware test below, which explicitly installed
80% at a displayed 96%, macOS continued reporting external power connected and
charge-capable while battery current became negative. Automatic sustain now
avoids that deliberate 96-to-80% request by capturing the current level instead.
Do not equate an active range, or an adapter-connected flag, with zero battery
current.

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
  Tools. After installing Xcode 26.3, the complete Release GUI app also built
  successfully with signing disabled. It has not been signed or installed.
- The production firmware backend accepted and read back a 30–80% range.
  During the 30-second test at 96%, `IsCharging` changed from true to false,
  current changed from +2561 mA to -2180 mA, and `ExternalConnected` and
  `ExternalChargeCapable` remained true.
- Both hardware tests restored the original three firmware keys and the
  previous system sleep setting. No helper was installed by the tests.

Still requiring hardware validation: sustaining an above-limit level such as
87%, stopping near 80%, restarting below 30%, sustained adapter-only operation
within the band, unplug/replug,
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
isolation and sleep accounting. Sustain cases additionally cover an 87% start,
overshoot, natural discharge, replug notification ordering, changing limits,
restart recovery and failed writes.

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
Unlike the app's automatic policy, `--test-limit` applies exactly the supplied
range; it does not substitute a sustain ceiling when charge is above the limit.

## Building the app

The GUI requires full Xcode with a Swift 6 toolchain; Command Line Tools alone
do not include the storyboard and asset compilers. This project's privileged
helper also authenticates the app using an Apple Development certificate.
Ad-hoc signing is not sufficient for the existing XPC security checks.

If Xcode is installed but `xcode-select -p` still reports Command Line Tools,
select it for a particular build using `DEVELOPER_DIR`. For example, the
following verifies compilation with the installed Xcode 26.3 without changing
the global developer directory or requiring a signing identity:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild -project 'Battery Toolkit.xcodeproj' -scheme 'Battery Toolkit' \
  -configuration Release -derivedDataPath build/sustain-derivedData \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

That produces an unsigned build for validation.

### Signing

The app and its privileged helper authenticate each other with a code
requirement built from two project build settings:

| Setting | Debug | Release |
| --- | --- | --- |
| `BT_CODESIGN_CN` | `Apple Development: …` | `Developer ID Application: …` |
| `BT_CODESIGN_CA_OID` | `1.2.840.113635.100.6.2.1` (Apple Development intermediate) | `1.2.840.113635.100.6.2.6` (Developer ID intermediate) |

Both must match the certificate that actually signs the build. Release is
signed manually with the Developer ID Application identity, a secure
timestamp and without the injected `get-task-allow` entitlement, as required
for notarization. To build with a different identity, change the team, both
settings and the Release `CODE_SIGN_IDENTITY` accordingly.

### Installing a local build

1. Build the **Battery Toolkit** scheme in **Release** configuration. Debug
   builds deliberately leave charging controls in place when the helper exits.
2. Disable background activity in any previously installed build before
   replacing it, especially when changing the signing identity (Debug and
   Release use different certificates). Launch the new app, enable its
   background activity, and approve it in macOS settings if prompted.
3. Set the thresholds to 30% and 80%, keep the adapter enabled, and disable
   macOS Optimized Battery Charging to avoid competing policies.

### Publishing a release

Store notarization credentials once (run it in Terminal, as it prompts for an
app-specific password):

```sh
xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>
```

Then build, notarize, staple and package:

```sh
Tools/release.sh <profile>
```

The script writes `Battery-Toolkit-Next-<version>.zip`, the matching dSYM
archive and `SHA256SUMS.txt` to `build/dist/`.

Do not replace only the helper inside a signed app: changing its
contents invalidates the bundle signature, and mismatched signing identities
prevent the GUI and helper from authenticating each other.
