import XCTest
@testable import SaberCore

final class CaseMotionTests: XCTestCase {
    /// Feeds an accelerometer row and a gyro row 20 ms apart, the way the helper streams them.
    private struct Feeder {
        var stamp = 1_000_000.0
        mutating func sample(_ o: CaseOrientation, g: Vec3, w: Vec3) {
            stamp += 20_000
            o.feed(CaseMotionRow(sensor: .accelerometer, stamp: stamp, host: stamp / 1e6, raw: g))
            o.feed(CaseMotionRow(sensor: .gyro, stamp: stamp + 3759, host: stamp / 1e6, raw: w))
        }
    }

    func testParsesHelperRows() {
        let row = CaseMotionRow(line: "17,12,1000000,123.5,100000,-50000,0")
        XCTAssertEqual(row?.sensor, .gyro)
        XCTAssertEqual(row?.raw.x ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(row?.raw.y ?? 0, -0.5, accuracy: 1e-12)
        XCTAssertNil(CaseMotionRow(line: "1,13,1000000,1,0,0,0"), "unknown sensors are skipped")
        XCTAssertNil(CaseMotionRow(line: "1,11,1000000,1,0,0"), "short rows are rejected")

        var buffer = CaseMotionLineBuffer()
        XCTAssertEqual(buffer.append(Data("1,11,1000000,1,0,0,100000\n2,12,10".utf8)).count, 1)
        XCTAssertEqual(buffer.append(Data("00010,1,0,0,0\n".utf8)).count, 1, "a split line completes on the next read")
    }

    func testIntegratesAKnownTurn() {
        let o = CaseOrientation()
        var f = Feeder()
        XCTAssertTrue(o.needsFirstOffset)
        for _ in 0..<110 { f.sample(o, g: Vec3(0, 0, 1), w: Vec3(0.8, -0.3, 0.4)) }
        XCTAssertTrue(o.ready, "a still stretch measures the first offset")
        XCTAssertEqual((o.bias - Vec3(0.8, -0.3, 0.4)).length, 0, accuracy: 1e-6)
        // 30 °/s about z for one second, on top of the offset.
        for _ in 0..<50 { f.sample(o, g: Vec3(0, 0, 1), w: Vec3(0.8, -0.3, 30.4)) }
        XCTAssertEqual(degrees(o.q.angle), 30, accuracy: 0.05)
        XCTAssertEqual(o.q.axis.z, 1, accuracy: 1e-3)
    }

    func testSavedOffsetSkipsTheWait() {
        let o = CaseOrientation(seedBias: Vec3(0.5, 0.7, -0.2))
        var f = Feeder()
        XCTAssertFalse(o.needsFirstOffset)
        f.sample(o, g: Vec3(0, 0, 1), w: Vec3(0.5, 0.7, -0.2))
        XCTAssertTrue(o.ready)
        XCTAssertTrue(o.seedUsed)
    }

    func testDropsHoldThePoseAndKeepTheFrame() {
        let o = CaseOrientation()
        var f = Feeder()
        for _ in 0..<110 { f.sample(o, g: Vec3(0, 0, 1), w: .zero) }
        let generation = o.generation
        f.stamp += 3_000_000 // a 3 s gap
        for _ in 0..<50 { f.sample(o, g: Vec3(0, 0, 1), w: Vec3(0, 0, 30)) }
        XCTAssertEqual(o.generation, generation, "the reference frame survives a drop, so calibration stays valid")
        XCTAssertEqual(degrees(o.q.angle), 29.4, accuracy: 0.2, "the first sample after the gap isn't integrated across it")
    }

    func testGravityCorrectionPullsTiltBack() {
        let o = CaseOrientation()
        var f = Feeder()
        for _ in 0..<110 { f.sample(o, g: Vec3(0, 0, 1), w: .zero) }
        // An uncorrected gyro offset of 2 °/s about x for 10 s would tilt 20°; gravity says level.
        for _ in 0..<500 { f.sample(o, g: Vec3(0, 0, 1), w: Vec3(2, 0, 0)) }
        XCTAssertLessThan(degrees(o.q.angle), 5)
    }

    func testSampleFeedsSaberCalibration() {
        // Pointing at the screen, then raising the case 90° about its x axis to the ceiling.
        let o = CaseOrientation()
        var f = Feeder()
        for _ in 0..<110 { f.sample(o, g: Vec3(0, 0, 1), w: .zero) }
        let center = (0..<10).compactMap { _ -> MotionSample? in f.sample(o, g: Vec3(0, 0, 1), w: .zero); return o.sample(time: 0) }
        // Turn about x at 90 °/s for one second while the accelerometer follows.
        for i in 1...50 {
            let a = radians(90 * Double(i) / 50)
            f.sample(o, g: Vec3(0, sin(a), cos(a)), w: Vec3(90, 0, 0))
        }
        let up = (0..<10).compactMap { _ -> MotionSample? in f.sample(o, g: Vec3(0, 1, 0), w: .zero); return o.sample(time: 0) }
        guard case .success(let cal) = SaberCalibration.solve(center: center, up: up) else { return XCTFail("calibration should solve") }
        XCTAssertTrue(cal.deviceToWorld)
        let ahead = cal.direction(for: center.last!.attitude)
        XCTAssertEqual(ahead.z, -1, accuracy: 0.05)
        let raised = cal.direction(for: up.last!.attitude)
        XCTAssertEqual(raised.y, 1, accuracy: 0.05)
    }

    func testLidFollowsPairedInCaseReports() {
        func lid(_ t: [(Double, Int, Int)]) -> Bool { CaseLid.isClosed(t.map { CaseLid.Report(uptime: $0.0, primary: $0.1, secondary: $0.2) }) }
        let closedOnce: [(Double, Int, Int)] = [(0, 2, 2), (4.6, 2, 2), (4.7, 2, 2)]
        let closedTwice: [(Double, Int, Int)] = [(0, 2, 2), (1.1, 2, 2), (1.2, 2, 2), (2.3, 2, 2), (2.4, 2, 2), (12.8, 2, 2), (12.9, 2, 2), (16.7, 2, 3)]
        let budLifted: [(Double, Int, Int)] = [(0, 2, 2), (2.8, 1, 2), (2.9, 1, 2), (3.1, 2, 2), (4.7, 2, 2), (4.7, 2, 2), (8.7, 2, 3)]
        XCTAssertFalse(lid([]))
        XCTAssertFalse(lid(Array(closedOnce.prefix(2))))
        XCTAssertTrue(lid(closedOnce))
        XCTAssertFalse(lid([(0, 2, 2), (4.6, 2, 2), (5.4, 2, 2)]))
        XCTAssertTrue(lid(Array(closedTwice.prefix(3))))
        XCTAssertFalse(lid(Array(closedTwice.prefix(5))))
        XCTAssertTrue(lid(closedTwice))
        XCTAssertFalse(lid(Array(budLifted.prefix(5))))
        XCTAssertTrue(lid(Array(budLifted.prefix(6))))
        XCTAssertTrue(lid([(0, 2, 2), (9, 2, 3)]))

        let json = try! JSONSerialization.jsonObject(with: Data(#"[{"received_uptime":1.5,"primary_code":2,"secondary_code":2},{"primary_code":2}]"#.utf8))
        XCTAssertEqual(CaseLid.reports(json).count, 1)
    }

    func testLidBroadcast() {
        func frame(_ status: UInt8, _ lid: UInt8, model: [UInt8] = [0x27, 0x20], length: Int = 29) -> [UInt8] {
            Array(([0x4C, 0, 7, 0x19, 1] + model + [status, 0x99, 0x8F, lid, 0, 4] + [UInt8](repeating: 0, count: 16)).prefix(length))
        }
        XCTAssertEqual(CaseLid.isOpen(advertisement: frame(0x24, 0x11), productID: 0x2027), true)
        XCTAssertEqual(CaseLid.isOpen(advertisement: frame(0x24, 0x19), productID: 0x2027), false)
        XCTAssertNil(CaseLid.isOpen(advertisement: frame(0x02, 0x11), productID: 0x2027), "no earbud in the case")
        XCTAssertNil(CaseLid.isOpen(advertisement: frame(0x24, 0x11, model: [0x14, 0x20]), productID: 0x2027), "another model")
        XCTAssertNil(CaseLid.isOpen(advertisement: frame(0x24, 0x11, length: 27), productID: 0x2027))
    }

    func testFindsAirPodsByProductID() throws {
        let listing: [String: Any] = ["SPBluetoothDataType": [[
            "controller_properties": ["controller_state": "attrib_on"],
            "device_connected": [["Test AirPods Pro": ["device_vendorID": "0x004C", "device_productID": "0x2027", "device_address": "0a-1b-2c-3d-4e-5f"]],
                                 ["Keyboard": ["device_vendorID": "0x3434", "device_productID": "0x2027", "device_address": "0A:1B:2C:3D:4E:61"]]],
            "device_not_connected": [["Spare AirPods Pro": ["device_vendorID": "0x004C", "device_productID": "0x2024", "device_address": "0A:1B:2C:3D:4E:62"]],
                                     ["AirPods": ["device_vendorID": "0x004C", "device_productID": "0x2002", "device_address": "0A:1B:2C:3D:4E:63"]]]]]]
        let survey = try XCTUnwrap(CaseAirPods.parse(try JSONSerialization.data(withJSONObject: listing)))
        XCTAssertEqual(survey.pairs.map(\.address), ["0A:1B:2C:3D:4E:5F", "0A:1B:2C:3D:4E:62"])
        XCTAssertEqual(survey.pairs[0].productID, 0x2027)
        XCTAssertEqual(survey.pairs[1].title, "Spare AirPods Pro · AirPods Pro 2")
        XCTAssertEqual(CaseAirPods.choose(survey, saved: "0a:1b:2c:3d:4e:62"), .chosen(survey.pairs[1]))
        XCTAssertEqual(CaseAirPods.choose(survey, saved: nil), .chosen(survey.pairs[0]), "the only connected pair")
        XCTAssertEqual(CaseAirPods.choose(.init(poweredOn: true, pairs: []), saved: nil), .missing)
        XCTAssertEqual(CaseAirPods.choose(.init(poweredOn: false, pairs: survey.pairs), saved: nil), .bluetoothOff)
        XCTAssertEqual(CaseAirPods.choose(nil, saved: nil), .unreadable)
    }

    func testHelperExitWording() {
        XCTAssertNil(CaseHelperExit.helperFailure(0, stopping: false))
        XCTAssertNil(CaseHelperExit.helperFailure(52, stopping: true))
        XCTAssertNotNil(CaseHelperExit.helperFailure(52, stopping: false))
        let codes: [Int32] = [2, 3, 10, 12, 20, 21, 22, 23, 24, 25, 26, 27, 28, 30, 31, 32, 34, 35, 36, 40, 41, 42, 43, 44, 45, 50, 51, 52, 53]
        XCTAssertEqual(Set(codes.compactMap { CaseHelperExit.helperFailure($0, stopping: false) }).count, codes.count)
        XCTAssertTrue(CaseHelperExit.lostContact(43))
        XCTAssertFalse(CaseHelperExit.lostContact(30))
    }
}
