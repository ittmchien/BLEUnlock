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

// Review fix: a device not yet seen close since monitoring started counts as present for locking
// (no lock at launch) but not for unlocking (no password typed before any device was really seen)
struct DevicePresence {
    let isPresent: Bool
    let hasBeenClose: Bool

    var isNear: Bool {
        return isPresent && hasBeenClose
    }
}

// Multi-device: lock wins on conflict so a device leaving always locks when configured to
func aggregatePresence(_ devices: [DevicePresence], unlockLogic: DeviceLogic, lockLogic: DeviceLogic) -> AggregateDecision {
    guard !devices.isEmpty else { return AggregateDecision(shouldUnlock: false, shouldLock: false) }
    let shouldLock = lockLogic == .any ? devices.contains { !$0.isPresent } : !devices.contains { $0.isPresent }
    let wantsUnlock = unlockLogic == .any ? devices.contains { $0.isNear } : devices.allSatisfy { $0.isNear }
    return AggregateDecision(shouldUnlock: wantsUnlock && !shouldLock, shouldLock: shouldLock)
}

// Device list: group order in the Device submenu
enum DeviceCategory: Int, CaseIterable {
    case iphone, watch, airpods, ipad, mac, other
}

// Device list: Bluetooth Class of Device major classes (Assigned Numbers, "Major Device Classes")
enum BluetoothClassMajor {
    static let computer: UInt32 = 1
    static let phone: UInt32 = 2
    static let audio: UInt32 = 4
    static let wearable: UInt32 = 7
}

private let pairedClassCategories: [UInt32: DeviceCategory] = [
    BluetoothClassMajor.computer: .mac, BluetoothClassMajor.phone: .iphone,
    BluetoothClassMajor.audio: .airpods, BluetoothClassMajor.wearable: .watch,
]

// Device list: model id prefix first, then whole-word name keywords, then the paired device's major
// class (coarse: Computer also covers iPads and PCs, so it only decides when nothing more precise does)
func deviceCategory(model: String?, name: String, pairedClassMajor: UInt32? = nil) -> DeviceCategory {
    if let model = model {
        if model.hasPrefix("iPhone") { return .iphone }
        if model.hasPrefix("Watch") { return .watch }
        // Review fix: no "Audio" prefix, it matched HomePod (AudioAccessory*)
        if model.hasPrefix("AirPods") || model.hasPrefix("Beats") { return .airpods }
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
    return pairedClassMajor.flatMap { pairedClassCategories[$0] } ?? .other
}

private func containsWord(_ text: String, _ word: String) -> Bool {
    let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

// Device list: names that can't identify one device (never deduplicated)
private let genericDeviceNames: Set<String> = ["iPhone", "iPad", "Mac", "Apple Watch", "AirPods"]

func isGenericDeviceName(_ name: String) -> Bool {
    return genericDeviceNames.contains(name) || isUnnamedDeviceName(name)
}

// Device list: display name is only the UUID or MAC fallback (no real name known)
func isUnnamedDeviceName(_ name: String) -> Bool {
    if UUID(uuidString: name) != nil { return true }
    return name.range(of: "^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$", options: .regularExpression) != nil
}

// Naming: "<name> · <model> (<detail>)", model omitted when unknown or equal to the name;
// detail is "<rssi>dBm" for scanned rows, the not-detected status for missing monitored devices
func deviceRowTitle(name: String, modelName: String?, detail: String) -> String {
    guard let model = modelName, model != name else { return "\(name) (\(detail))" }
    return "\(name) · \(model) (\(detail))"
}
