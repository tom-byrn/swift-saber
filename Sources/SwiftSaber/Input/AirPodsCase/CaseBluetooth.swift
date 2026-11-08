import Foundation
import CoreBluetooth
import SaberCore

// Bluetooth plumbing for the closed-case saber, after AirPointer's ClosedCaseAirPods.swift
// (github.com/musubipapi/airpointer, MIT License, Copyright (c) 2026 Andy Gao).

enum CaseFiles {
    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SwiftSaber", isDirectory: true)
        .appendingPathComponent("AirPodsCase", isDirectory: true)
    /// The AirPods to use (their Bluetooth address). Never logged.
    static let target = folder.appendingPathComponent("target.txt")
    /// The gyro's resting offset, so a later connection needn't wait for the case to sit still.
    static let sensorOffset = folder.appendingPathComponent("sensor-offset.json")
    static let sessions = folder.appendingPathComponent("Sessions", isDirectory: true)

    static var savedTarget: String? {
        (try? String(contentsOf: target, encoding: .utf8)).map(CaseAirPods.normalized)
    }

    static func save(target pair: CaseAirPods) throws {
        guard savedTarget != pair.address else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(pair.address.utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// A saved offset for these AirPods, if it's under a week old.
    static func loadOffset(for address: String) -> Vec3? {
        guard let data = try? Data(contentsOf: sensorOffset),
              let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              v["address"] as? String == address,
              let time = v["updated_unix"] as? Double, (0..<7 * 86400).contains(Date().timeIntervalSince1970 - time),
              let b = v["bias"] as? [Double], b.count == 3 else { return nil }
        return Vec3(b[0], b[1], b[2])
    }

    static func saveOffset(_ bias: Vec3, for address: String) {
        let value: [String: Any] = ["address": address, "bias": [bias.x, bias.y, bias.z], "updated_unix": Date().timeIntervalSince1970]
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: value) {
                try? data.write(to: sensorOffset, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sensorOffset.path)
            }
        }
    }

    /// Keeps the newest `count` session folders.
    static func pruneSessions(keeping count: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return }
        func created(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        let folders = entries.filter { UUID(uuidString: $0.lastPathComponent) != nil }
        for f in folders.sorted(by: { created($0) > created($1) }).dropFirst(max(0, count)) { try? fm.removeItem(at: f) }
    }
}

enum CaseSurvey {
    /// Asks `system_profiler` on a utility queue and answers on the main queue; nil when it couldn't be read.
    static func run(completion: @escaping (CaseAirPods.Survey?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = toolOutput("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 20).flatMap(CaseAirPods.parse)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// A system tool's output, or nil if it fails or outlasts the timeout.
    static func toolOutput(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        var data = Data()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        return process.terminationStatus == 0 ? data : nil
    }
}

/// Asks for Bluetooth when the player first connects the case, so the system prompt makes sense.
final class CaseBluetoothAccess: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var waiting: [(Bool) -> Void] = []
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")

    static var allowed: Bool { CBManager.authorization == .allowedAlways }

    func request(_ completion: @escaping (Bool) -> Void) {
        switch CBManager.authorization {
        case .allowedAlways: completion(true)
        case .notDetermined:
            waiting.append(completion)
            if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
        default: completion(false)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        let allowed = CBManager.authorization == .allowedAlways, answers = waiting
        waiting = []
        manager = nil
        for answer in answers { answer(allowed) }
    }
}

/// Waits for the lid to open by listening for the AirPods' own proximity broadcast (the one
/// that shows the battery card on an iPhone). Runs only while a connection waits for the lid.
final class CaseLidWatcher: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var opened: (() -> Void)?
    private let productID: UInt16
    private var lastOpen: [UUID: Double] = [:]

    init(productID: UInt16, opened: @escaping () -> Void) {
        self.productID = productID
        self.opened = opened
    }

    func start() { manager = CBCentralManager(delegate: self, queue: .main) }

    func stop() {
        manager?.stopScan()
        manager?.delegate = nil
        manager = nil
        opened = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let open = CaseLid.isOpen(advertisement: [UInt8](data), productID: productID) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Only AirPods paired with this Mac carry a name.
        guard peripheral.name != nil, open else { lastOpen[peripheral.identifier] = nil; return }
        // Two open frames within two seconds, so one stray frame can't start a connection.
        if let previous = lastOpen[peripheral.identifier], now - previous <= 2 {
            let fire = opened
            opened = nil
            fire?()
            return
        }
        lastOpen[peripheral.identifier] = now
    }
}
