# Multi-device monitoring, grouped device list, device naming — Design

Date: 2026-09-28
Base: ts1/BLEUnlock 1.12.2 + local fixes (#182, #137, #97, #82)
Reference (read only, not merged): Skyearn/BLEUnlock 1.14.4

## Goals

1. Show the user's device name (e.g. `🍚🍳`) instead of the model id (`Apple Inc./iPhone15,2`), with the
   model name appended when known.
2. Device list: monitored devices on top, remaining devices grouped by type, duplicates hidden.
3. Monitor several devices at once with configurable Any/All logic for lock and unlock.
   Use case: iPhone stays on the desk, user walks away wearing AirPods → Mac locks.

## Non-goals

- Re-mapping a monitored device when its BLE UUID rotates (Skyearn MAC correlation).
- GATT connection throttling / queueing.
- Keeping the device menu open while toggling devices (custom menu item views).
- Per-device RSSI thresholds or timeouts.
- AirPods-specific tracking code.

## 1. Device naming

Root cause (verified on macOS 26.5.2): `/Library/Bluetooth/*.ledevices.*.db` is root-only and
`com.apple.Bluetooth.plist` no longer has `CoreBluetoothCache`/`DeviceCache`, so
`getLEDeviceInfoFromUUID`, `getMACFromUUID` and `getNameFromMAC` return nil. `Device.description` then
prefers manufacturer/model over `peripheral.name`.

Changes (`BLE.swift`, `appleDeviceNames.swift`):

- Store the advertised local name (`CBAdvertisementDataLocalNameKey`) on the `Device` in `didDiscover`.
- Name priority: resolved Bluetooth name (existing lookups, kept) → advertised name → GAP Device Name
  (GATT `0x1800`/`0x2A00`, skipped when generic: `iPhone`, UUID/MAC, …) → `peripheral.name`
  → mapped model name → `manufacturer/model` → iBeacon → MAC → UUID.
  Generic names `iPhone`/`iPad` keep the existing "try model name" behaviour.
- Info read: after connecting, Device Information (`0x180A`: manufacturer, model) and Generic Access
  (`0x1800`: device name) are read. A listed peripheral that is already connected (monitored device in
  active mode, so no new `didConnect`) is read directly; `didConnect` also reads a listed device whose
  read never finished. An unmonitored device is disconnected once every read finished or failed
  (absent services/characteristics count as finished).
- `modelName`: `appleDeviceNames[model]` if present, else the raw model id; nil when model unknown.
- Menu row title: `<name> · <modelName> (<rssi>dBm)`; the `· <modelName>` part is omitted when the
  model is unknown or equals the name. Status line keeps the short name.
- Extend `appleDeviceNames` with current iPhone, iPad, Apple Watch, Mac and AirPods identifiers.

## 2. Device list

Layout of the Device submenu:

```
Scanning…
<Monitored header>
✓ monitored devices (RSSI desc at insertion)
<iPhone header>        ┐
<Apple Watch header>   │ each group: header + devices sorted by RSSI desc at insertion
<AirPods header>       │ empty groups (header included) hidden
<iPad header>          │
<Mac header>           │
<Other header>         ┘
Unnamed Devices (N) ▸   unmonitored rows named only by UUID/MAC (submenu, hidden when empty)
```

- Headers are disabled `NSMenuItem`s (works on macOS 10.13+).
- Device type: from model id prefix (`iPhone`, `Watch`, `AirPods`/`Beats`, `iPad`, `Mac`/`MacBook`/
  `iMac`; HomePod `AudioAccessory*` → Other), else case-insensitive name keyword (`iPhone`, `Watch`, `AirPods`, `Beats`, `iPad`, `Mac`),
  else the major device class of the paired classic Bluetooth device with the same name
  (`IOBluetoothDevice.pairedDevices()`, re-read at most every 5 s: Phone → iPhone, Computer → Mac,
  Audio → AirPods, Wearable → Apple Watch), else Other.
- Duplicates: an unmonitored row is hidden when its non-generic display name equals a monitored device's
  name, or equals another unmonitored row with stronger RSSI. Generic names (`iPhone`, `iPad`, `Mac`,
  UUID/MAC fallbacks) are never deduplicated.
- No live re-sorting on RSSI updates; order is decided at insertion. Type or monitored-state changes
  (model read later, device toggled) move the row to its new group on the next opening.
- Stable layout while open: the full sorted/grouped rebuild runs once per opening of the Device submenu
  (`menuWillOpen`; opening the "Unnamed Devices" child doesn't count as closing the parent) and when a
  device is toggled (the click closes the menu). While the submenu is open, existing rows never move:
  - an update only retitles the row (RSSI, name, model); a name or type change regroups it on the next
    opening;
  - a newly seen device is appended to the end of its group (or the "Unnamed Devices" submenu). A group
    not shown yet is added below the named groups, above "Unnamed Devices" (fixed group order is
    restored on the next opening). A device that reappears reuses its kept row or its "not detected"
    Monitored row in place;
  - a device dropped from the scan list (scan timer expired) keeps its row, titled
    `… (Signal not detected)` and disabled; a monitored one stays clickable so it can be deselected.
    The row is removed on the next opening.
  While closed, updates only maintain the row objects; nothing is re-laid out until the next opening.
- Clicking a device toggles it in the monitored set (menu closes per click), also inside the
  "Unnamed Devices" submenu. Monitored devices always stay in the Monitored group whatever their name.
- A monitored device missing from the scan list still gets a checked row in the Monitored group
  (`<last known name or UUID> · <model> (Signal not detected)`) so it can be deselected. Last known names
  are kept in the `deviceNames` pref (`[uuidString: name]`) and last read model ids in `deviceModels`
  (`[uuidString: model]`), monitored UUIDs only. A stored model is applied to a newly seen monitored
  device until GATT reads one, so its group and model suffix survive restarts. Its name doesn't hide
  same-named unmonitored rows. Ties in insertion RSSI are ordered by UUID string.

## 3. Multi-device monitoring

BLE (`BLE.swift`):

- `monitoredUUIDs: Set<UUID>` replaces `monitoredUUID`; per-device state
  (`presence`, `lastRSSI`, RSSI samples, proximity timer, signal timer, active-mode connection) replaces
  the single-device fields.
- Global settings unchanged: `lockRSSI`, `unlockRSSI`, delay to lock, no-signal timeout, passive mode.
- Scanning keeps running while more than one device is monitored (fixes ts1's `stopScan()` in
  `didReadRSSI`, which would starve other devices).
- Aggregation is a pure function:
  `aggregatePresence([DevicePresence(isPresent:, hasBeenClose:)], unlockLogic:, lockLogic:) -> AggregateDecision`
  - `hasBeenClose` = seen within unlock range since monitoring started. A device not yet seen close
    counts as present for locking (no lock at launch; it goes away when its signal timer fires "lost")
    but not for unlocking (no password typed before a device was really seen).
  - Unlock Any = any present and seen close; Unlock All = all present and seen close.
  - Lock Any = any away; Lock All = all away.
  - Only "away" (RSSI below the lock RSSI for the lock delay) locks. A device absent through signal timeout
    ("lost", e.g. turned off, AirPods in their case) never locks: lost devices are left out of both Lock Any
    and Lock All; with every device lost, nothing locks.
    A device already away keeps "away" when its signal later times out (never re-labelled "lost").
  - Conflict (both true) → lock wins.
  - Single device → both logics equivalent.
- Delegate `updatePresence` is called when the aggregate changes, and additionally with `false` whenever a
  device goes present → away (proximity "away" or signal "lost") while the aggregate says lock — so
  Lock Any re-locks after the user unlocked by password following an earlier lock.
  It is also called with `true` ("close") on the rising edge of the live Unlock When result, even while
  `presence` is still true (Unlock All + Lock All: a device left without causing a lock and came back).
  `ble.presence` = sticky aggregate (true since the last "close", false since the last lock);
  `ble.isUnlockAllowed` = live Unlock When result; `ble.isLockDue` = live Lock When result.
  `tryUnlockScreen` uses `isUnlockAllowed`; `onScreenLocked` (#137 manual-lock detection) records a manual
  lock when no lock is due (`!isLockDue`), also before any device entered unlock range.
- A lock while the screensaver-based lock is already running (Use screensaver to lock) is skipped, so
  a second departing device doesn't repeat notification / script / pause.
- Status RSSI = strongest monitored `lastRSSI`.

App (`AppDelegate.swift`):

- Prefs: `devices` ([String] of UUIDs); migrate legacy `device` (String) on first launch, then remove it.
  `lockDeviceLogic` / `unlockDeviceLogic` (Int). Defaults: lock = Any, unlock = All.
  `deviceNames` ([String: String]) last known display names of monitored devices.
  `deviceModels` ([String: String]) last read model ids of monitored devices.
- Menus: existing "Unlock RSSI" / "Lock RSSI" submenus stay unchanged (their items use `tag` = RSSI and
  `UNLOCK_DISABLED = 1`, so mixing logic items in would collide). Two new submenus right after them:
  "Unlock When" (Any device is near / All devices are near) and "Lock When" (Any device is away /
  All devices are away), radio-style checkmarks. Items enabled only when ≥ 2 devices are monitored.
- Status line: single device → unchanged; multiple → "Detected %d/%d, strongest %ddBm" or not detected.

## 4. Localization

New keys added to all 8 `.lproj` (Base, da, de, ja, nb, sv, tr, zh-Hans): `unlock_logic`,
`unlock_logic_any`, `unlock_logic_all`, `lock_logic`, `lock_logic_any`, `lock_logic_all`,
`monitor_status_detected`, `group_monitored`, `group_iphone`, `group_watch`, `group_airpods`, `group_ipad`,
`group_mac`, `group_other`, `unnamed_devices` ("Unnamed Devices (%d)"). Product names stay English.

## 5. Testing

- `xcodebuild` Debug build must succeed.
- `aggregatePresence`, `deviceCategory` (incl. paired class), `isGenericDeviceName`, `isUnnamedDeviceName`,
  `deviceRowTitle` covered by an assert-based self-check (`checks/DeviceLogicCheck.swift`).
- Manual: rename/model suffix shows; groups + dedupe; select iPhone + AirPods, Lock Any, walk away with
  AirPods only → locks; legacy single-device prefs migrate.

## Risks

- AirPods use resolvable random addresses and may not advertise steadily while connected to the iPhone;
  tracking reliability is unverified. Fallback: Apple Watch.
- Model id is only available after a GATT Device Information read (not in passive mode / some devices).
