import XCTest
@testable import SaberCore

final class AttitudeEstimatorTests: XCTestCase {
    private let down = Vec3(0, 0, -1)

    func testStartsLevelWithGravity() {
        var e = AttitudeEstimator()
        // Tilted: gravity along the device's -y axis.
        e.update(rotationRate: .zero, acceleration: Vec3(0, -1, 0), time: 0)
        XCTAssertTrue(e.isInitialized)
        XCTAssertLessThan((e.gravity - Vec3(0, -1, 0)).length, 1e-9)
        XCTAssertLessThan((e.attitude.rotate(Vec3(0, -1, 0)) - down).length, 1e-9)
    }

    func testIntegratesRotation() {
        var e = AttitudeEstimator()
        e.correctionGain = 0
        e.biasGain = 0
        e.update(rotationRate: .zero, acceleration: down, time: 0)
        // 1 rad/s about the device's z (vertical) axis for π/2 seconds.
        var t = 0.0
        let dt = 0.01
        while t < .pi / 2 - 1e-9 {
            let step = min(dt, .pi / 2 - t)
            t += step
            e.update(rotationRate: Vec3(0, 0, 1), acceleration: down, time: t)
        }
        // The device's x axis now points along world y.
        let x = e.attitude.rotate(.unitX)
        XCTAssertEqual(x.y, 1, accuracy: 1e-6)
    }

    func testGravityCorrectsTiltDrift() {
        var e = AttitudeEstimator()
        e.update(rotationRate: .zero, acceleration: down, time: 0)
        // Start with a badly wrong tilt by spinning about x with the correction off…
        e.correctionGain = 0
        for i in 1...50 { e.update(rotationRate: Vec3(1, 0, 0), acceleration: down, time: Double(i) * 0.01) }
        XCTAssertGreaterThan(e.gravity.angle(to: down), radians(25))
        // …then hold still: gravity pulls it back.
        e.correctionGain = 1.5
        var t = 0.5
        for _ in 0..<800 {
            t += 0.01
            e.update(rotationRate: .zero, acceleration: down, time: t)
        }
        XCTAssertLessThan(e.gravity.angle(to: down), radians(1))
    }

    func testLearnsGyroBias() {
        var e = AttitudeEstimator()
        e.update(rotationRate: .zero, acceleration: Vec3(0, -1, 0), time: 0)
        // A still controller whose gyro reads a constant offset about a horizontal axis.
        let bias = Vec3(0.02, 0, 0)
        var t = 0.0
        for _ in 0..<6000 {
            t += 0.01
            e.update(rotationRate: bias, acceleration: Vec3(0, -1, 0), time: t)
        }
        XCTAssertLessThan(e.gyroBias.angle(to: bias), radians(15))
        XCTAssertLessThan(e.gravity.angle(to: Vec3(0, -1, 0)), radians(1))
    }

    func testCalibrationWorksWithEstimatedAttitude() {
        // A controller held pointing at the screen, then raised to the ceiling, through the
        // estimator, must calibrate like any other sensor.
        var e = AttitudeEstimator()
        e.update(rotationRate: .zero, acceleration: Vec3(0, -1, 0), time: 0)
        var t = 0.0
        var center: [MotionSample] = []
        for _ in 0..<40 {
            t += 0.01
            e.update(rotationRate: .zero, acceleration: Vec3(0, -1, 0), time: t)
            center.append(MotionSample(time: t, attitude: e.attitude, gravity: e.gravity))
        }
        // Raise by 80° about the device's x axis (true gravity follows the raise).
        let steps = 80
        for i in 1...steps {
            t += 0.01
            let angle = radians(80) * Double(i) / Double(steps)
            let g = Quat(axis: .unitX, angle: angle).conjugate.rotate(Vec3(0, -1, 0))
            e.update(rotationRate: Vec3(radians(80) / (Double(steps) * 0.01), 0, 0), acceleration: g, time: t)
        }
        let gUp = Quat(axis: .unitX, angle: radians(80)).conjugate.rotate(Vec3(0, -1, 0))
        var up: [MotionSample] = []
        for _ in 0..<40 {
            t += 0.01
            e.update(rotationRate: .zero, acceleration: gUp, time: t)
            up.append(MotionSample(time: t, attitude: e.attitude, gravity: e.gravity))
        }
        guard case .success(let cal) = SaberCalibration.solve(center: center, up: up) else {
            return XCTFail("calibration failed")
        }
        let atScreen = cal.direction(for: center.last!.attitude)
        XCTAssertLessThan(atScreen.angle(to: .forward), radians(3))
        let atCeiling = cal.direction(for: up.last!.attitude)
        XCTAssertGreaterThan(atCeiling.y, 0.9)
    }
}

final class SaberAssignmentTests: XCTestCase {
    func testOneDeviceTakesTheMainHand() {
        XCTAssertEqual(SaberAssignment.assign([SaberCandidate("phone")], primary: .left), [.left: "phone"])
        XCTAssertEqual(SaberAssignment.assign([SaberCandidate<String>](), primary: .left), [:])
    }

    func testTwoDevicesInOrder() {
        let a = SaberAssignment.assign([SaberCandidate("airpod"), SaberCandidate("ipad"), SaberCandidate("extra")], primary: .right)
        XCTAssertEqual(a, [.right: "airpod", .left: "ipad"])
        let swapped = SaberAssignment.assign([SaberCandidate("airpod"), SaberCandidate("ipad")], primary: .left)
        XCTAssertEqual(swapped, [.left: "airpod", .right: "ipad"])
    }

    func testDuplicatesAreIgnored() {
        let a = SaberAssignment.assign([SaberCandidate("a"), SaberCandidate("a"), SaberCandidate("b")], primary: .right)
        XCTAssertEqual(a, [.right: "a", .left: "b"])
    }

    func testJoyConPairGoesInMatchingHands() {
        let a = SaberAssignment.assign([SaberCandidate("R", preferredHand: .right), SaberCandidate("L", preferredHand: .left)],
                                       primary: .left)
        XCTAssertEqual(a, [.left: "L", .right: "R"])
        // Only one is one-handed: plain order wins.
        let b = SaberAssignment.assign([SaberCandidate("L", preferredHand: .left), SaberCandidate("pad")], primary: .right)
        XCTAssertEqual(b, [.right: "L", .left: "pad"])
    }

    func testControllerHandFromName() {
        XCTAssertEqual(SaberAssignment.preferredHand(forControllerNamed: "Joy-Con (L)"), .left)
        XCTAssertEqual(SaberAssignment.preferredHand(forControllerNamed: "Nintendo Switch Joy-Con (R)"), .right)
        XCTAssertNil(SaberAssignment.preferredHand(forControllerNamed: "DualSense Wireless Controller"))
        XCTAssertNil(SaberAssignment.preferredHand(forControllerNamed: "Joy-Con (L/R)"))
    }
}

final class ControllerDeviceProtocolTests: XCTestCase {
    func testHelloCarriesDeviceInfo() {
        let m = ControllerMessage.hello(name: "Tom’s iPad", device: ControllerDevice(kind: .iPad, id: "ABC-123", wantsSaber: false))
        XCTAssertEqual(ControllerMessage.decode(m.encoded()), m)
        let phone = ControllerMessage.hello(name: "Phone", device: ControllerDevice(kind: .iPhone, id: "x"))
        XCTAssertEqual(ControllerMessage.decode(phone.encoded()), phone)
    }

    func testOldHelloStillDecodes() {
        // Older phone apps send just the name.
        XCTAssertEqual(ControllerMessage.decode(ControllerMessage.hello(name: "Old").encoded()), .hello(name: "Old", device: nil))
    }

    func testNewHelloIsReadableByOldMacs() {
        // An older Mac reads only the name; the device info must follow it intact.
        let data = ControllerMessage.hello(name: "Pad", device: ControllerDevice(kind: .iPad, id: "id")).encoded()
        var r = ByteReader(Array(data))
        _ = r.u8(); _ = r.u8(); _ = r.u8(); _ = r.u8()
        XCTAssertEqual(r.string(), "Pad")
    }

    func testNewCommandsRoundTrip() {
        for c in [RemoteCommand.swapHands, .setDeviceUsed("iOS2", false)] {
            let m = ControllerMessage.command(id: 7, c)
            XCTAssertEqual(ControllerMessage.decode(m.encoded()), m)
        }
    }

    func testStateWithSabersRoundTrips() {
        var s = RemoteState()
        s.sabers = [.init(hand: 0, device: "Tom’s iPad", symbol: "ipad", ready: true),
                    .init(hand: 1, device: "DualSense", symbol: "gamecontroller.fill", ready: false)]
        s.canSwapHands = true
        s.calibration.streams = [.init(id: "iOS1", name: "iPad", live: true, progress: 0, done: false,
                                       symbol: "ipad", hand: 0, used: true, note: nil)]
        let m = ControllerMessage.remoteState(s)
        XCTAssertEqual(ControllerMessage.decode(m.encoded()), m)
    }
}
