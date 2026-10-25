import XCTest
@testable import SensorSources

final class SensorHealthTests: XCTestCase {
    private func accel(_ x: Double, _ y: Double, _ z: Double) -> AccelerometerSample {
        AccelerometerSample(timestamp: 1, acceleration: Vector3(x: x, y: y, z: z))
    }

    private func motion(gravity: Vector3, rotation: Vector3 = .zero) -> DeviceMotionSample {
        DeviceMotionSample(timestamp: 1, rotationRate: rotation, userAcceleration: .zero, gravity: gravity, attitude: .identity)
    }

    func testAccelerometerAtRestIsReal() {
        XCTAssertTrue(SensorHealth.isReal([accel(0, 0, -1)]))
    }

    func testAccelerometerOfZerosIsNotReal() {
        XCTAssertFalse(SensorHealth.isReal([accel(0, 0, 0), accel(0, 0, 0)]))
    }

    func testAccelerometerWithANaNIsNotReal() {
        XCTAssertFalse(SensorHealth.isReal([accel(0, 0, -1), accel(.nan, 0, -1)]))
    }

    func testEmptyBatchesAreNotReal() {
        XCTAssertFalse(SensorHealth.isReal([AccelerometerSample]()))
        XCTAssertFalse(SensorHealth.isReal([DeviceMotionSample]()))
        XCTAssertFalse(SensorHealth.isReal([AudioSample]()))
    }

    func testDeviceMotionNeedsGravityNearOneG() {
        XCTAssertTrue(SensorHealth.isReal([motion(gravity: Vector3(x: 0, y: 0.6, z: -0.8))]))
        XCTAssertFalse(SensorHealth.isReal([motion(gravity: .zero)]))
        XCTAssertFalse(SensorHealth.isReal([motion(gravity: Vector3(x: 0, y: 0, z: -1), rotation: Vector3(x: .infinity, y: 0, z: 0))]))
    }

    func testMicrophoneNeedsSomeNoise() {
        XCTAssertTrue(SensorHealth.isReal([AudioSample(hostTime: 1, sampleRate: 48_000, samples: [0, 0.0001, 0])]))
        XCTAssertFalse(SensorHealth.isReal([AudioSample(hostTime: 1, sampleRate: 48_000, samples: [0, 0, 0])]))
        XCTAssertFalse(SensorHealth.isReal([AudioSample(hostTime: 1, sampleRate: 48_000, samples: [])]))
        XCTAssertFalse(SensorHealth.isReal([AudioSample(hostTime: 1, sampleRate: 48_000, samples: [0.1, .nan])]))
    }
}
