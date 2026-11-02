// Self-check for DeviceLogic.swift. Run:
// swiftc BLEUnlock/DeviceLogic.swift checks/DeviceLogicCheck.swift -o /tmp/devicelogic-check && /tmp/devicelogic-check
import Foundation

func check(_ condition: Bool, _ label: String) {
    if !condition { print("FAIL: \(label)"); exit(1) }
}

// Review fix: presences of devices that were all seen close since monitoring started
func seenClose(_ presences: [Bool]) -> [DevicePresence] {
    return presences.map { DevicePresence(isPresent: $0, hasBeenClose: true) }
}

// Multi-file swiftc only allows top-level code in main.swift, so the checks run from @main
@main
enum DeviceLogicCheck {
    static func main() {
        // aggregatePresence (existing cases: every device already seen close)
        check(aggregatePresence([], unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: false), "empty → nothing")
        check(aggregatePresence(seenClose([true]), unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: true, shouldLock: false), "single present")
        check(aggregatePresence(seenClose([false]), unlockLogic: .any, lockLogic: .all) == AggregateDecision(shouldUnlock: false, shouldLock: true), "single away")
        check(aggregatePresence(seenClose([true, false]), unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: true), "AirPods left, phone stays, lock Any → lock")
        check(aggregatePresence(seenClose([true, false]), unlockLogic: .all, lockLogic: .all) == AggregateDecision(shouldUnlock: false, shouldLock: false), "lock All, one away → hold")
        check(aggregatePresence(seenClose([false, false]), unlockLogic: .all, lockLogic: .all) == AggregateDecision(shouldUnlock: false, shouldLock: true), "all away → lock")
        check(aggregatePresence(seenClose([true, true]), unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: true, shouldLock: false), "all near → unlock")
        check(aggregatePresence(seenClose([true, false]), unlockLogic: .any, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: true), "conflict → lock wins")
        check(aggregatePresence(seenClose([true, false]), unlockLogic: .any, lockLogic: .all) == AggregateDecision(shouldUnlock: true, shouldLock: false), "unlock Any, lock All, one near")

        // Review fix: a device not yet seen close holds off locking but never allows unlocking
        let unseen = DevicePresence(isPresent: true, hasBeenClose: false)
        let near = DevicePresence(isPresent: true, hasBeenClose: true)
        let away = DevicePresence(isPresent: false, hasBeenClose: true)
        check(aggregatePresence([unseen], unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: false), "launch, unseen → no unlock, no lock")
        check(aggregatePresence([unseen, unseen], unlockLogic: .any, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: false), "all unseen, unlock Any → no unlock")
        check(aggregatePresence([near, unseen], unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: false), "unlock All waits for unseen device")
        check(aggregatePresence([near, unseen], unlockLogic: .any, lockLogic: .any) == AggregateDecision(shouldUnlock: true, shouldLock: false), "unlock Any, one seen near")
        check(aggregatePresence([unseen, away], unlockLogic: .any, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: true), "lock Any, seen device away → lock")
        check(aggregatePresence([unseen, away], unlockLogic: .any, lockLogic: .all) == AggregateDecision(shouldUnlock: false, shouldLock: false), "lock All, unseen counts as present")

        // Lost-signal fix: a lost device (signal timeout, e.g. put in its case) never locks; only moving away does
        let lost = DevicePresence(isPresent: false, hasBeenClose: true, isLost: true)
        check(aggregatePresence([near, lost], unlockLogic: .any, lockLogic: .any) == AggregateDecision(shouldUnlock: true, shouldLock: false), "AirPods in case, phone near → no lock")
        check(aggregatePresence([lost, lost], unlockLogic: .any, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: false), "all lost, Any → no lock")
        check(aggregatePresence([lost], unlockLogic: .all, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: false), "sole device lost → no lock")
        check(aggregatePresence([lost], unlockLogic: .all, lockLogic: .all) == AggregateDecision(shouldUnlock: false, shouldLock: false), "sole device lost, All → no lock")
        check(aggregatePresence([away, lost], unlockLogic: .any, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: true), "one moved away → lock")
        check(aggregatePresence([away, lost], unlockLogic: .any, lockLogic: .all) == AggregateDecision(shouldUnlock: false, shouldLock: true), "All: one away, rest lost → lock")
        check(aggregatePresence([near, lost], unlockLogic: .any, lockLogic: .all) == AggregateDecision(shouldUnlock: true, shouldLock: false), "All: one near, one lost → no lock")
        check(aggregatePresence([unseen, lost], unlockLogic: .any, lockLogic: .any) == AggregateDecision(shouldUnlock: false, shouldLock: false), "unseen + lost → no lock")
        // Review fix: a device that moved away keeps "away" when its signal later times out (else it would
        // turn "lost", stop locking and let a nearby device unlock the Mac)
        check(awayReasonOnSignalLoss(isPresent: false, currentReason: "away", lostReason: "lost") == "away", "away then signal loss stays away")
        check(awayReasonOnSignalLoss(isPresent: true, currentReason: "away", lostReason: "lost") == "lost", "present then signal loss → lost")

        // deviceCategory
        check(deviceCategory(model: "iPhone15,2", name: "🍚🍳") == .iphone, "model iPhone")
        check(deviceCategory(model: "Watch6,1", name: "x") == .watch, "model Watch")
        check(deviceCategory(model: "iPad13,4", name: "x") == .ipad, "model iPad")
        check(deviceCategory(model: "MacBookPro18,3", name: "x") == .mac, "model MacBook")
        check(deviceCategory(model: "Mac14,2", name: "x") == .mac, "model Mac")
        check(deviceCategory(model: "iMac21,1", name: "x") == .mac, "model iMac")
        check(deviceCategory(model: "BeatsFitPro1,1", name: "x") == .airpods, "model Beats")
        check(deviceCategory(model: nil, name: "AirPods của Trứng") == .airpods, "name AirPods")
        check(deviceCategory(model: nil, name: "Beats Studio Buds") == .airpods, "name Beats")
        check(deviceCategory(model: nil, name: "Trứng's MacBook Pro") == .mac, "name MacBook")
        check(deviceCategory(model: nil, name: "Apple Watch của A") == .watch, "name Watch")
        check(deviceCategory(model: nil, name: "M236 LaserJet") == .other, "printer → other")
        check(deviceCategory(model: nil, name: "Machine") == .other, "Mac keyword needs word boundary")
        // Review fix: HomePod model ids (AudioAccessory*) are not AirPods
        check(deviceCategory(model: "AudioAccessory5,1", name: "HomePod") == .other, "HomePod → other")
        // Device list: paired classic Bluetooth major class (Computer 1, Phone 2, Audio 4, Wearable 7)
        check(deviceCategory(model: nil, name: "🍚🍳", pairedClassMajor: 2) == .iphone, "paired Phone → iPhone")
        check(deviceCategory(model: nil, name: "x", pairedClassMajor: 1) == .mac, "paired Computer → Mac")
        check(deviceCategory(model: nil, name: "x", pairedClassMajor: 4) == .airpods, "paired Audio → AirPods")
        check(deviceCategory(model: nil, name: "x", pairedClassMajor: 7) == .watch, "paired Wearable → Watch")
        check(deviceCategory(model: nil, name: "x", pairedClassMajor: 5) == .other, "paired Peripheral → other")
        check(deviceCategory(model: "iPad13,4", name: "x", pairedClassMajor: 1) == .ipad, "model beats paired class")
        check(deviceCategory(model: nil, name: "Trứng's iPad", pairedClassMajor: 1) == .ipad, "name keyword beats paired class")

        // isGenericDeviceName
        check(isGenericDeviceName("iPhone"), "iPhone generic")
        check(isGenericDeviceName("Mac"), "Mac generic")
        check(isGenericDeviceName("F0:2F:4B:00:95:90"), "MAC address generic")
        check(isGenericDeviceName("63B61A13-02BF-0CB1-D5FE-1D440735C645"), "UUID generic")
        check(!isGenericDeviceName("🍚🍳"), "custom name not generic")

        // isUnnamedDeviceName: UUID/MAC fallbacks only
        check(isUnnamedDeviceName("63B61A13-02BF-0CB1-D5FE-1D440735C645"), "UUID unnamed")
        check(isUnnamedDeviceName("F0:2F:4B:00:95:90"), "MAC unnamed")
        check(isUnnamedDeviceName("f0-2f-4b-00-95-90"), "dashed MAC unnamed")
        check(!isUnnamedDeviceName("iPhone"), "generic product name is a name")
        check(!isUnnamedDeviceName("🍚🍳"), "custom name is a name")

        // deviceRowTitle
        check(deviceRowTitle(name: "🍚🍳", modelName: "iPhone 14 Pro", detail: "-45dBm") == "🍚🍳 · iPhone 14 Pro (-45dBm)", "name + model")
        check(deviceRowTitle(name: "iPhone 14 Pro", modelName: "iPhone 14 Pro", detail: "-45dBm") == "iPhone 14 Pro (-45dBm)", "no duplicate model")
        check(deviceRowTitle(name: "M236 LaserJet", modelName: nil, detail: "-68dBm") == "M236 LaserJet (-68dBm)", "no model")
        // Device list: rows of missing monitored devices use the same title with a status detail
        check(deviceRowTitle(name: "🍚🍳", modelName: "iPhone 14 Pro", detail: "Signal not detected") == "🍚🍳 · iPhone 14 Pro (Signal not detected)", "missing row with model")
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
        print("DeviceLogic checks passed")
    }
}
