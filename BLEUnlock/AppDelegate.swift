import Cocoa
import Quartz
import ServiceManagement

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSUserNotificationCenterDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let ble = BLE()
    let mainMenu = NSMenu()
    let deviceMenu = NSMenu()
    let lockRSSIMenu = NSMenu()
    let unlockRSSIMenu = NSMenu()
    let timeoutMenu = NSMenu()
    let lockDelayMenu = NSMenu()
    // Multi-device: "Unlock When" / "Lock When" submenus
    let unlockLogicMenu = NSMenu()
    let lockLogicMenu = NSMenu()
    var deviceDict: [UUID: NSMenuItem] = [:]
    // Device list: RSSI at first sight fixes a row's order
    var deviceInsertRSSI: [UUID: Int] = [:]
    // Device list: unmonitored rows named only by UUID/MAC, kept in one submenu at the bottom
    let unnamedDevicesMenu = NSMenu()
    let unnamedDevicesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    // Device list: true while the Device submenu is shown; its "Unnamed Devices" child has no delegate, so
    // opening that child doesn't count as closing. While open, existing rows never move.
    var isDeviceMenuOpen = false
    // Device list: non-generic names already listed, so a later same-named unmonitored row is hidden
    var shownDeviceNames: Set<String> = []
    var monitorMenuItem : NSMenuItem?
    let prefs = UserDefaults.standard
    var displaySleep = false
    var systemSleep = false
    var connected = false
    var userNotification: NSUserNotification?
    var nowPlayingWasPlaying = false
    var aboutBox: AboutBox? = nil
    var wakeTimer: Timer?
    var manualLock = false
    var unlockedAt = 0.0
    var inScreensaver = false
    var lastRSSI: Int? = nil
    // Fix #137: set right before BLEUnlock's own auto-lock, consumed by the next screen-lock notification
    var isAutoLocking = false
    // Fix #137: a lock counts as manual only if user input happened within this many seconds before it
    let MANUAL_LOCK_INPUT_WINDOW = 2.0
    // Fix #97: accepted range for the minimum RSSI of the device scan list
    let MIN_THRESHOLD_RSSI = -100
    let MAX_THRESHOLD_RSSI = -1
    // Review fix: prefs key of the last known display name per monitored UUID ([uuidString: name])
    let DEVICE_NAMES_KEY = "deviceNames"
    // Device list: prefs key of the last read model id per monitored UUID ([uuidString: model])
    let DEVICE_MODELS_KEY = "deviceModels"

    // Multi-device: radio-style checkmark shared by all tag-valued submenus (was repeated per menu)
    func checkItem(in menu: NSMenu, tag: Int) {
        for item in menu.items {
            item.state = item.tag == tag ? .on : .off
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == deviceMenu {
            // Review fix: show monitored devices missing from the scan list even before any scan result
            // Device list: the one sorted/grouped rebuild per opening; later changes keep rows in place
            isDeviceMenuOpen = true
            rebuildDeviceMenu()
            ble.startScanning()
        } else if menu == lockRSSIMenu {
            checkItem(in: menu, tag: ble.lockRSSI)
        } else if menu == unlockRSSIMenu {
            checkItem(in: menu, tag: ble.unlockRSSI)
        } else if menu == timeoutMenu {
            checkItem(in: menu, tag: Int(ble.signalTimeout))
        } else if menu == lockDelayMenu {
            checkItem(in: menu, tag: Int(ble.proximityTimeout))
        } else if menu == unlockLogicMenu {
            checkItem(in: menu, tag: ble.unlockLogic.rawValue)
        } else if menu == lockLogicMenu {
            checkItem(in: menu, tag: ble.lockLogic.rawValue)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.menu == lockRSSIMenu {
            return menuItem.tag <= ble.unlockRSSI
        } else if menuItem.menu == unlockRSSIMenu {
            return menuItem.tag >= ble.lockRSSI
        } else if menuItem.menu == unlockLogicMenu || menuItem.menu == lockLogicMenu {
            // Multi-device: Any/All only matters with two or more monitored devices
            return ble.monitoredUUIDs.count > 1
        } else if menuItem.action == #selector(selectDevice), let uuid = menuItem.representedObject as? UUID {
            // Device list: a row kept after its device left the scan list is only clickable when monitored
            return ble.devices[uuid] != nil || ble.monitoredUUIDs.contains(uuid)
        }
        return true
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu == deviceMenu {
            // Device list: back to lazy mode, the next opening rebuilds
            isDeviceMenuOpen = false
            ble.stopScanning()
        }
    }
    
    // Naming: "<name> (<MAC>) · <model> (<detail>)"; MAC only when resolved and not already the name.
    // Review fix: `name` is the caller's device.description, computed once (it may read SQLite/plist)
    // Device list: detail is the RSSI unless given (not-detected status of a row kept while the menu is open)
    func menuItemTitle(device: Device, name: String, detail: String? = nil) -> String {
        let modelName = device.modelName == name ? nil : device.modelName
        let detail = detail ?? "\(device.rssi)dBm"
        guard let mac = device.macAddr, mac != name else {
            return deviceRowTitle(name: name, modelName: modelName, detail: detail)
        }
        let prettifiedMac = mac.replacingOccurrences(of: "-", with: ":").uppercased()
        return deviceRowTitle(name: "\(name) (\(prettifiedMac))", modelName: modelName, detail: detail)
    }

    // Device list: header title key per category, in DeviceCategory order
    func groupTitleKey(_ category: DeviceCategory) -> String {
        switch category {
        case .iphone: return "group_iphone"
        case .watch: return "group_watch"
        case .airpods: return "group_airpods"
        case .ipad: return "group_ipad"
        case .mac: return "group_mac"
        case .other: return "group_other"
        }
    }

    // Device list: paired classic Bluetooth class decides when model and name don't
    func category(device: Device, name: String) -> DeviceCategory {
        return deviceCategory(model: device.model, name: name, pairedClassMajor: ble.pairedClassMajor(name: name))
    }

    // Device list: where a scanned row goes (section header title, the unnamed submenu, or hidden)
    enum DeviceRowPlacement {
        case section(String)
        case unnamed
        case hidden
    }

    // Device list: monitored first; an unmonitored row whose non-generic name is already shown is hidden,
    // otherwise its name is recorded as shown
    func placeRow(device: Device, name: String, monitored: Set<UUID>) -> DeviceRowPlacement {
        if monitored.contains(device.uuid) { return .section(t("group_monitored")) }
        if isUnnamedDeviceName(name) { return .unnamed }
        if !isGenericDeviceName(name) && shownDeviceNames.contains(name) { return .hidden }
        shownDeviceNames.insert(name)
        return .section(t(groupTitleKey(category(device: device, name: name))))
    }

    // Device list: row goes to the end of its section; a section not shown yet is added below the named
    // sections (above "Unnamed Devices"), so on an open menu no existing row changes order
    func appendRow(_ item: NSMenuItem, toSection title: String) {
        let items = deviceMenu.items
        if let headerIndex = items.firstIndex(where: { $0.action == nil && $0.title == title }) {
            let sectionEnd = items[(headerIndex + 1)...].firstIndex(where: { $0.isSeparatorItem }) ?? items.count
            deviceMenu.insertItem(item, at: sectionEnd)
            return
        }
        // "Unnamed Devices" is always preceded by its own separator
        var index = items.firstIndex(of: unnamedDevicesItem).map { $0 - 1 } ?? items.count
        if index > 1 {
            deviceMenu.insertItem(NSMenuItem.separator(), at: index)
            index += 1
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        deviceMenu.insertItem(header, at: index)
        deviceMenu.insertItem(item, at: index + 1)
    }

    // Device list: row goes to the end of the "Unnamed Devices" submenu, shown at the bottom once non-empty
    func appendUnnamedRow(_ item: NSMenuItem) {
        unnamedDevicesMenu.addItem(item)
        unnamedDevicesItem.title = String(format: t("unnamed_devices"), unnamedDevicesMenu.items.count)
        guard !deviceMenu.items.contains(unnamedDevicesItem) else { return }
        deviceMenu.addItem(NSMenuItem.separator())
        deviceMenu.addItem(unnamedDevicesItem)
    }

    // Device list (Fix #82/#173 successor): "Scanning…" first, then monitored devices, then one section per
    // category. Rows keep their first-sight RSSI order (strongest first); empty sections are hidden;
    // an unmonitored row whose non-generic name is already shown (monitored or stronger) is hidden.
    // Device list: unmonitored UUID/MAC-only rows go to the "Unnamed Devices" submenu at the bottom.
    func rebuildDeviceMenu() {
        while deviceMenu.items.count > 1 {
            deviceMenu.removeItem(at: 1)
        }
        unnamedDevicesMenu.removeAllItems()
        // Device list: rows kept (not detected) while the menu was open are dropped now
        let departedUUIDs = deviceDict.keys.filter { ble.devices[$0] == nil }
        for uuid in departedUUIDs {
            deviceDict.removeValue(forKey: uuid)
            deviceInsertRSSI.removeValue(forKey: uuid)
        }
        let monitored = ble.monitoredUUIDs
        // Review fix: uuidString breaks RSSI ties so the order doesn't follow Dictionary order
        let rows = deviceDict.compactMap { uuid, item -> (device: Device, item: NSMenuItem, name: String)? in
            guard let device = ble.devices[uuid] else { return nil }
            return (device, item, device.description)
        }.sorted {
            let lhsRSSI = deviceInsertRSSI[$0.device.uuid] ?? $0.device.rssi
            let rhsRSSI = deviceInsertRSSI[$1.device.uuid] ?? $1.device.rssi
            return lhsRSSI != rhsRSSI ? lhsRSSI > rhsRSSI : $0.device.uuid.uuidString < $1.device.uuid.uuidString
        }

        let monitoredRows = rows.filter { monitored.contains($0.device.uuid) }
        let deviceNames = saveMonitoredValues(monitoredRows.map { ($0.device.uuid, $0.name) }, forKey: DEVICE_NAMES_KEY)
        let deviceModels = saveMonitoredValues(monitoredRows.compactMap { row -> (UUID, String)? in
            guard let model = row.device.model else { return nil }
            return (row.device.uuid, model)
        }, forKey: DEVICE_MODELS_KEY)
        shownDeviceNames = Set(monitoredRows.map { $0.name })
        var itemsBySection: [String: [NSMenuItem]] = [:]
        var unnamedItems: [NSMenuItem] = []
        for row in rows {
            row.item.state = monitored.contains(row.device.uuid) ? .on : .off
            switch placeRow(device: row.device, name: row.name, monitored: monitored) {
            case .section(let title): itemsBySection[title, default: []].append(row.item)
            case .unnamed: unnamedItems.append(row.item)
            case .hidden: break
            }
        }

        // Review fix: monitored devices without a scan row stay listed (checked) so they can be deselected;
        // their names aren't added to shownDeviceNames, so a same-named device under a new UUID stays pickable
        let scannedUUIDs = Set(rows.compactMap { $0.device.uuid })
        let missingItems = monitored.subtracting(scannedUUIDs)
            .sorted { $0.uuidString < $1.uuidString }
            .map { missingDeviceItem(uuid: $0, name: deviceNames[$0.uuidString], model: deviceModels[$0.uuidString]) }
        let monitoredTitle = t("group_monitored")
        itemsBySection[monitoredTitle, default: []] += missingItems

        // Device list: same placement path as open-menu insertion, fed in fixed section order
        let sectionTitles = [monitoredTitle] + DeviceCategory.allCases.map { t(groupTitleKey($0)) }
        for title in sectionTitles {
            itemsBySection[title]?.forEach { appendRow($0, toSection: title) }
        }
        unnamedItems.forEach(appendUnnamedRow)
    }

    // Review fix: stores values (names, models) of monitored devices seen in the scan under `key`,
    // drops unmonitored UUIDs, returns the stored values
    func saveMonitoredValues(_ seenValues: [(UUID, String)], forKey key: String) -> [String: String] {
        let monitoredStrings = Set(ble.monitoredUUIDs.map { $0.uuidString })
        let stored = prefs.dictionary(forKey: key) as? [String: String] ?? [:]
        var values = stored.filter { monitoredStrings.contains($0.key) }
        for (uuid, value) in seenValues {
            values[uuid.uuidString] = value
        }
        if values != stored {
            prefs.set(values, forKey: key)
        }
        return values
    }

    // Review fix: checked row of a monitored device absent from the scan list; rebuilt fresh on every
    // rebuildDeviceMenu, so it never duplicates the real row once the device reappears
    // Device list: stored model keeps the model suffix while the device is missing
    func missingDeviceItem(uuid: UUID, name: String?, model: String?) -> NSMenuItem {
        let label = name ?? uuid.uuidString
        let title = deviceRowTitle(name: label, modelName: model.map(modelDisplayName), detail: t("not_detected"))
        let item = NSMenuItem(title: title, action: #selector(selectDevice), keyEquivalent: "")
        item.representedObject = uuid
        item.state = .on
        return item
    }

    // Device list: rows are placed by rebuildDeviceMenu on each opening; while the menu is open a new row is
    // appended to the end of its section, so existing rows don't move
    func newDevice(device: Device) {
        // Device list: a monitored device keeps its stored model (category, suffix) until GATT reads one
        if device.model == nil, let models = prefs.dictionary(forKey: DEVICE_MODELS_KEY) as? [String: String] {
            device.model = models[device.uuid.uuidString]
        }
        let name = device.description
        let title = menuItemTitle(device: device, name: name)
        deviceInsertRSSI[device.uuid] = device.rssi
        // Device list: a kept not-detected row or a missing monitored row of this UUID comes back in place
        let existingItem = deviceDict[device.uuid]
            ?? deviceMenu.items.first { $0.representedObject as? UUID == device.uuid }
        if let item = existingItem {
            item.title = title
            item.isEnabled = true
            deviceDict[device.uuid] = item
            return
        }
        let item = NSMenuItem(title: title, action: #selector(selectDevice), keyEquivalent: "")
        // Review fix: selectDevice reads the UUID from the item (also used by rows of missing devices)
        item.representedObject = device.uuid
        deviceDict[device.uuid] = item
        guard isDeviceMenuOpen else { return }
        switch placeRow(device: device, name: name, monitored: ble.monitoredUUIDs) {
        case .section(let sectionTitle): appendRow(item, toSection: sectionTitle)
        case .unnamed: appendUnnamedRow(item)
        case .hidden: break
        }
    }

    // Device list: updates only retitle (RSSI, name, model); a name or category change regroups the row
    // on the next opening. Review fix: device.description computed once per update
    func updateDevice(device: Device) {
        guard let menuItem = deviceDict[device.uuid] else { return }
        menuItem.title = menuItemTitle(device: device, name: device.description)
    }

    // Device list: while the menu is open the row stays in place as not detected, disabled unless monitored
    // (deselection); rebuildDeviceMenu drops it on the next opening. BLE removes the Device right after.
    func removeDevice(device: Device) {
        guard isDeviceMenuOpen, let item = deviceDict[device.uuid] else {
            deviceDict.removeValue(forKey: device.uuid)
            deviceInsertRSSI.removeValue(forKey: device.uuid)
            return
        }
        item.title = menuItemTitle(device: device, name: device.description, detail: t("not_detected"))
        item.isEnabled = ble.monitoredUUIDs.contains(device.uuid)
    }

    func updateRSSI(rssi: Int?, active: Bool) {
        if let r = rssi {
            lastRSSI = r
            // Multi-device: with several devices show how many are detected and the strongest signal
            let monitoredCount = ble.monitoredUUIDs.count
            monitorMenuItem?.title = monitoredCount > 1
                ? String(format: t("monitor_status_detected"), ble.monitoredDetectedCount(), monitoredCount, r)
                : String(format:"%ddBm", r) + (active ? " (Active)" : "")
            if (!connected) {
                connected = true
                statusItem.button?.image = NSImage(named: "StatusBarConnected")
            }
        } else {
            monitorMenuItem?.title = t("not_detected")
            if (connected) {
                connected = false
                statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
            }
        }
    }

    func bluetoothPowerWarn() {
        errorModal(t("bluetooth_power_warn"))
    }

    func notifyUser(_ reason: String) {
        let un = NSUserNotification()
        un.title = "BLEUnlock"
        if reason == "lost" {
            un.subtitle = t("notification_lost_signal")
        } else if reason == "away" {
            un.subtitle = t("notification_device_away")
        }
        un.informativeText = t("notification_locked")
        un.deliveryDate = Date().addingTimeInterval(1)
        NSUserNotificationCenter.default.scheduleNotification(un)
        userNotification = un
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        if notification != userNotification {
            NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock/releases")!)
            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
        }
    }

    func runScript(_ arg: String) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        if let r = lastRSSI {
            process.arguments = [arg, String(r)]
        } else {
            process.arguments = [arg]
        }
        try? process.run()
    }

    func pauseNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(
            DispatchQueue.main,
            { (playing) in
                // Review fix: a repeated lock while already paused must not forget that playback was paused
                // by us; playNowPlaying clears the flag after resuming
                guard playing else { return }
                self.nowPlayingWasPlaying = true
                print("pause")
                MRMediaRemoteSendCommand(MRCommandPause, nil)
            }
        )
    }
    
    func playNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        if nowPlayingWasPlaying {
            print("play")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
                MRMediaRemoteSendCommand(MRCommandPlay, nil)
                self.nowPlayingWasPlaying = false
            })
        }
    }

    func lockOrSaveScreen() {
        if prefs.bool(forKey: "screensaver") {
            NSWorkspace.shared.launchApplication("ScreenSaverEngine")
        } else {
            if SACLockScreenImmediate() != 0 {
                print("Failed to lock screen")
            }
            if prefs.bool(forKey: "sleepDisplay") {
                print("sleep display")
                sleepDisplay()
            }
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        if presence {
            // Fix #137: auto-lock produced no lock (e.g. screensaver without password); don't let the flag go stale
            if !isScreenLocked() {
                isAutoLocking = false
            }
            if ble.unlockRSSI != ble.UNLOCK_DISABLED {
                if let un = userNotification {
                    NSUserNotificationCenter.default.removeDeliveredNotification(un)
                    userNotification = nil
                }
                if displaySleep && !systemSleep && prefs.bool(forKey: "wakeOnProximity") {
                    print("Waking display")
                    wakeDisplay()
                    // Review fix: a second "close" must not orphan a still-running retry timer
                    wakeTimer?.invalidate()
                    wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { _ in
                        print("Retrying waking display")
                        wakeDisplay()
                    })
                }
                tryUnlockScreen()
            }
        } else {
            // Review fix: screensaver-based lock already running (no immediate password) → a second departing
            // device must not repeat the lock side effects
            let isScreensaverLockActive = inScreensaver && prefs.bool(forKey: "screensaver")
            if !isScreenLocked() && !isScreensaverLockActive && ble.lockRSSI != ble.LOCK_DISABLED {
                pauseNowPlaying()
                // Fix #137: mark this lock as BLEUnlock's own so onScreenLocked won't treat it as manual
                isAutoLocking = true
                lockOrSaveScreen()
                notifyUser(reason)
                runScript(reason)
            }
            manualLock = false
        }
    }

    // Fix #182: returns false (and stops posting events) as soon as the screen is no longer locked,
    // so the password never lands in whatever app gained focus after an unlock by other means.
    func fakeKeyStrokes(_ string: String) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        // Send 20 characters per keyboard event. That seems to be the limit.
        let PER = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: PER) {
            guard isScreenLocked() else { return false }
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            // Fix #182: buffer was never freed
            defer { buffer.deallocate() }
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }
        
        // Return key
        guard isScreenLocked() else { return false }
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: false)?.post(tap: .cghidEventTap)
        return true
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }
    
    func tryUnlockScreen() {
        guard !manualLock else { return }
        // Multi-device: honour Unlock When rule live, `presence` alone can stay sticky-true
        guard ble.isUnlockAllowed else { return }
        guard ble.unlockRSSI != ble.UNLOCK_DISABLED else { return }
        guard !systemSleep else { return }
        guard !displaySleep else { return }

        if inScreensaver {
            // In screensaver, make sure Login panel is displayed
            let src = CGEventSource(stateID: .hidSystemState)
            // Esc key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
        }

        guard !self.prefs.bool(forKey: "wakeWithoutUnlocking") else { return }

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
            guard self.isScreenLocked() else { return }
            guard let password = self.fetchPassword(warn: true) else { return }
            // Fix #182: Keychain fetch can be slow; the Mac may have been unlocked meanwhile
            guard self.isScreenLocked() else { return }

            print("Entering password")
            guard self.fakeKeyStrokes(password) else {
                print("Screen unlocked while entering password, aborted")
                return
            }
            self.unlockedAt = Date().timeIntervalSince1970
            self.playNowPlaying()
            self.runScript("unlocked")
        })
    }

    @objc func onDisplayWake() {
        print("display wake")
        //unlockedAt = Date().timeIntervalSince1970
        displaySleep = false
        wakeTimer?.invalidate()
        wakeTimer = nil
        tryUnlockScreen()
    }

    @objc func onDisplaySleep() {
        print("display sleep")
        displaySleep = true
    }

    @objc func onSystemWake() {
        print("system wake")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            print("delayed system wake job")
            NSApp.setActivationPolicy(.accessory) // Hide Dock icon again
            self.systemSleep = false
            self.tryUnlockScreen()
        })
    }
    
    @objc func onSystemSleep() {
        print("system sleep")
        systemSleep = true
        // Set activation policy to regular, so the CBCentralManager can scan for peripherals
        // when the Bluetooth will become on again.
        // This enables Dock icon but the screen is off anyway.
        NSApp.setActivationPolicy(.regular)
    }

    @objc func onUnlock() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            print("onUnlock")
            if Date().timeIntervalSince1970 >= self.unlockedAt + 10 {
                if self.ble.unlockRSSI != self.ble.UNLOCK_DISABLED {
                    self.runScript("intruded")
                }
                self.playNowPlaying()
            }
        })
        manualLock = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            checkUpdate()
        })
    }

    // Fix #137: a lock done via macOS (Ctrl+Cmd+Q, Apple menu) while the device is nearby counts as manual,
    // so it won't auto-unlock until the device goes away and comes back. Idle/sleep-triggered locks are
    // excluded (no recent user input, or display/system asleep) so wake-to-unlock keeps working.
    @objc func onScreenLocked() {
        let isOwnAutoLock = isAutoLocking
        isAutoLocking = false
        // Review fix: "no lock due" (live Lock When), not the Unlock When rule or sticky `presence`: a manual
        // lock is recorded while one device is away under Unlock All + Lock All, and also before any device
        // entered unlock range (where `presence` is still false), so a later approach won't type the password
        guard !isOwnAutoLock, !ble.isLockDue, !displaySleep, !systemSleep else { return }
        guard let anyInputEventType = CGEventType(rawValue: ~0) else { return }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
        guard idleSeconds < MANUAL_LOCK_INPUT_WINDOW else { return }
        print("Manual lock detected")
        manualLock = true
    }

    @objc func onScreensaverStart() {
        print("screensaver start")
        inScreensaver = true
    }

    @objc func onScreensaverStop() {
        print("screensaver stop")
        inScreensaver = false
    }

    // Multi-device: a click toggles the device in the monitored set.
    // Review fix: UUID from representedObject, which rows of missing monitored devices carry too
    @objc func selectDevice(item: NSMenuItem) {
        guard let uuid = item.representedObject as? UUID else { return }
        monitorDevices(ble.monitoredUUIDs.symmetricDifference([uuid]))
        saveMonitoredDevices()
        rebuildDeviceMenu()
    }

    // Multi-device: (re)start monitoring; an empty set shows "Device not selected"
    func monitorDevices(_ uuids: Set<UUID>) {
        connected = false
        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        monitorMenuItem?.title = t(uuids.isEmpty ? "device_not_set" : "not_detected")
        ble.startMonitor(uuids: uuids)
    }

    // Multi-device: persisted as "devices"; the legacy single "device" pref is migrated once
    func loadMonitoredDevices() -> Set<UUID> {
        if let uuidStrings = prefs.stringArray(forKey: "devices") {
            return Set(uuidStrings.compactMap { UUID(uuidString: $0) })
        }
        guard let legacy = prefs.string(forKey: "device"), let uuid = UUID(uuidString: legacy) else { return [] }
        prefs.set([uuid.uuidString], forKey: "devices")
        prefs.removeObject(forKey: "device")
        return [uuid]
    }

    func saveMonitoredDevices() {
        prefs.set(ble.monitoredUUIDs.map { $0.uuidString }.sorted(), forKey: "devices")
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    func storePassword(_ password: String) {
        let pw = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecAttrLabel): "BLEUnlock",
            String(kSecValueData): pw,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            let err = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to store password to Keychain", info: err as String? ?? "Status \(status)")
            return
        }
    }

    func fetchPassword(warn: Bool = false) -> String? {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "BLEUnlock",
            String(kSecReturnData): kCFBooleanTrue!,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if (status == errSecItemNotFound) {
            print("Password is not stored")
            if warn {
                errorModal(t("password_not_set"))
            }
            return nil
        }
        guard status == errSecSuccess else {
            let info = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to retrieve password", info: info as String? ?? "Status \(status)")
            return nil
        }
        guard let data = item as? Data else {
            errorModal("Failed to convert password")
            return nil
        }
        return String(data: data, encoding: .utf8)!
    }
    
    @objc func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_password")
        msg.informativeText = t("password_info")
        msg.window.title = "BLEUnlock"

        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let pw = txt.stringValue
            storePassword(pw)
        }
    }
    
    @objc func setRSSIThreshold() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_rssi_threshold")
        msg.informativeText = t("enter_rssi_threshold_info")
        msg.window.title = "BLEUnlock"
        
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        txt.placeholderString = String(ble.thresholdRSSI)
        // Fix #97: pre-fill with the current value so OK without edits keeps it
        txt.stringValue = String(ble.thresholdRSSI)
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            // Fix #97: empty, non-numeric or out-of-range input keeps the current value
            let input = txt.stringValue.trimmingCharacters(in: .whitespaces)
            guard let val = Int(input), (MIN_THRESHOLD_RSSI...MAX_THRESHOLD_RSSI).contains(val) else { return }
            ble.thresholdRSSI = val
            prefs.set(val, forKey: "thresholdRSSI")
        }
    }

    @objc func toggleWakeOnProximity(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "wakeOnProximity")
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: "wakeOnProximity")
    }

    @objc func setLockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockRSSI")
        ble.lockRSSI = value
    }
    
    @objc func setUnlockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "unlockRSSI")
        ble.unlockRSSI = value
    }

    // Multi-device: Any/All logic, item tag = DeviceLogic raw value
    @objc func setUnlockLogic(_ menuItem: NSMenuItem) {
        guard let logic = DeviceLogic(rawValue: menuItem.tag) else { return }
        prefs.set(logic.rawValue, forKey: "unlockDeviceLogic")
        ble.unlockLogic = logic
    }

    @objc func setLockLogic(_ menuItem: NSMenuItem) {
        guard let logic = DeviceLogic(rawValue: menuItem.tag) else { return }
        prefs.set(logic.rawValue, forKey: "lockDeviceLogic")
        ble.lockLogic = logic
    }

    @objc func setTimeout(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "timeout")
        ble.signalTimeout = Double(value)
    }

    @objc func setLockDelay(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockDelay")
        ble.proximityTimeout = Double(value)
    }

    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        let launchAtLogin = !prefs.bool(forKey: "launchAtLogin")
        prefs.set(launchAtLogin, forKey: "launchAtLogin")
        menuItem.state = launchAtLogin ? .on : .off
        SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! + ".Launcher" as CFString, launchAtLogin)
    }

    @objc func togglePauseNowPlaying(_ menuItem: NSMenuItem) {
        let pauseNowPlaying = !prefs.bool(forKey: "pauseItunes")
        prefs.set(pauseNowPlaying, forKey: "pauseItunes")
        menuItem.state = pauseNowPlaying ? .on : .off
    }
    
    @objc func toggleUseScreensaver(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "screensaver")
        prefs.set(value, forKey: "screensaver")
        menuItem.state = value ? .on : .off
    }

    @objc func toggleSleepDisplay(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "sleepDisplay")
        prefs.set(value, forKey: "sleepDisplay")
        menuItem.state = value ? .on : .off
    }
    
    @objc func togglePassiveMode(_ menuItem: NSMenuItem) {
        let passiveMode = !prefs.bool(forKey: "passiveMode")
        prefs.set(passiveMode, forKey: "passiveMode")
        menuItem.state = passiveMode ? .on : .off
        ble.setPassiveMode(passiveMode)
    }

    @objc func toggleWakeWithoutUnlocking(_ menuItem: NSMenuItem) {
        let wakeWithoutUnlocking = !prefs.bool(forKey: "wakeWithoutUnlocking")
        prefs.set(wakeWithoutUnlocking, forKey: "wakeWithoutUnlocking")
        menuItem.state = wakeWithoutUnlocking ? .on : .off
    }

    @objc func lockNow() {
        guard !isScreenLocked() else { return }
        manualLock = true
        pauseNowPlaying()
        lockOrSaveScreen()
    }
    
    @objc func showAboutBox() {
        AboutBox.showAboutBox()
    }

    func constructRSSIMenu(_ menu: NSMenu, _ action: Selector) {
        menu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            let item = menu.addItem(withTitle: String(format: "%ddBm", proximity), action: action, keyEquivalent: "")
            item.tag = proximity
        }
        menu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        menu.delegate = self
    }

    // Multi-device: Any/All submenu, kept apart from the RSSI menus whose tags are RSSI values
    func constructLogicMenu(_ menu: NSMenu, title: String, anyTitle: String, allTitle: String, action: Selector) {
        mainMenu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        menu.addItem(withTitle: anyTitle, action: action, keyEquivalent: "").tag = DeviceLogic.any.rawValue
        menu.addItem(withTitle: allTitle, action: action, keyEquivalent: "").tag = DeviceLogic.all.rawValue
        menu.delegate = self
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("device_not_set"), action: nil, keyEquivalent: "")
        
        var item: NSMenuItem

        item = mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())

        item = mainMenu.addItem(withTitle: t("device"), action: nil, keyEquivalent: "")
        item.submenu = deviceMenu
        deviceMenu.delegate = self
        deviceMenu.addItem(withTitle: t("scanning"), action: nil, keyEquivalent: "")
        // Device list: the submenu is attached once; only its item is added (appendUnnamedRow) or removed
        unnamedDevicesItem.submenu = unnamedDevicesMenu

        let unlockRSSIItem = mainMenu.addItem(withTitle: t("unlock_rssi"), action: nil, keyEquivalent: "")
        unlockRSSIItem.submenu = unlockRSSIMenu
        item = unlockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setUnlockRSSI), keyEquivalent: "")
        item.tag = ble.UNLOCK_DISABLED
        constructRSSIMenu(unlockRSSIMenu, #selector(setUnlockRSSI))

        let lockRSSIItem = mainMenu.addItem(withTitle: t("lock_rssi"), action: nil, keyEquivalent: "")
        lockRSSIItem.submenu = lockRSSIMenu
        constructRSSIMenu(lockRSSIMenu, #selector(setLockRSSI))
        item = lockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setLockRSSI), keyEquivalent: "")
        item.tag = ble.LOCK_DISABLED

        constructLogicMenu(unlockLogicMenu, title: t("unlock_logic"), anyTitle: t("unlock_logic_any"),
                           allTitle: t("unlock_logic_all"), action: #selector(setUnlockLogic))
        constructLogicMenu(lockLogicMenu, title: t("lock_logic"), anyTitle: t("lock_logic_any"),
                           allTitle: t("lock_logic_all"), action: #selector(setLockLogic))

        let lockDelayItem = mainMenu.addItem(withTitle: t("lock_delay"), action: nil, keyEquivalent: "")
        lockDelayItem.submenu = lockDelayMenu
        lockDelayMenu.addItem(withTitle: "2 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 2
        lockDelayMenu.addItem(withTitle: "5 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 5
        lockDelayMenu.addItem(withTitle: "15 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 15
        lockDelayMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 30
        lockDelayMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setLockDelay), keyEquivalent: "").tag = 60
        lockDelayMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 120
        lockDelayMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 300
        lockDelayMenu.delegate = self

        let timeoutItem = mainMenu.addItem(withTitle: t("timeout"), action: nil, keyEquivalent: "")
        timeoutItem.submenu = timeoutMenu
        timeoutMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setTimeout), keyEquivalent: "").tag = 30
        timeoutMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setTimeout), keyEquivalent: "").tag = 60
        timeoutMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 120
        timeoutMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 300
        timeoutMenu.addItem(withTitle: "10 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 600
        timeoutMenu.delegate = self

        item = mainMenu.addItem(withTitle: t("wake_on_proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        if prefs.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("wake_without_unlocking"), action: #selector(toggleWakeWithoutUnlocking), keyEquivalent: "")
        if prefs.bool(forKey: "wakeWithoutUnlocking") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("pause_now_playing"), action: #selector(togglePauseNowPlaying), keyEquivalent: "")
        if prefs.bool(forKey: "pauseItunes") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("use_screensaver_to_lock"), action: #selector(toggleUseScreensaver), keyEquivalent: "")
        if prefs.bool(forKey: "screensaver") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("sleep_display"), action: #selector(toggleSleepDisplay), keyEquivalent: "")
        if prefs.bool(forKey: "sleepDisplay") {
            item.state = .on
        }
        
        mainMenu.addItem(withTitle: t("set_password"), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: t("passive_mode"), action: #selector(togglePassiveMode), keyEquivalent: "")
        item.state = prefs.bool(forKey: "passiveMode") ? .on : .off
        
        item = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off
        
        mainMenu.addItem(withTitle: t("set_rssi_threshold"), action: #selector(setRSSIThreshold),
                         keyEquivalent: "")

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = mainMenu
    }

    func checkAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        if (!AXIsProcessTrustedWithOptions([key: true] as CFDictionary)) {
            // Sometimes Prompt option above doesn't work.
            // Actually trying to send key may open that dialog.
            let src = CGEventSource(stateID: .hidSystemState)
            // "Fn" key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            constructMenu()
        }
        ble.delegate = self
        let lockRSSI = prefs.integer(forKey: "lockRSSI")
        if lockRSSI != 0 {
            ble.lockRSSI = lockRSSI
        }
        let unlockRSSI = prefs.integer(forKey: "unlockRSSI")
        if unlockRSSI != 0 {
            ble.unlockRSSI = unlockRSSI
        }
        let timeout = prefs.integer(forKey: "timeout")
        if timeout != 0 {
            ble.signalTimeout = Double(timeout)
        }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI")
        if thresholdRSSI != 0 {
            ble.thresholdRSSI = thresholdRSSI
        }
        let lockDelay = prefs.integer(forKey: "lockDelay")
        if lockDelay != 0 {
            ble.proximityTimeout = Double(lockDelay)
        }
        // Multi-device: logic prefs (missing → defaults unlock All / lock Any), then monitor once all
        // thresholds and timeouts are loaded so the first evaluation and signal timers use them
        if let raw = prefs.object(forKey: "unlockDeviceLogic") as? Int, let logic = DeviceLogic(rawValue: raw) {
            ble.unlockLogic = logic
        }
        if let raw = prefs.object(forKey: "lockDeviceLogic") as? Int, let logic = DeviceLogic(rawValue: raw) {
            ble.lockLogic = logic
        }
        monitorDevices(loadMonitoredDevices())

        NSUserNotificationCenter.default.delegate = self

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        // Fix #137: detect locks not initiated by BLEUnlock
        dnc.addObserver(self, selector: #selector(onScreenLocked), name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStart), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStop), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)

        if ble.unlockRSSI != ble.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") && fetchPassword() == nil {
            askPassword()
        }
        checkAccessibility()
        checkUpdate()

        // Hide dock icon.
        // This is required because we can't have LSUIElement set to true in Info.plist,
        // otherwise CBCentralManager.scanForPeripherals won't work.
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
}
