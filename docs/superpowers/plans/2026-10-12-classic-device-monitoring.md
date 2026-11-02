# Classic Device Monitoring Implementation Plan

> **Status: Task 3 (Classic poller) withdrawn after implementation** — macOS reports only a cached constant
> RSSI for Classic links; see the spec's Status note. Tasks 1–2 (`DeviceID`, re-keying) remain.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let connected Bluetooth Classic devices (e.g. UGREEN HiTune S3) be listed and monitored for lock/unlock like BLE devices.

**Architecture:** A new `DeviceID` enum (`.le(UUID)` / `.classic(MAC)`) replaces raw `UUID` device keys everywhere. A 2 s IOBluetooth poller reads `rawRSSI()` of connected Classic devices and feeds the existing `updateMonitored` pipeline and the Device menu.

**Tech Stack:** Swift, AppKit, CoreBluetooth, IOBluetooth, Xcode project `BLEUnlock.xcodeproj`.

**Spec:** `docs/superpowers/specs/2026-10-12-classic-device-monitoring-design.md`

## Global Constraints

- Persisted prefs stay readable without migration: BLE IDs are stored as plain `uuidString` (`devices`, `deviceNames`, `deviceModels`, `infoTriedDevices`); Classic IDs as `classic:<MAC>`.
- MAC normalized form: `04:CC:36:40:74:23` (colon-separated, uppercase).
- BLEUnlock never opens a Classic connection; Classic RSSI is read only while `IOBluetoothDevice.isConnected()`.
- Classic poll interval 2 s; HCI RSSI `127` = unavailable (skip).
- Every edited block gets one purpose comment prefixed `// Classic monitoring:` (repo convention: `// <Feature>: ...`).
- No commits in this plan; the user commits on request.
- Heavy commands (`scripts/build.sh`) run through `~/.claude/hooks/typecheck-queue.sh '<cmd>'` in the background.

## Review Focus

- Legacy prefs (plain UUID strings, legacy single `device` key) must load as `.le` IDs — monitored devices stay selected after update (Task 1 check + Task 2 manual step).
- A Classic device disconnecting while monitored must go `lost` via the signal timer, never crash or stall (Task 3 manual step).
- A Classic row must leave the open Device menu as "not detected" when the device disconnects, like a BLE row (Task 3 manual step).
- Dual-mode devices (AirPods: BLE advertising + Classic connection) may yield two rows with one name; the existing same-name dedupe in `placeRow` must hide the unmonitored duplicate (Task 3 manual step).
- `rawRSSI()` returning 127 or a positive value must not produce bogus presence (Task 3 code: skip 127, clamp > 0 to 0).

---

### Task 1: `DeviceID` type

**Files:**
- Modify: `BLEUnlock/DeviceLogic.swift` (append)
- Test: `checks/DeviceLogicCheck.swift`

**Interfaces:**
- Produces:
  - `enum DeviceID: Hashable { case le(UUID); case classic(String) }`
  - `static func DeviceID.classicID(mac: String) -> DeviceID?`
  - `var DeviceID.prefString: String`
  - `init?(prefString: String)`
  - `var DeviceID.leUUID: UUID?` (nil for `.classic`)
  - `var DeviceID.classicMAC: String?` (nil for `.le`)

- [ ] **Step 1: Write the failing checks** — in `checks/DeviceLogicCheck.swift`, before `print("DeviceLogic checks passed")`:

```swift
        // Classic monitoring: DeviceID pref round trip, legacy UUID strings, MAC normalization
        let leUUID = UUID(uuidString: "63B61A13-02BF-0CB1-D5FE-1D440735C645")!
        check(DeviceID(prefString: "63B61A13-02BF-0CB1-D5FE-1D440735C645") == .le(leUUID), "legacy UUID string → le")
        check(DeviceID.le(leUUID).prefString == "63B61A13-02BF-0CB1-D5FE-1D440735C645", "le prefString is plain UUID")
        check(DeviceID.classicID(mac: "04-cc-36-40-74-23") == .classic("04:CC:36:40:74:23"), "MAC normalized")
        check(DeviceID.classic("04:CC:36:40:74:23").prefString == "classic:04:CC:36:40:74:23", "classic prefString")
        check(DeviceID(prefString: "classic:04:CC:36:40:74:23") == .classic("04:CC:36:40:74:23"), "classic round trip")
        check(DeviceID(prefString: "classic:nope") == nil, "bad classic MAC → nil")
        check(DeviceID(prefString: "garbage") == nil, "garbage → nil")
        check(DeviceID.classicID(mac: "04:CC:36:40:74") == nil, "short MAC → nil")
        check(DeviceID.le(leUUID).leUUID == leUUID && DeviceID.le(leUUID).classicMAC == nil, "le accessors")
        check(DeviceID.classic("04:CC:36:40:74:23").classicMAC == "04:CC:36:40:74:23", "classic accessor")
```

- [ ] **Step 2: Run, expect compile failure**

Run: `cd ~/github/BLEUnlock && swiftc BLEUnlock/DeviceLogic.swift checks/DeviceLogicCheck.swift -o build/devicelogic-check && build/devicelogic-check`
Expected: error `cannot find 'DeviceID' in scope`.

- [ ] **Step 3: Implement** — append to `BLEUnlock/DeviceLogic.swift`:

```swift
// Classic monitoring: identity of a listed/monitored device; BLE by CoreBluetooth UUID, Classic by MAC
enum DeviceID: Hashable {
    case le(UUID)
    case classic(String)

    private static let CLASSIC_PREFIX = "classic:"

    // Classic monitoring: normalized ("04:CC:36:40:74:23"); nil unless six hex octets
    static func classicID(mac: String) -> DeviceID? {
        let normalized = mac.replacingOccurrences(of: "-", with: ":").uppercased()
        guard normalized.range(of: "^([0-9A-F]{2}:){5}[0-9A-F]{2}$", options: .regularExpression) != nil else {
            return nil
        }
        return .classic(normalized)
    }

    // Classic monitoring: BLE keeps the plain UUID string already stored in prefs (no migration)
    var prefString: String {
        switch self {
        case .le(let uuid): return uuid.uuidString
        case .classic(let mac): return DeviceID.CLASSIC_PREFIX + mac
        }
    }

    init?(prefString: String) {
        if prefString.hasPrefix(DeviceID.CLASSIC_PREFIX) {
            guard let id = DeviceID.classicID(mac: String(prefString.dropFirst(DeviceID.CLASSIC_PREFIX.count))) else {
                return nil
            }
            self = id
        } else if let uuid = UUID(uuidString: prefString) {
            self = .le(uuid)
        } else {
            return nil
        }
    }

    var leUUID: UUID? {
        guard case .le(let uuid) = self else { return nil }
        return uuid
    }

    var classicMAC: String? {
        guard case .classic(let mac) = self else { return nil }
        return mac
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: same command as Step 2.
Expected: `DeviceLogic checks passed`.

---

### Task 2: Re-key app from `UUID` to `DeviceID` (no behaviour change)

**Files:**
- Modify: `BLEUnlock/BLE.swift` (Device, MonitoredDeviceState, BLE)
- Modify: `BLEUnlock/AppDelegate.swift`

**Interfaces:**
- Consumes: `DeviceID` (Task 1).
- Produces:
  - `Device.id: DeviceID`, `Device.init(id: DeviceID)` (replaces `uuid` / `init(uuid:)`)
  - `MonitoredDeviceState.id: DeviceID`, `init(id: DeviceID)`
  - `BLE.devices: [DeviceID: Device]`, `BLE.monitoredStates: [DeviceID: MonitoredDeviceState]`
  - `BLE.monitoredIDs: Set<DeviceID>` (replaces `monitoredUUIDs`), `BLE.startMonitor(ids: Set<DeviceID>)`
  - `extension CBPeripheral { var deviceID: DeviceID }` (= `.le(identifier)`)
  - `AppDelegate.monitorDevices(_ ids: Set<DeviceID>)`, `loadMonitoredDevices() -> Set<DeviceID>`

- [ ] **Step 1: `BLE.swift` — `Device`**

Replace `let uuid : UUID!` with `let id: DeviceID` and `init(uuid _uuid: UUID) { uuid = _uuid }` with:

```swift
    init(id: DeviceID) {
        self.id = id
    }
```

In `description`, wrap the two UUID-based lookups so they run only for BLE, and replace the final fallback:

```swift
            // Classic monitoring: CoreBluetooth caches are keyed by UUID; Classic devices carry their MAC already
            if let uuid = id.leUUID {
                if macAddr == nil || blName == nil {
                    if let info = getLEDeviceInfoFromUUID(uuid.uuidString) {
                        blName = info.name
                        macAddr = info.macAddr
                    }
                }
                if macAddr == nil {
                    macAddr = getMACFromUUID(uuid.uuidString)
                }
            }
```
and `return uuid.description` → `return id.prefString`.

- [ ] **Step 2: `BLE.swift` — `MonitoredDeviceState`**: `let uuid: UUID` → `let id: DeviceID`; `init(uuid: UUID) { self.uuid = uuid }` → `init(id: DeviceID) { self.id = id }`.

- [ ] **Step 3: `BLE.swift` — peripheral key helper** (top level, after `getNameFromMAC`):

```swift
// Classic monitoring: device key of a CoreBluetooth peripheral
extension CBPeripheral {
    var deviceID: DeviceID {
        return .le(identifier)
    }
}
```

- [ ] **Step 4: `BLE.swift` — `BLE` class re-key** (exact replacements):
  - `var devices : [UUID : Device]` → `var devices: [DeviceID: Device]`
  - `var monitoredStates: [UUID: MonitoredDeviceState]` → `[DeviceID: MonitoredDeviceState]`
  - `var monitoredUUIDs: Set<UUID>` → `var monitoredIDs: Set<DeviceID>`
  - `func startMonitor(uuids: Set<UUID>)` → `func startMonitor(ids: Set<DeviceID>)`; inside: `uuids` → `ids`, loop vars `uuid` → `id`, `MonitoredDeviceState(uuid: uuid)` → `MonitoredDeviceState(id: id)`
  - `monitoredState(for:)`: `monitoredStates[peripheral.identifier]` → `monitoredStates[peripheral.deviceID]`
  - `resetScanTimer`: `device.uuid` → `device.id` (2 places)
  - `shouldConnectForInfo`: `[device.uuid.uuidString]` → `[device.id.prefString]`
  - `didDiscover`: `devices[peripheral.identifier]` → `devices[peripheral.deviceID]` (2 places); `Device(uuid: peripheral.identifier)` → `Device(id: peripheral.deviceID)`
  - `finishInfoReadIfDone`, `didConnect`, `didDiscoverServices`, `didDiscoverCharacteristicsFor`, `didUpdateValueFor`: every `devices[peripheral.identifier]` / `monitoredStates[peripheral.identifier]` → `[peripheral.deviceID]` (after the edit `grep -n 'peripheral.identifier\]' BLEUnlock/BLE.swift` → no output)
  - Leave `CBUUID`/`service.uuid`/`characteristic.uuid` untouched (GATT, not device keys).

- [ ] **Step 5: `AppDelegate.swift` re-key** (exact replacements):
  - `var deviceDict: [UUID: NSMenuItem]` → `[DeviceID: NSMenuItem]`; `var deviceInsertRSSI: [UUID: Int]` → `[DeviceID: Int]`
  - `ble.monitoredUUIDs` → `ble.monitoredIDs` (all occurrences)
  - `validateMenuItem`: `let uuid = menuItem.representedObject as? UUID` → `let id = menuItem.representedObject as? DeviceID`; body uses `id`
  - `placeRow(..., monitored: Set<UUID>)` → `Set<DeviceID>`; `device.uuid` → `device.id`
  - `rebuildDeviceMenu`: `departedUUIDs` → `departedIDs`; closure var `uuid` → `id`; every `device.uuid` → `device.id`; tie-break `$0.device.uuid.uuidString < $1.device.uuid.uuidString` → `$0.device.id.prefString < $1.device.id.prefString`; `scannedUUIDs` → `scannedIDs`; `.sorted { $0.uuidString < $1.uuidString }` → `.sorted { $0.prefString < $1.prefString }`; `missingDeviceItem(uuid: $0, name: deviceNames[$0.uuidString], model: deviceModels[$0.uuidString])` → `missingDeviceItem(id: $0, name: deviceNames[$0.prefString], model: deviceModels[$0.prefString])`
  - `saveMonitoredValues(_ seenValues: [(UUID, String)], ...)` → `[(DeviceID, String)]`; `ble.monitoredUUIDs.map { $0.uuidString }` → `ble.monitoredIDs.map { $0.prefString }`; `values[uuid.uuidString]` → `values[id.prefString]`
  - `missingDeviceItem(uuid: UUID, ...)` → `missingDeviceItem(id: DeviceID, ...)`; `let label = name ?? uuid.uuidString` → `name ?? id.prefString`; `item.representedObject = uuid` → `= id`
  - `newDevice`: `models[device.uuid.uuidString]` → `models[device.id.prefString]`; `$0.representedObject as? UUID == device.uuid` → `$0.representedObject as? DeviceID == device.id`; other `device.uuid` → `device.id`
  - `updateDevice`, `removeDevice`: `device.uuid` → `device.id`
  - `selectDevice`: `guard let uuid = item.representedObject as? UUID` → `guard let id = item.representedObject as? DeviceID`; `symmetricDifference([uuid])` → `([id])`
  - `monitorDevices(_ uuids: Set<UUID>)` → `monitorDevices(_ ids: Set<DeviceID>)`; `ble.startMonitor(uuids: uuids)` → `ble.startMonitor(ids: ids)`; `uuids.isEmpty` → `ids.isEmpty`
  - `loadMonitoredDevices`:

```swift
    // Multi-device: persisted as "devices"; the legacy single "device" pref is migrated once
    // Classic monitoring: entries parse as DeviceID (plain UUID string = BLE, "classic:<MAC>" = Classic)
    func loadMonitoredDevices() -> Set<DeviceID> {
        if let idStrings = prefs.stringArray(forKey: "devices") {
            return Set(idStrings.compactMap { DeviceID(prefString: $0) })
        }
        guard let legacy = prefs.string(forKey: "device"), let uuid = UUID(uuidString: legacy) else { return [] }
        prefs.set([uuid.uuidString], forKey: "devices")
        prefs.removeObject(forKey: "device")
        return [.le(uuid)]
    }

    func saveMonitoredDevices() {
        prefs.set(ble.monitoredIDs.map { $0.prefString }.sorted(), forKey: "devices")
    }
```

- [ ] **Step 6: Confirm nothing left** — `grep -n 'monitoredUUIDs\|device\.uuid\|state\.uuid\|as? UUID\|Device(uuid\|startMonitor(uuids' BLEUnlock/*.swift` → no output.

- [ ] **Step 7: Build**

Run: `cd ~/github/BLEUnlock && ~/.claude/hooks/typecheck-queue.sh 'scripts/build.sh'` (background).
Expected: `DeviceLogic checks passed`, build succeeds, app relaunches.

- [ ] **Step 8: Manual** — open the Device menu: previously monitored iPhone/AirPods still checked in Monitoring; `defaults read jp.sone.BLEUnlock devices` still lists plain UUID strings.

---

### Task 3: Classic poller

**Files:**
- Modify: `BLEUnlock/BLE.swift` (BLE class)

**Interfaces:**
- Consumes: `DeviceID.classicID(mac:)`, `DeviceID.classicMAC`, `Device(id:)`, `monitoredStates`, `devices`, `updateMonitored(state:rssi:)`, `resetScanTimer(device:)`, `delegate.newDevice/updateDevice`.
- Produces: `BLE.updateClassicPolling()`, `BLE.pollClassicDevices()`.

- [ ] **Step 1: Constants and timer** — next to `LOST_REASON`:

```swift
    // Classic monitoring: RSSI poll interval of connected Classic devices; HCI value for "RSSI unavailable"
    let CLASSIC_POLL_INTERVAL = 2.0
    let CLASSIC_RSSI_UNAVAILABLE = 127
    var classicPollTimer: Timer?
```

- [ ] **Step 2: Poller** — after `refreshPairedDevicesIfStale()`:

```swift
    // Classic monitoring: poll while the Device menu lists devices or a Classic device is monitored
    func updateClassicPolling() {
        let isNeeded = scanMode || monitoredIDs.contains { $0.classicMAC != nil }
        if isNeeded && classicPollTimer == nil {
            classicPollTimer = commonModeTimer(CLASSIC_POLL_INTERVAL, repeats: true) { _ in self.pollClassicDevices() }
            pollClassicDevices()
        } else if !isNeeded {
            classicPollTimer?.invalidate()
            classicPollTimer = nil
        }
    }

    // Classic monitoring: connected Classic devices feed the BLE pipeline (monitoring) and the Device menu
    // (scan mode); BLEUnlock never connects them itself, a disconnected device just stops reporting
    func pollClassicDevices() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        for bluetoothDevice in paired where bluetoothDevice.isConnected() {
            guard let address = bluetoothDevice.addressString, let id = DeviceID.classicID(mac: address) else { continue }
            let rawRSSI = Int(bluetoothDevice.rawRSSI())
            guard rawRSSI != CLASSIC_RSSI_UNAVAILABLE else { continue }
            let rssi = min(rawRSSI, 0)
            if let state = monitoredStates[id] {
                updateMonitored(state: state, rssi: rssi)
            }
            if scanMode {
                listClassicDevice(id: id, name: bluetoothDevice.name, rssi: rssi)
            }
        }
    }

    // Classic monitoring: same row lifecycle as a BLE scan result (no RSSI threshold: connected = relevant)
    func listClassicDevice(id: DeviceID, name: String?, rssi: Int) {
        if let device = devices[id] {
            device.rssi = rssi
            delegate?.updateDevice(device: device)
            resetScanTimer(device: device)
            return
        }
        let device = Device(id: id)
        device.macAddr = id.classicMAC
        device.blName = name
        device.rssi = rssi
        devices[id] = device
        delegate?.newDevice(device: device)
        resetScanTimer(device: device)
    }
```

- [ ] **Step 3: Hook it up** — call `updateClassicPolling()` as the last line of `startScanning()`, `stopScanning()`, and of `startMonitor(ids:)` (also before its early `return` in the empty-set guard, so the timer stops when nothing is monitored).

- [ ] **Step 4: Build** — same as Task 2 Step 7. Expected: pass.

- [ ] **Step 5: Manual (user)**
  1. UGREEN connected → open Device menu → row "UGREEN HiTune S3 (04:CC:36:40:74:23) (-NNdBm)" in Monitoring within ~2 s. If RSSI looks wrong (e.g. always 0 or 127), report — spec Risk: try `RSSI()`.
  2. Select it → status shows RSSI; `defaults read jp.sone.BLEUnlock devices` contains `classic:04:CC:36:40:74:23`.
  3. Turn headset off with the menu open → row turns "not detected" after the No-Signal Timeout.
  4. iPhone + UGREEN monitored, Lock When = Any, headset off → no lock after timeout.
  5. Only UGREEN monitored, headset off → locks after timeout.
  6. AirPods (dual-mode) connected → not listed twice unless one row is monitored.
