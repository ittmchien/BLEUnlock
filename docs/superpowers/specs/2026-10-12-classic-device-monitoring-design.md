# Classic Bluetooth Device Monitoring — Design

Date: 2026-10-12

> **Status: withdrawn (2026-10-12).** The Classic poller was built, then removed. macOS gives no live RSSI
> for a Classic link: `IOBluetoothDevice.rawRSSI()` (and `system_profiler`) stayed at a constant -50 while the
> UGREEN headset was carried away from the Mac (121 and 153 one-second samples), the headset never
> disconnected within walking range, and the HCI `readRSSIForDevice:` command is not available
> (`responds(to:)` is false). A Classic device therefore cannot tell "moved away" and would always look near,
> which could unlock the Mac with Unlock When = Any. Kept: the `DeviceID` type and re-keying; stored
> `classic:<MAC>` entries are skipped on load.

## Goal

Let the user pick a connected Bluetooth Classic device (e.g. UGREEN HiTune S3 headset, HFP/A2DP only, no GATT)
in the Device menu and use it for lock/unlock exactly like a BLE device (iPhone, AirPods).

Today the Device menu lists only CoreBluetooth scan results, so Classic-only devices never appear and cannot
be monitored.

## Decisions

- Device identity becomes an explicit type `DeviceID` (approach B), replacing raw `UUID` keys everywhere.
- RSSI of a Classic device is read only while macOS has it connected (`IOBluetoothDevice.isConnected()`).
  BLEUnlock never opens a Classic connection itself.
- A Classic device that disconnects (turned off, back in its case) stops producing RSSI; its signal timer
  fires and it becomes `lost`. Existing Lock When rules apply unchanged (a lost device locks with Any only
  when no monitored device is present).
- A Classic device is listed in the Device menu only while connected.

## Identity

`BLEUnlock/DeviceLogic.swift` (pure, covered by `checks/DeviceLogicCheck.swift`):

```swift
enum DeviceID: Hashable {
    case le(UUID)          // CoreBluetooth peripheral.identifier
    case classic(String)   // normalized MAC "04:CC:36:40:74:23"
}
```

- `DeviceID.classic(mac:)` normalizes a MAC: `-` → `:`, uppercased; returns nil if not 6 hex octets.
- `prefString`: `.le` → plain `uuidString` (the format already stored), `.classic` → `classic:<MAC>`.
- `init?(prefString:)` accepts both forms; anything else → nil.
- Persisted data stays readable without migration: `devices`, `deviceNames`, `deviceModels`,
  `infoTriedDevices` keep plain UUID strings for BLE devices.

## Re-keying

Every device key moves from `UUID` to `DeviceID`:

- `BLE`: `devices: [DeviceID: Device]`, `monitoredStates: [DeviceID: MonitoredDeviceState]`,
  `monitoredUUIDs` → `monitoredIDs: Set<DeviceID>`, `startMonitor(uuids:)` → `startMonitor(ids:)`.
- `Device.uuid` → `Device.id`; `MonitoredDeviceState.uuid` → `.id`.
- `AppDelegate`: `deviceDict`, `deviceInsertRSSI`, menu item `representedObject`, `selectDevice`,
  `monitorDevices`, `loadMonitoredDevices` / `saveMonitoredDevices`, `saveMonitoredValues`,
  `missingDeviceItem`, row sort tie-break (by `prefString`).
- CoreBluetooth paths look up with `.le(peripheral.identifier)`.
- UUID-only helpers (`getLEDeviceInfoFromUUID`, `getMACFromUUID`) run only for `.le`.

## Classic poller

`BLE.swift`, one repeating common-mode timer, interval 2 s (`CLASSIC_POLL_INTERVAL`).
Runs while `scanMode` is on or any monitored ID is `.classic`; stopped otherwise.

Each tick, for every `IOBluetoothDevice.pairedDevices()` entry with `isConnected()`:

1. `id = .classic(mac)` from `addressString`; skip if the MAC doesn't normalize.
2. `rssi = rawRSSI()`; skip when 127 (HCI "RSSI unavailable"); clamp > 0 to 0 like BLE.
3. Monitored → `updateMonitored(state:rssi:)` (same pipeline as BLE: proximity timer, signal timer,
   Any/All aggregate, lost/away rules).
4. `scanMode` → create or update a `Device` (`macAddr`, `blName` = device name, `rssi`) in `devices`,
   then `delegate.newDevice` / `updateDevice` and `resetScanTimer`, like a BLE scan row.
   Placement uses the existing connected-device rule, so the row lands in the Monitoring section.

## Untouched

CoreBluetooth-only behaviour (active mode, `connectMonitored`, GATT info read, passive mode) skips Classic
devices: they have no `peripheral`. `isSoleDeviceActive` stays false for a Classic device (scanning keeps
running for other monitored BLE devices; harmless when none).

## Risks

- `rawRSSI()` is assumed to return dBm like `system_profiler` (observed -50 for the headset). Unverified;
  if values look wrong in manual testing, try `RSSI()`.
- Classic RSSI near the Mac may vary less than BLE; lock/unlock thresholds may need user tuning.

## Testing

- `checks/DeviceLogicCheck.swift`: `prefString` round trip for both cases, legacy plain UUID string parses
  to `.le`, MAC normalization, garbage → nil.
- `scripts/build.sh` passes (logic self-check + xcodebuild).
- Manual:
  1. Previously selected BLE devices are still selected after the update.
  2. With UGREEN connected, open Device menu → it shows in Monitoring with RSSI; select it.
  3. Status shows its RSSI; turn the headset off → after the No-Signal Timeout it is `lost`; with the
     iPhone near and Lock When = Any → no lock.
  4. Monitor only UGREEN, turn it off → locks after the timeout.
