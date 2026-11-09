import Foundation
import SaberCore

/// Identifies one motion stream in the `InputHub`.
/// AirPods tag each sample with the bud that produced it (left / right); every other device
/// gets a slot of its own.
enum StreamID: Int, Codable, CaseIterable, Comparable {
    case unknown = 0
    case left = 1
    case right = 2
    /// The first iPhone / iPad running the Swift Saber app.
    case phone = 3
    /// An AirPod's motion read while it sits in the closed charging case (see `AirPodsCaseSession`).
    case airPodCase = 4
    /// A second iPhone / iPad.
    case phone2 = 5
    /// Game controllers with motion sensors (DualSense, DualShock 4, Joy-Con…).
    case controller1 = 6
    case controller2 = 7

    /// Generic name; `AppModel.deviceName(_:)` has the real device names.
    var label: String {
        switch self {
        case .unknown: return "AirPods"
        case .left: return "Left AirPod"
        case .right: return "Right AirPod"
        case .phone, .phone2: return "iPhone / iPad"
        case .airPodCase: return "AirPods Case"
        case .controller1, .controller2: return "Controller"
        }
    }

    var isAirPod: Bool { device == .airPod || device == .airPodCase }
    var isPhone: Bool { self == .phone || self == .phone2 }
    var isController: Bool { self == .controller1 || self == .controller2 }
    static let airPods: [StreamID] = [.unknown, .left, .right, .airPodCase]
    static let phones: [StreamID] = [.phone, .phone2]
    static let controllers: [StreamID] = [.controller1, .controller2]

    /// The device this stream belongs to.
    var device: SaberDevice {
        switch self {
        case .unknown, .left, .right: return .airPod
        case .airPodCase: return .airPodCase
        case .phone: return .iOS1
        case .phone2: return .iOS2
        case .controller1: return .controller1
        case .controller2: return .controller2
        }
    }

    /// SF Symbol for this stream (`AppModel.deviceSymbol(_:)` knows iPhone from iPad).
    var symbol: String {
        switch self {
        case .phone, .phone2: return "iphone"
        case .airPodCase: return "airpodspro.chargingcase.wireless.fill"
        case .left: return "airpodpro.left"
        case .controller1, .controller2: return "gamecontroller.fill"
        default: return "airpodpro.right"
        }
    }

    static func < (a: StreamID, b: StreamID) -> Bool { a.rawValue < b.rawValue }
}

/// A physical thing that can drive one saber. AirPod buds hand their motion stream over to each
/// other, so all of them together are one device.
enum SaberDevice: String, CaseIterable, Hashable {
    case airPod, airPodCase, iOS1, iOS2, controller1, controller2, mouse

    /// The motion streams this device produces.
    var streams: [StreamID] {
        switch self {
        case .airPod: return [.unknown, .left, .right]
        case .airPodCase: return [.airPodCase]
        case .iOS1: return [.phone]
        case .iOS2: return [.phone2]
        case .controller1: return [.controller1]
        case .controller2: return [.controller2]
        case .mouse: return []
        }
    }

    /// How the `InputHub` reads this device.
    var source: SaberSource {
        switch self {
        case .airPod: return .anyAirPod
        case .airPodCase: return .stream(.airPodCase)
        case .iOS1: return .stream(.phone)
        case .iOS2: return .stream(.phone2)
        case .controller1: return .stream(.controller1)
        case .controller2: return .stream(.controller2)
        case .mouse: return .mouse
        }
    }

    var isAirPod: Bool { self == .airPod || self == .airPodCase }
    var isPhone: Bool { self == .iOS1 || self == .iOS2 }
    var isController: Bool { self == .controller1 || self == .controller2 }
    var needsCalibration: Bool { self != .mouse }
}

extension SaberSource {
    /// The device behind a hub source.
    var device: SaberDevice {
        switch self {
        case .anyAirPod: return .airPod
        case .mouse: return .mouse
        case .stream(let id): return id.device
        }
    }
}
