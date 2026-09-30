# Multi-device, Grouped Device List, Device Naming — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Monitor several BLE devices with Any/All lock/unlock logic, show a grouped/deduplicated device list, and display real device names with model suffix.

**Architecture:** Pure, Foundation-only decision logic (aggregation, categorisation, naming helpers) lives in a new `BLEUnlock/DeviceLogic.swift` and is checked by an assert-based runner compiled with `swiftc`. `BLE.swift` moves from one monitored peripheral to a dictionary of per-device state and reports one aggregate presence. `AppDelegate.swift` persists a device set, adds "Unlock When"/"Lock When" submenus and rebuilds the Device submenu into groups.

**Tech Stack:** Swift 5, AppKit, CoreBluetooth, Xcode 26.5, macOS deployment target 10.13.

**Spec:** `docs/superpowers/specs/2026-09-28-multi-device-design.md`

## Global Constraints

- Minimum macOS 10.13: no `NSMenuItem.sectionHeader`, no macOS 14-only APIs.
- No new dependencies. No `any`-style escapes: no force casts added, no `as!` added.
- Every new user-facing string goes through `t("<key>")` and exists in ALL 8 `.lproj/Localizable.strings` (Base, da, de, ja, nb, sv, tr, zh-Hans).
- Every changed/added code block gets one short purpose comment on top (`// Multi-device: ...`, `// Naming: ...`, `// Device list: ...`). English only.
- Keep the existing uncommitted fixes (#182, #137, #97, #82) working — `ble.presence` semantics for `tryUnlockScreen`/`onScreenLocked` must stay "devices say unlock is allowed".
- Defaults: lock logic = Any, unlock logic = All. Conflict (both lock and unlock true) → lock wins.
- Build is heavy: run ONLY via `~/.claude/hooks/typecheck-queue.sh '<cmd>'` in background. The logic check (`swiftc` of two small files) is light and may run directly.
- Do not commit; the user commits when they decide.

## Review Focus

1. Legacy prefs: user upgrading with only `device` (String) set → that device is monitored, `devices` written, `device` removed.
2. A monitored device that is never seen after launch → signal timer fires "lost" for it; with Lock Any the Mac locks, with Lock All it locks only when every device is lost/away.
3. Deselecting the last monitored device → no timers left running, no lock fires, status shows "Device not selected".
4. Unlock disabled (`UNLOCK_DISABLED`) + multi-device → never unlocks, lock still works.
5. Device menu open while devices arrive/leave → headers of empty groups hidden, no duplicate rows, "Scanning…" stays first.

Tests for 1–4 at the logic level live in Task 1 (aggregation) and are exercised manually in Task 6; 5 is manual in Task 6.

---

### Task 1: Pure decision logic + self-check

**Files:**
- Create: `BLEUnlock/DeviceLogic.swift`
- Create: `checks/DeviceLogicCheck.swift` (runner `main`, not part of the app target)
- Modify: `BLEUnlock.xcodeproj/project.pbxproj` (add `DeviceLogic.swift` to the BLEUnlock app target: PBXFileReference, PBXBuildFile, BLEUnlock group, Sources build phase — copy the pattern used for `appleDeviceNames.swift`)

**Interfaces — Produces:**
```swift
enum DeviceLogic: Int { case any = 0, all = 1 }
struct AggregateDecision: Equatable { let shouldUnlock: Bool; let shouldLock: Bool }
func aggregatePresence(_ presences: [Bool], unlockLogic: DeviceLogic, lockLogic: DeviceLogic) -> AggregateDecision
enum DeviceCategory: Int, CaseIterable { case iphone, watch, airpods, ipad, mac, other }
func deviceCategory(model: String?, name: String) -> DeviceCategory
func isGenericDeviceName(_ name: String) -> Bool
func deviceRowTitle(name: String, modelName: String?, rssi: Int) -> String
```

- [x] **Step 1: Write the failing check**

`checks/DeviceLogicCheck.swift`:
```swift
// Self-check for DeviceLogic.swift. Run:
// swiftc BLEUnlock/DeviceLogic.swift checks/DeviceLogicCheck.swift -o /tmp/devicelogic-check && /tmp/devicelogic-check
func check(_ condition: Bool, _ label: String) {
    if !condition { print("FAIL: \(label)"); exit(1) }
}

// aggregatePresence
check(aggregatePresence([], unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: false), "empty → nothing")
check(aggregatePresence([true], unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: true, shouldLock: false), "single present")
check(aggregatePresence([false], unlockLogic: .any, lockLogic: .all) == AggregateDecision(shouldUnlock: false, shouldLock: true), "single away")
check(aggregatePresence([true, false], unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: true), "AirPods left, phone stays, lock Any → lock")
check(aggregatePresence([true, false], unlockLogic: .all, lockLogic: .all) == AggregateDecision(shouldUnlock: false, shouldLock: false), "lock All, one away → hold")
check(aggregatePresence([false, false], unlockLogic: .all, lockLogic: .all) == AggregateDecision(shouldUnlock: false, shouldLock: true), "all away → lock")
check(aggregatePresence([true, true], unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: true, shouldLock: false), "all near → unlock")
check(aggregatePresence([true, false], unlockLogic: .any, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: true), "conflict → lock wins")
check(aggregatePresence([true, false], unlockLogic: .any, lockLogic: .all) == AggregateDecision(shouldUnlock: true, shouldLock: false), "unlock Any, lock All, one near")

// deviceCategory
check(deviceCategory(model: "iPhone15,2", name: "🍚🍳") == .iphone, "model iPhone")
check(deviceCategory(model: "Watch6,1", name: "x") == .watch, "model Watch")
check(deviceCategory(model: "iPad13,4", name: "x") == .ipad, "model iPad")
check(deviceCategory(model: "MacBookPro18,3", name: "x") == .mac, "model MacBook")
check(deviceCategory(model: "Mac14,2", name: "x") == .mac, "model Mac")
check(deviceCategory(model: "iMac21,1", name: "x") == .mac, "model iMac")
check(deviceCategory(model: nil, name: "AirPods của Trứng") == .airpods, "name AirPods")
check(deviceCategory(model: nil, name: "Beats Studio Buds") == .airpods, "name Beats")
check(deviceCategory(model: nil, name: "Trứng's MacBook Pro") == .mac, "name MacBook")
check(deviceCategory(model: nil, name: "Apple Watch của A") == .watch, "name Watch")
check(deviceCategory(model: nil, name: "M236 LaserJet") == .other, "printer → other")
check(deviceCategory(model: nil, name: "Machine") == .other, "Mac keyword needs word boundary")

// isGenericDeviceName
check(isGenericDeviceName("iPhone"), "iPhone generic")
check(isGenericDeviceName("Mac"), "Mac generic")
check(isGenericDeviceName("F0:2F:4B:00:95:90"), "MAC address generic")
check(isGenericDeviceName("63B61A13-02BF-0CB1-D5FE-1D440735C645"), "UUID generic")
check(!isGenericDeviceName("🍚🍳"), "custom name not generic")

// deviceRowTitle
check(deviceRowTitle(name: "🍚🍳", modelName: "iPhone 14 Pro", rssi: -45) == "🍚🍳 · iPhone 14 Pro (-45dBm)", "name + model")
check(deviceRowTitle(name: "iPhone 14 Pro", modelName: "iPhone 14 Pro", rssi: -45) == "iPhone 14 Pro (-45dBm)", "no duplicate model")
check(deviceRowTitle(name: "M236 LaserJet", modelName: nil, rssi: -68) == "M236 LaserJet (-68dBm)", "no model")
print("DeviceLogic checks passed")
```
Add `import Foundation` at top of the check file.

- [x] **Step 2: Run to verify it fails**

Run: `swiftc BLEUnlock/DeviceLogic.swift checks/DeviceLogicCheck.swift -o /tmp/devicelogic-check`
Expected: FAIL — `DeviceLogic.swift` missing / `cannot find 'aggregatePresence' in scope`.

- [x] **Step 3: Implement `BLEUnlock/DeviceLogic.swift`**

```swift
import Foundation

// Multi-device: how presences of several monitored devices combine into one lock/unlock decision
enum DeviceLogic: Int {
    case any = 0
    case all = 1
}

struct AggregateDecision: Equatable {
    let shouldUnlock: Bool
    let shouldLock: Bool
}

// Multi-device: lock wins on conflict so a device leaving always locks when configured to
func aggregatePresence(_ presences: [Bool], unlockLogic: DeviceLogic, lockLogic: DeviceLogic) -> AggregateDecision {
    guard !presences.isEmpty else { return AggregateDecision(shouldUnlock: false, shouldLock: false) }
    let shouldLock = lockLogic == .any ? presences.contains(false) : !presences.contains(true)
    let wantsUnlock = unlockLogic == .any ? presences.contains(true) : !presences.contains(false)
    return AggregateDecision(shouldUnlock: wantsUnlock && !shouldLock, shouldLock: shouldLock)
}

// Device list: group order in the Device submenu
enum DeviceCategory: Int, CaseIterable {
    case iphone, watch, airpods, ipad, mac, other
}

// Device list: model id prefix first, then whole-word name keywords
func deviceCategory(model: String?, name: String) -> DeviceCategory {
    if let model = model {
        if model.hasPrefix("iPhone") { return .iphone }
        if model.hasPrefix("Watch") { return .watch }
        if model.hasPrefix("AirPods") || model.hasPrefix("Audio") { return .airpods }
        if model.hasPrefix("iPad") { return .ipad }
        if model.hasPrefix("Mac") || model.hasPrefix("iMac") { return .mac }
    }
    let keywords: [(String, DeviceCategory)] = [
        ("iPhone", .iphone), ("Watch", .watch), ("AirPods", .airpods), ("Beats", .airpods),
        ("iPad", .ipad), ("MacBook", .mac), ("iMac", .mac), ("Mac", .mac),
    ]
    for (keyword, category) in keywords where containsWord(name, keyword) {
        return category
    }
    return .other
}

private func containsWord(_ text: String, _ word: String) -> Bool {
    let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

// Device list: names that can't identify one device (never deduplicated)
private let genericDeviceNames: Set<String> = ["iPhone", "iPad", "Mac", "Apple Watch", "AirPods"]

func isGenericDeviceName(_ name: String) -> Bool {
    if genericDeviceNames.contains(name) { return true }
    if UUID(uuidString: name) != nil { return true }
    return name.range(of: "^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$", options: .regularExpression) != nil
}

// Naming: "<name> · <model> (<rssi>dBm)", model omitted when unknown or equal to the name
func deviceRowTitle(name: String, modelName: String?, rssi: Int) -> String {
    guard let model = modelName, model != name else { return String(format: "%@ (%ddBm)", name, rssi) }
    return String(format: "%@ · %@ (%ddBm)", name, model, rssi)
}
```

- [x] **Step 4: Run check to verify it passes**

Run: `swiftc BLEUnlock/DeviceLogic.swift checks/DeviceLogicCheck.swift -o /tmp/devicelogic-check && /tmp/devicelogic-check`
Expected: `DeviceLogic checks passed`

- [x] **Step 5: Add `DeviceLogic.swift` to the Xcode app target** (pbxproj, pattern of `appleDeviceNames.swift`; generate new 24-hex ids not already in the file).

---

### Task 2: Device naming + model table

**Files:**
- Modify: `BLEUnlock/BLE.swift` (`Device` class L28-107, `didDiscover`)
- Modify: `BLEUnlock/appleDeviceNames.swift`

**Interfaces — Produces:** `Device.advertisedName: String?`, `Device.modelName: String?` (mapped name, else raw model id, nil when model unknown), `Device.description` keeps returning the display name.

- [x] **Step 1:** Add `var advertisedName: String?` to `Device`. In `didDiscover`, for every discovered/updated scan device: `if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty { device.advertisedName = name }`.
- [x] **Step 2:** Reorder `Device.description`: keep the existing LE-db / MAC / `blName` resolution block first (returns non-generic `blName`); then `advertisedName`; then `peripheral?.name` (non-empty) — each skipped when it is exactly "iPhone"/"iPad" and a model name exists; then `modelName`; then `manufacture/model` formatting as today; then iBeacon; then `blName`; then MAC; then UUID.
- [x] **Step 3:** Add computed `var modelName: String? { guard let model = model else { return nil }; return appleDeviceNames[model] ?? model }`.
- [x] **Step 4:** Extend `appleDeviceNames` with iPhone14,6 (SE 3rd gen), iPhone14,7/8 (14/14 Plus), iPhone15,2/3 (14 Pro/Pro Max), iPhone15,4/5 (15/15 Plus), iPhone16,1/2 (15 Pro/Pro Max), iPhone17,1/2/3/4/5 (16 Pro/Pro Max/16/16 Plus/16e), iPhone18,1/2/3/4 (17 Pro/17 Pro Max/17/Air); Watch6,x–Watch7,x; recent iPad and Mac ids only if you can verify them from Apple/public identifier lists — skip any id you cannot verify rather than guess.
- [x] **Step 5:** Run the Task 1 check (still passes) — BLE.swift is built in Task 6.

---

### Task 3: Multi-device BLE core

**Files:** Modify `BLEUnlock/BLE.swift` (class `BLE`)

**Interfaces:**
- Consumes: `aggregatePresence`, `DeviceLogic` (Task 1).
- Produces:
```swift
var monitoredUUIDs: Set<UUID>                 // replaces monitoredUUID
var unlockLogic: DeviceLogic = .all
var lockLogic: DeviceLogic = .any
var presence: Bool                             // aggregate "unlock allowed", reported via delegate
func startMonitor(uuids: Set<UUID>)            // replaces startMonitor(uuid:)
func monitoredDetectedCount() -> Int           // devices currently present
// BLEDelegate.updateRSSI(rssi:active:) now receives the strongest monitored lastRSSI
```

- [x] **Step 1:** Add `final class MonitoredDeviceState { let uuid: UUID; var peripheral: CBPeripheral?; var presence = true; var lastRSSI: Int?; var latestRSSIs: [Double] = []; var proximityTimer: Timer?; var signalTimer: Timer?; var activeModeTimer: Timer?; var connectionTimer: Timer?; var lastReadAt = 0.0; var awayReason = "away" }` and `var monitoredStates: [UUID: MonitoredDeviceState] = [:]`. Remove the single-device fields (`monitoredUUID`, `monitoredPeripheral`, `proximityTimer`, `signalTimer`, `latestRSSIs`, `activeModeTimer`, `connectionTimer`, `lastReadAt`) and convert every use.
- [x] **Step 2:** `startMonitor(uuids:)`: cancel connections + invalidate all timers of states not in `uuids`, create states for new uuids (`presence = true`, start signal timer), keep existing states, set `monitoredUUIDs`, then `reevaluatePresence(reason: "close")` and `scanForPeripherals()`. Empty set → all states torn down, `presence = false` without calling the delegate's lock path.
- [x] **Step 3:** Per-state versions: `getEstimatedRSSI(state:rssi:)`, `updateMonitored(state:rssi:)` (same thresholds as today; sets `state.presence` and `state.awayReason`, then calls `reevaluatePresence`), `resetSignalTimer(state:)` (on fire: `state.presence = false`, `state.lastRSSI = nil`, `awayReason = "lost"`, reevaluate), `connectMonitored(state:)`.
- [x] **Step 4:** `reevaluatePresence(reason:)`: `let d = aggregatePresence(monitoredStates.values.map { $0.presence }, unlockLogic: unlockLogic, lockLogic: lockLogic)`; if `d.shouldLock && presence` → `presence = false`, delegate `updatePresence(presence: false, reason: <awayReason of an away state>)`; else if `d.shouldUnlock && !presence` → `presence = true`, delegate `updatePresence(presence: true, reason: "close")`. Then `delegate?.updateRSSI(rssi: strongest lastRSSI, active: any activeModeTimer != nil)`. Changing `unlockLogic`/`lockLogic` calls `reevaluatePresence(reason: "close")` via `didSet`.
- [x] **Step 5:** `didDiscover`: look up `monitoredStates[peripheral.identifier]`; set `state.peripheral` if nil; if `state.activeModeTimer == nil` → `updateMonitored(state:rssi:)` and `connectMonitored(state:)` unless passive. `didConnect` / `didReadRSSI`: find the state by peripheral identifier. In `didReadRSSI`, only `stopScan()` when `!scanMode && monitoredStates.count == 1` (multi-device needs advertisements for the other devices). `stopScanning()`: stop scan only when exactly one state exists and it is in active mode. `setPassiveMode`: tear down every state's active timer/connection. Bluetooth powered off: every state `presence = false`, invalidate signal timers, aggregate `presence = false`.
- [x] **Step 6:** `didUpdateValueFor`: replace `device.peripheral != monitoredPeripheral` with `monitoredStates[peripheral.identifier] == nil` (also fix the existing typo `device.model != nil && device.model != nil` → `device.manufacture != nil && device.model != nil`).
- [x] **Step 7:** `monitoredDetectedCount()` = count of states with `presence && lastRSSI != nil`.

---

### Task 4: App side — prefs, selection, logic menus, status line

**Files:** Modify `BLEUnlock/AppDelegate.swift`

**Interfaces:** Consumes Task 3 API. Produces `func saveMonitoredDevices()`, `func loadMonitoredDevices() -> Set<UUID>`.

- [x] **Step 1:** Prefs: `loadMonitoredDevices()` reads `devices` ([String]); if missing and legacy `device` String exists → use it, write `devices`, remove `device`. `saveMonitoredDevices()` writes sorted uuidStrings. At launch (currently `if let str = prefs.string(forKey: "device")` ~L739) call `monitorDevices(loadMonitoredDevices())`. Load `unlockDeviceLogic` / `lockDeviceLogic` ints (missing → defaults .all / .any).
- [x] **Step 2:** `selectDevice(item:)`: toggle that uuid in `ble.monitoredUUIDs`, save, call `monitorDevices(newSet)`, update `.state` of that row, then rebuild the device menu layout (Task 5). `monitorDevice(uuid:)` → `monitorDevices(_ uuids: Set<UUID>)`; empty set → status `device_not_set`, disconnected icon.
- [x] **Step 3:** Menus: after the Lock RSSI item in `constructMenu`, add "Unlock When" (`unlock_logic`) submenu with items `unlock_logic_any` / `unlock_logic_all` and "Lock When" (`lock_logic`) with `lock_logic_any` / `lock_logic_all`; `tag` = `DeviceLogic.rawValue`; actions `setUnlockLogic(_:)` / `setLockLogic(_:)` set `ble.unlockLogic`/`ble.lockLogic` + prefs. Check-marks refreshed in `menuWillOpen`; `validateMenuItem` returns `ble.monitoredUUIDs.count > 1` for these two menus (existing RSSI rules untouched).
- [x] **Step 4:** Status line (`updateRSSI`): one monitored device → unchanged text; more than one → `String(format: t("monitor_status_detected"), ble.monitoredDetectedCount(), ble.monitoredUUIDs.count, r)` ("Detected %d/%d, strongest %ddBm"); no signal → `not_detected`.
- [x] **Step 5:** grep every former use of `monitoredUUID`, `startMonitor(uuid:`, `monitorDevice(`, `"device"` and convert; `deviceMenuInsertIndex` uses `ble.monitoredUUIDs.contains`.

---

### Task 5: Grouped, deduplicated device menu

**Files:** Modify `BLEUnlock/AppDelegate.swift` (`menuItemTitle`, `deviceMenuInsertIndex`, `newDevice`, `updateDevice`, `removeDevice`, `menuWillOpen/menuDidClose`)

- [x] **Step 1:** `menuItemTitle(device:)` → `deviceRowTitle(name: device.description, modelName: device.modelName, rssi: device.rssi)`; keep the existing MAC suffix only when the name itself is not the MAC.
- [x] **Step 2:** Replace positional insertion with `rebuildDeviceMenu()`: keep item 0 ("Scanning…"); remove all other items; build sections in order: monitored (`group_monitored`), then `DeviceCategory.allCases` (`group_iphone`, `group_watch`, `group_airpods`, `group_ipad`, `group_mac`, `group_other`). Header = disabled `NSMenuItem` (action nil, `isEnabled = false`), preceded by a separator except before the first section. Within a section order by the RSSI captured when the device was first inserted (store `deviceInsertRSSI[UUID]`), strongest first. Skip empty sections entirely. Reuse existing `NSMenuItem`s from `deviceDict` (don't recreate) so titles keep updating.
- [x] **Step 3:** Dedupe inside `rebuildDeviceMenu()`: for unmonitored devices whose `description` is not `isGenericDeviceName`, hide (don't add) a row when a monitored device has the same `description`, or an already-added unmonitored row has the same `description` with stronger RSSI.
- [x] **Step 4:** Call `rebuildDeviceMenu()` from `newDevice`, `removeDevice`, `selectDevice`, and from `updateDevice` only when that device's category or display name changed since last build (track `deviceLayoutKey[UUID] = "<category>|<name>"`), so RSSI-only updates just retitle.

---

### Task 6: Localization, build, manual verification

**Files:** Modify all 8 `BLEUnlock/*.lproj/Localizable.strings`

- [x] **Step 1:** Add keys (English values in Base; translate for da, de, ja, nb, sv, tr, zh-Hans; product names stay English):
```
"unlock_logic" = "Unlock When";
"unlock_logic_any" = "Any Device Is Near";
"unlock_logic_all" = "All Devices Are Near";
"lock_logic" = "Lock When";
"lock_logic_any" = "Any Device Is Away";
"lock_logic_all" = "All Devices Are Away";
"monitor_status_detected" = "Detected %d/%d, strongest %ddBm";
"group_monitored" = "Monitoring";
"group_iphone" = "iPhone";
"group_watch" = "Apple Watch";
"group_airpods" = "AirPods & Headphones";
"group_ipad" = "iPad";
"group_mac" = "Mac";
"group_other" = "Other";
```
- [x] **Step 2:** `plutil -lint BLEUnlock/*.lproj/Localizable.strings` → all OK.
- [x] **Step 3:** Logic check: `swiftc BLEUnlock/DeviceLogic.swift checks/DeviceLogicCheck.swift -o /tmp/devicelogic-check && /tmp/devicelogic-check` → passed.
- [ ] **Step 4:** Build via queue: `~/.claude/hooks/typecheck-queue.sh 'cd ~/BLEUnlock && xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Debug -derivedDataPath <scratchpad>/dd CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"'` → `BUILD SUCCEEDED`.
- [ ] **Step 5:** Manual (user): name shows `🍚🍳 · iPhone 14 Pro`; groups and dedupe; select iPhone + AirPods, Lock When = Any, walk away with AirPods → locks; Review Focus 1–5.
