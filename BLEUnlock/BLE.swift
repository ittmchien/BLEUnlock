import Foundation
import CoreBluetooth
import Accelerate
import IOBluetooth

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
// Naming: GAP service / Device Name characteristic
let GenericAccess = CBUUID(string:"1800")
let DeviceNameCharacteristic = CBUUID(string:"2A00")
// Naming: characteristics read per info service after connecting
let InfoCharacteristics: [CBUUID: [CBUUID]] = [
    DeviceInformation: [ManufacturerName, ModelName],
    GenericAccess: [DeviceNameCharacteristic],
]
let ExposureNotification = CBUUID(string:"FD6F")

func getMACFromUUID(_ uuid: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let cbcache = plist["CoreBluetoothCache"] as? NSDictionary else { return nil }
    guard let device = cbcache[uuid] as? NSDictionary else { return nil }
    return device["DeviceAddress"] as? String
}

func getNameFromMAC(_ mac: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let devcache = plist["DeviceCache"] as? NSDictionary else { return nil }
    guard let device = devcache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "" { return nil }
        return trimmed
    }
    return nil
}

// Classic monitoring: device key of a CoreBluetooth peripheral
extension CBPeripheral {
    var deviceID: DeviceID {
        return .le(identifier)
    }
}

class Device: NSObject {
    // Classic monitoring: BLE UUID or Classic MAC
    let id: DeviceID
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?
    // Naming: local name from advertisements; the Bluetooth caches holding user names are unreadable on recent macOS
    var advertisedName: String?
    // Naming: GAP Device Name read over GATT
    var gattName: String?
    // Naming: info services / characteristics still awaited; the info read is over once empty
    var pendingInfoReads: Set<CBUUID> = []
    var hasReadInfo = false

    // Naming: bare product names that yield to a known model name
    private static let bareProductNames: Set<String> = ["iPhone", "iPad"]

    private var mappedModelName: String? {
        guard let model = model else { return nil }
        return appleDeviceNames[model]
    }

    // Naming: marketing name when mapped, else the raw model id; nil when the model is unknown
    var modelName: String? {
        return model.map(modelDisplayName)
    }

    override var description: String {
        get {
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
            if let mac = macAddr {
                if blName == nil {
                    blName = getNameFromMAC(mac)
                }
                if let name = blName {
                    // If it's just "iPhone" or "iPad", there's a chance we can get the model name in the following code
                    if !Device.bareProductNames.contains(name) {
                        return name
                    }
                }
            }
            // Naming: user-visible names beat model ids; a bare "iPhone"/"iPad" yields to a mapped model name;
            // a generic GAP name ("iPhone", UUID/MAC) is skipped
            let usableGattName = gattName.flatMap { isGenericDeviceName($0) ? nil : $0 }
            for candidate in [advertisedName, usableGattName, peripheral?.name] {
                guard let name = candidate?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
                if Device.bareProductNames.contains(name) && mappedModelName != nil { continue }
                return name
            }
            if let mapped = mappedModelName {
                return mapped
            }
            if let manu = manufacture {
                if let mod = model {
                    return String(format: "%@/%@", manu, mod)
                }
                return manu
            }
            if let mod = model {
                return mod
            }
            // iBeacon
            if let adv = advData {
                if adv.count >= 25 {
                    var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                    if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                        let major = uint16(adv[20]) << 8 | uint16(adv[21])
                        let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                        let tx = Int8(bitPattern: adv[24])
                        let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                        let d = String(format:"%.1f", distance)
                        return "iBeacon [\(major), \(minor)] \(d)m"
                    }
                }
            }
            if let name = blName {
                return name
            }
            if let mac = macAddr {
                return mac // better than uuid
            }
            return id.prefString
        }
    }

    // Classic monitoring: re-keyed from UUID to DeviceID
    init(id: DeviceID) {
        self.id = id
    }
}

// Naming: marketing name for a model id, else the id itself
func modelDisplayName(_ model: String) -> String {
    return appleDeviceNames[model] ?? model
}

protocol BLEDelegate {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?, active: Bool)
    func updatePresence(presence: Bool, reason: String)
    func bluetoothPowerWarn()
}

// Multi-device: per-device monitoring state (replaces BLE's former single-device fields)
final class MonitoredDeviceState {
    // Classic monitoring: keyed by DeviceID
    let id: DeviceID
    var peripheral: CBPeripheral?
    var presence = true
    // Review fix: set once the device is seen within unlock range; gates unlocking, not locking
    var hasBeenClose = false
    var lastRSSI: Int?
    var latestRSSIs: [Double] = []
    var proximityTimer: Timer?
    var signalTimer: Timer?
    var activeModeTimer: Timer?
    var connectionTimer: Timer?
    var lastReadAt = 0.0
    var awayReason = "away"

    init(id: DeviceID) {
        self.id = id
    }

    func invalidateTimers() {
        for timer in [proximityTimer, signalTimer, activeModeTimer, connectionTimer] {
            timer?.invalidate()
        }
        proximityTimer = nil
        signalTimer = nil
        activeModeTimer = nil
        connectionTimer = nil
    }
}

class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let UNLOCK_DISABLED = 1
    let LOCK_DISABLED = -100
    // Multi-device: former inline timing literals of active mode / connection handling
    let CONNECTION_TIMEOUT = 60.0
    let ACTIVE_MODE_READ_INTERVAL = 2.0
    let ACTIVE_MODE_FALLBACK_AFTER = 10.0
    // Lost-signal fix: away reason of a device whose signal timed out (also passed to the user's script)
    let LOST_REASON = "lost"
    var centralMgr : CBCentralManager!
    // Classic monitoring: keyed by DeviceID (BLE UUID or Classic MAC)
    var devices: [DeviceID: Device] = [:]
    var delegate: BLEDelegate?
    var scanMode = false
    // Multi-device: state per monitored device; `presence` is the aggregate "unlock allowed" result
    var monitoredStates: [DeviceID: MonitoredDeviceState] = [:]
    var monitoredIDs: Set<DeviceID> {
        return Set(monitoredStates.keys)
    }
    var unlockLogic: DeviceLogic = .all {
        didSet { reevaluatePresence() }
    }
    var lockLogic: DeviceLogic = .any {
        didSet { reevaluatePresence() }
    }
    var presence = false
    // Review fix: last live Unlock When result, to report "close" on its rising edge (see reevaluatePresence)
    var wasUnlockAllowed = false
    // Device list: paired classic Bluetooth devices, name → major device class, refreshed lazily
    let PAIRED_DEVICES_REFRESH_INTERVAL = 5.0
    var pairedClassByName: [String: UInt32] = [:]
    // Device list: names of paired devices connected to this Mac, refreshed with pairedClassByName
    var connectedPairedNames: Set<String> = []
    // Pairing prompt fix: Apple company ID (little endian) leading the manufacturer data
    let APPLE_COMPANY_ID: [UInt8] = [0x4C, 0x00]
    // Pairing prompt fix: prefs key and cap of the UUIDs/names already connected for their info
    let INFO_TRIED_DEVICES_KEY = "infoTriedDevices"
    let MAX_INFO_TRIED_DEVICES = 500
    var pairedDevicesReadAt = 0.0
    var lockRSSI = -80
    var unlockRSSI = -60
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var powerWarn = true
    var passiveMode = false
    var thresholdRSSI = -70
    var latestN: Int = 5

    // Multi-device: scanning may stop only when a single monitored device is served by active mode
    var isSoleDeviceActive: Bool {
        return monitoredStates.count == 1 && monitoredStates.values.first?.activeModeTimer != nil
    }

    // Multi-device: timers that keep firing while a menu is open
    func commonModeTimer(_ interval: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func scanForPeripherals() {
        guard !centralMgr.isScanning else { return }
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        //print("Start scanning")
    }

    func startScanning() {
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        scanMode = false
        if isSoleDeviceActive {
            centralMgr.stopScan()
        }
    }

    // Multi-device: leave active mode on every monitored device
    func setPassiveMode(_ mode: Bool) {
        passiveMode = mode
        if passiveMode {
            for state in monitoredStates.values {
                state.activeModeTimer?.invalidate()
                state.activeModeTimer = nil
                if let p = state.peripheral {
                    centralMgr.cancelPeripheralConnection(p)
                }
            }
        }
        scanForPeripherals()
    }

    // Multi-device: sync monitored states with `ids`, keeping states of devices still monitored
    // Classic monitoring: ids are DeviceIDs
    func startMonitor(ids: Set<DeviceID>) {
        for (id, state) in monitoredStates where !ids.contains(id) {
            state.invalidateTimers()
            if let p = state.peripheral {
                centralMgr.cancelPeripheralConnection(p)
            }
            monitoredStates.removeValue(forKey: id)
        }
        for id in ids where monitoredStates[id] == nil {
            let state = MonitoredDeviceState(id: id)
            monitoredStates[id] = state
            resetSignalTimer(state: state)
        }
        guard !monitoredStates.isEmpty else {
            presence = false
            wasUnlockAllowed = false
            return
        }
        reevaluatePresence()
        scanForPeripherals()
    }

    // Review fix: unseen devices hold off locking but never allow unlocking (see DevicePresence)
    func aggregateDecision(_ states: [MonitoredDeviceState]) -> AggregateDecision {
        // Lost-signal fix: a device absent through signal timeout is passed as lost (see aggregatePresence)
        let devices = states.map {
            DevicePresence(isPresent: $0.presence, hasBeenClose: $0.hasBeenClose,
                           isLost: !$0.presence && $0.awayReason == LOST_REASON)
        }
        return aggregatePresence(devices, unlockLogic: unlockLogic, lockLogic: lockLogic)
    }

    // Multi-device: live unlock decision; `presence` is sticky and may lag behind the Unlock When rule
    var isUnlockAllowed: Bool {
        return aggregateDecision(Array(monitoredStates.values)).shouldUnlock
    }

    // Review fix: live Lock When result; unlike `presence` it doesn't wait for a device to come close
    var isLockDue: Bool {
        return aggregateDecision(Array(monitoredStates.values)).shouldLock
    }

    // Multi-device: report only aggregate changes; lock wins on conflict (see aggregatePresence).
    // Review fix: a device that just left (`departed`) reports a lock even when `presence` is already
    // false, so Lock When = Any re-locks after the user unlocked by password following an earlier lock.
    // Review fix: the rising edge of Unlock When reports "close" even while `presence` is still true
    // (Unlock All + Lock All: one device left without a lock and came back); once per transition.
    func reevaluatePresence(departed: MonitoredDeviceState? = nil) {
        guard !monitoredStates.isEmpty else { return }
        let states = Array(monitoredStates.values)
        let decision = aggregateDecision(states)
        let isUnlockRisingEdge = decision.shouldUnlock && !wasUnlockAllowed
        wasUnlockAllowed = decision.shouldUnlock
        // Lost-signal fix: a device going lost is no departure that re-locks, and never names the lock reason
        let lockingDeparture = departed.flatMap { $0.awayReason == LOST_REASON ? nil : $0 }
        if decision.shouldLock && (presence || lockingDeparture != nil) {
            presence = false
            let awayState = states.first { !$0.presence && $0.awayReason != LOST_REASON }
            let reason = lockingDeparture?.awayReason ?? awayState?.awayReason ?? "away"
            delegate?.updatePresence(presence: presence, reason: reason)
        } else if decision.shouldUnlock && (!presence || isUnlockRisingEdge) {
            presence = true
            delegate?.updatePresence(presence: presence, reason: "close")
        }
        let strongestRSSI = states.compactMap { $0.lastRSSI }.max()
        delegate?.updateRSSI(rssi: strongestRSSI, active: states.contains { $0.activeModeTimer != nil })
    }

    // Device list: major class of the paired classic Bluetooth device with this name, if any.
    // ponytail: matched by name only; two paired devices with one name share the first one's class
    func pairedClassMajor(name: String) -> UInt32? {
        refreshPairedDevicesIfStale()
        return pairedClassByName[name]
    }

    // Device list: true when a paired device with this name is currently connected to this Mac
    // ponytail: matched by name only, like pairedClassMajor
    func isPairedDeviceConnected(name: String) -> Bool {
        refreshPairedDevicesIfStale()
        return connectedPairedNames.contains(name)
    }

    // Device list: reads paired devices (class, connection state) at most once per refresh interval
    func refreshPairedDevicesIfStale() {
        let now = Date().timeIntervalSince1970
        guard now - pairedDevicesReadAt >= PAIRED_DEVICES_REFRESH_INTERVAL else { return }
        pairedDevicesReadAt = now
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let entries = paired.compactMap { device -> (String, UInt32)? in
            guard let pairedName = device.name else { return nil }
            return (pairedName, device.deviceClassMajor)
        }
        pairedClassByName = Dictionary(entries, uniquingKeysWith: { first, _ in first })
        connectedPairedNames = Set(paired.filter { $0.isConnected() }.compactMap { $0.name })
    }

    // Multi-device: monitored devices currently present with a signal
    func monitoredDetectedCount() -> Int {
        return monitoredStates.values.filter { $0.presence && $0.lastRSSI != nil }.count
    }

    // Multi-device: find the state of a monitored peripheral, attaching the peripheral on first sight
    func monitoredState(for peripheral: CBPeripheral) -> MonitoredDeviceState? {
        // Classic monitoring: states are keyed by DeviceID
        guard let state = monitoredStates[peripheral.deviceID] else { return nil }
        if state.peripheral == nil {
            state.peripheral = peripheral
        }
        return state
    }

    // Review fix: only a present → away transition counts as the device leaving
    func markAway(state: MonitoredDeviceState, reason: String) {
        let wasPresent = state.presence
        state.presence = false
        state.awayReason = reason
        reevaluatePresence(departed: wasPresent ? state : nil)
    }

    func resetSignalTimer(state: MonitoredDeviceState) {
        state.signalTimer?.invalidate()
        state.signalTimer = commonModeTimer(signalTimeout, repeats: false) { _ in
            print("Device is lost")
            state.lastRSSI = nil
            // Review fix: an "away" device must not turn "lost" (lost doesn't lock while another device is near)
            let reason = awayReasonOnSignalLoss(isPresent: state.presence, currentReason: state.awayReason,
                                                lostReason: self.LOST_REASON)
            self.markAway(state: state, reason: reason)
        }
    }

    // Multi-device: power-off marks every device absent; no lock is triggered (unchanged behaviour)
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            if !isSoleDeviceActive {
                scanForPeripherals()
            }
            powerWarn = false
        case .poweredOff:
            print("Bluetooth powered off")
            presence = false
            for state in monitoredStates.values {
                state.presence = false
                state.signalTimer?.invalidate()
                state.signalTimer = nil
            }
            if powerWarn {
                powerWarn = false
                delegate?.bluetoothPowerWarn()
            }
        default:
            break
        }
    }
    
    func getEstimatedRSSI(state: MonitoredDeviceState, rssi: Int) -> Int {
        if state.latestRSSIs.count >= latestN {
            state.latestRSSIs.removeFirst()
        }
        state.latestRSSIs.append(Double(rssi))
        var mean: Double = 0.0
        var sddev: Double = 0.0
        vDSP_normalizeD(state.latestRSSIs, 1, nil, 1, &mean, &sddev, vDSP_Length(state.latestRSSIs.count))
        return Int(mean)
    }

    // Multi-device: per-device thresholds as before, then the aggregate decides what to report
    func updateMonitored(state: MonitoredDeviceState, rssi: Int) {
        // Review fix: a sighting within unlock range also makes the device eligible for unlocking
        if rssi >= (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI) {
            state.hasBeenClose = true
            if !state.presence {
                print("Device is close")
                state.presence = true
                state.latestRSSIs.removeAll() // Avoid bouncing
            }
        }

        let estimatedRSSI = getEstimatedRSSI(state: state, rssi: rssi)
        state.lastRSSI = estimatedRSSI

        if estimatedRSSI >= (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) {
            if let timer = state.proximityTimer {
                timer.invalidate()
                print("Proximity timer canceled")
                state.proximityTimer = nil
            }
        } else if state.presence && state.proximityTimer == nil {
            state.proximityTimer = commonModeTimer(proximityTimeout, repeats: false) { _ in
                print("Device is away")
                state.proximityTimer = nil
                self.markAway(state: state, reason: "away")
            }
            print("Proximity timer started")
        }
        resetSignalTimer(state: state)
        reevaluatePresence()
    }

    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            self.delegate?.removeDevice(device: device)
            // Review fix: a stale scan row must not drop a monitored device's active-mode connection
            // (passive mode holds no connections, so always release there)
            // Classic monitoring: keyed by DeviceID
            if let p = device.peripheral, self.monitoredStates[device.id] == nil || self.passiveMode {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            self.devices.removeValue(forKey: device.id)
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func connectMonitored(state: MonitoredDeviceState) {
        guard let p = state.peripheral else { return }

        // Idk why but this works like a charm when 'didConnect' won't get called.
        // However, this generates warnings in the log.
        p.readRSSI()

        guard p.state == .disconnected else { return }
        print("Connecting")
        centralMgr.connect(p, options: nil)
        state.connectionTimer?.invalidate()
        state.connectionTimer = commonModeTimer(CONNECTION_TIMEOUT, repeats: false) { _ in
            if p.state == .connecting {
                print("Connection timeout")
                self.centralMgr.cancelPeripheralConnection(p)
            }
        }
    }

    // Naming: read model (Device Information) and GAP name; see finishInfoReadIfDone
    func discoverInfoServices(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(Array(InfoCharacteristics.keys))
    }

    // Naming: once every info read has finished or failed, drop the connection of an unmonitored device
    // (absent services/characteristics count as finished, so connections are never held forever)
    func finishInfoReadIfDone(_ peripheral: CBPeripheral) {
        // Classic monitoring: keyed by DeviceID
        guard let device = devices[peripheral.deviceID], device.pendingInfoReads.isEmpty else { return }
        device.hasReadInfo = true
        // Review fix: passive mode keeps no connection to monitored devices either
        if monitoredStates[peripheral.deviceID] == nil || passiveMode {
            centralMgr.cancelPeripheralConnection(peripheral)
        }
    }

    // Pairing prompt fix: reading info from some non-Apple devices (e.g. Xiaomi watches) makes macOS show a
    // "Connection Request" pairing dialog. Apple devices are always read (their model drives grouping);
    // any other device is connected at most once, remembered across launches by UUID and advertised name
    // (random-address devices come back under a new UUID with the same name).
    func shouldConnectForInfo(_ device: Device) -> Bool {
        if let adv = device.advData, adv.starts(with: APPLE_COMPANY_ID) { return true }
        // Classic monitoring: key by the pref string of the device id
        let keys = [device.id.prefString] + [device.advertisedName].compactMap { $0 }.filter { !isGenericDeviceName($0) }
        let tried = UserDefaults.standard.stringArray(forKey: INFO_TRIED_DEVICES_KEY) ?? []
        guard Set(tried).isDisjoint(with: keys) else { return false }
        // ponytail: oldest entries dropped past the cap; a long-forgotten device may prompt once more
        UserDefaults.standard.set(Array((tried + keys).suffix(MAX_INFO_TRIED_DEVICES)), forKey: INFO_TRIED_DEVICES_KEY)
        return true
    }

    // Naming: keep the last non-blank advertised local name (not every packet carries it)
    func storeAdvertisedName(_ advertisementData: [String : Any], on device: Device) {
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        device.advertisedName = name
    }

    //MARK:- CBCentralManagerDelegate start

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        // Multi-device: every monitored device is tracked from advertisements until it enters active mode
        if let state = monitoredState(for: peripheral), state.activeModeTimer == nil {
            //print("Discover \(rssi)dBm")
            updateMonitored(state: state, rssi: rssi)
            if !passiveMode {
                connectMonitored(state: state)
            }
        }

        if (scanMode) {
            if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == ExposureNotification {
                        //print("Device \(peripheral.identifier) Exposure Notification")
                        return
                    }
                }
            }
            // Classic monitoring: keyed by DeviceID
            let dev = devices[peripheral.deviceID]
            var device: Device
            if (dev == nil) {
                device = Device(id: peripheral.deviceID)
                storeAdvertisedName(advertisementData, on: device)
                if (rssi >= thresholdRSSI) {
                    device.peripheral = peripheral
                    device.rssi = rssi
                    device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                    devices[peripheral.deviceID] = device
                    // Naming: an already connected peripheral (monitored, active mode) gets no new didConnect
                    // Pairing prompt fix: a non-Apple device is connected for its info only once, ever
                    if peripheral.state == .connected {
                        discoverInfoServices(peripheral)
                    } else if shouldConnectForInfo(device) {
                        central.connect(peripheral, options: nil)
                    }
                    delegate?.newDevice(device: device)
                }
            } else {
                device = dev!
                device.rssi = rssi
                storeAdvertisedName(advertisementData, on: device)
                delegate?.updateDevice(device: device)
            }
            resetScanTimer(device: device)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        // Naming: also read info of a listed device whose read never finished (e.g. connected by active mode)
        // Classic monitoring: keyed by DeviceID
        if scanMode || devices[peripheral.deviceID]?.hasReadInfo == false {
            discoverInfoServices(peripheral)
        }
        // Multi-device: match the connected peripheral to its monitored state
        if let state = monitoredState(for: peripheral), !passiveMode {
            print("Connected")
            state.connectionTimer?.invalidate()
            state.connectionTimer = nil
            peripheral.readRSSI()
        }
    }

    //MARK:CBCentralManagerDelegate end -
    
    //MARK:- CBPeripheralDelegate start

    // Multi-device: active mode per device; scanning keeps running while other devices need advertisements
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let state = monitoredState(for: peripheral) else { return }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        //print("readRSSI \(rssi)dBm")
        updateMonitored(state: state, rssi: rssi)
        state.lastReadAt = Date().timeIntervalSince1970

        guard state.activeModeTimer == nil && !passiveMode else { return }
        print("Entering active mode")
        state.activeModeTimer = commonModeTimer(ACTIVE_MODE_READ_INTERVAL, repeats: true) { _ in
            if Date().timeIntervalSince1970 > state.lastReadAt + self.ACTIVE_MODE_FALLBACK_AFTER {
                print("Falling back to passive mode")
                self.centralMgr.cancelPeripheralConnection(peripheral)
                state.activeModeTimer?.invalidate()
                state.activeModeTimer = nil
                self.scanForPeripherals()
            } else if peripheral.state == .connected {
                peripheral.readRSSI()
            } else {
                self.connectMonitored(state: state)
            }
        }
        if !scanMode && isSoleDeviceActive {
            centralMgr.stopScan()
        }
    }

    // Naming: track which info services still need their characteristics discovered
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        let services = (peripheral.services ?? []).filter { InfoCharacteristics[$0.uuid] != nil }
        // Classic monitoring: keyed by DeviceID
        devices[peripheral.deviceID]?.pendingInfoReads = Set(services.map { $0.uuid })
        for service in services {
            peripheral.discoverCharacteristics(InfoCharacteristics[service.uuid], for: service)
        }
        finishInfoReadIfDone(peripheral)
    }

    // Naming: the service is done; its wanted characteristics become pending reads
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        let wanted = InfoCharacteristics[service.uuid] ?? []
        let chars = (service.characteristics ?? []).filter { wanted.contains($0.uuid) }
        // Classic monitoring: keyed by DeviceID
        if let device = devices[peripheral.deviceID] {
            device.pendingInfoReads.remove(service.uuid)
            device.pendingInfoReads.formUnion(chars.map { $0.uuid })
        }
        for chara in chars {
            peripheral.readValue(for: chara)
        }
        finishInfoReadIfDone(peripheral)
    }

    // Naming: store manufacturer / model / GAP name; a failed read still completes it
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        // Classic monitoring: keyed by DeviceID
        guard let device = devices[peripheral.deviceID] else { return }
        device.pendingInfoReads.remove(characteristic.uuid)
        if error == nil, let value = characteristic.value, let str = String(data: value, encoding: .utf8) {
            switch characteristic.uuid {
            case ManufacturerName:
                device.manufacture = str
                delegate?.updateDevice(device: device)
            case ModelName:
                device.model = str
                delegate?.updateDevice(device: device)
            case DeviceNameCharacteristic:
                device.gattName = str
                delegate?.updateDevice(device: device)
            default:
                break
            }
        }
        finishInfoReadIfDone(peripheral)
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        discoverInfoServices(peripheral)
    }
    //MARK:CBPeripheralDelegate end -

    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }
}
