import CoreMotion
import Foundation

/// The batched accelerometer: 800 Hz, about one batch a second. On a watch it delivers only
/// during a workout. Each start uses a new manager, in case the old one is wedged.
@MainActor
public final class LiveAccelerometer: AccelerometerSource {
    private var manager: CMBatchedSensorManager?

    public init() {}

    public var isSupported: Bool { CMBatchedSensorManager.isAccelerometerSupported }

    public var isActive: Bool { manager?.isAccelerometerActive ?? false }

    public func start(onSamples: @escaping @Sendable ([AccelerometerSample]) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) throws {
        guard isSupported else { throw SensorSourceError.unsupported }
        manager?.stopAccelerometerUpdates()
        let manager = CMBatchedSensorManager()
        self.manager = manager
        // Core Motion calls this on its own queue, so @Sendable: a plain closure made here
        // would count as main-actor code, and Swift 6 traps when it runs anywhere else
        manager.startAccelerometerUpdates { @Sendable batch, error in
            if let error { onError(error) }
            guard let batch else { return }
            onSamples(batch.map { data in
                let a = data.acceleration
                return AccelerometerSample(timestamp: data.timestamp, acceleration: Vector3(x: a.x, y: a.y, z: a.z))
            })
        }
    }

    public func stop() {
        manager?.stopAccelerometerUpdates()
        manager = nil
    }
}

/// Batched device motion: 200 Hz rotation rate, user acceleration, gravity and attitude,
/// about one batch a second. On a watch it delivers only during a workout.
@MainActor
public final class LiveDeviceMotion: DeviceMotionSource {
    private var manager: CMBatchedSensorManager?

    public init() {}

    public var isSupported: Bool { CMBatchedSensorManager.isDeviceMotionSupported }

    public var isActive: Bool { manager?.isDeviceMotionActive ?? false }

    public func start(onSamples: @escaping @Sendable ([DeviceMotionSample]) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) throws {
        guard isSupported else { throw SensorSourceError.unsupported }
        manager?.stopDeviceMotionUpdates()
        let manager = CMBatchedSensorManager()
        self.manager = manager
        manager.startDeviceMotionUpdates { @Sendable batch, error in
            if let error { onError(error) }
            guard let batch else { return }
            onSamples(batch.map { motion in
                let r = motion.rotationRate, u = motion.userAcceleration, g = motion.gravity, q = motion.attitude.quaternion
                return DeviceMotionSample(timestamp: motion.timestamp,
                                          rotationRate: Vector3(x: r.x, y: r.y, z: r.z),
                                          userAcceleration: Vector3(x: u.x, y: u.y, z: u.z),
                                          gravity: Vector3(x: g.x, y: g.y, z: g.z),
                                          attitude: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w))
            })
        }
    }

    public func stop() {
        manager?.stopDeviceMotionUpdates()
        manager = nil
    }
}
