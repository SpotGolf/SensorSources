import Foundation

/// A sensor that delivers its readings in batches. A live source reads the hardware; a mock
/// source makes readings up and plays clips, so an app runs the same way on a simulator.
///
/// `start` and `stop` are called on the main actor. The handlers are called on the source's
/// own thread, so they must be `@Sendable`.
@MainActor
public protocol SensorSource<Sample>: AnyObject {
    associatedtype Sample: Sendable

    /// False when this device does not have the sensor.
    var isSupported: Bool { get }

    /// True from a successful `start` until `stop`, or until the source stops on its own.
    var isActive: Bool { get }

    /// Starts delivering batches to `onSamples`. A source that stops on an error reports it to
    /// `onError`. Throws when the sensor can't start. Each start begins afresh: nothing from
    /// an earlier start is reused.
    func start(onSamples: @escaping @Sendable ([Sample]) -> Void,
               onError: @escaping @Sendable (Error) -> Void) throws

    func stop()
}

public typealias AccelerometerSource = SensorSource<AccelerometerSample>
public typealias DeviceMotionSource = SensorSource<DeviceMotionSample>
public typealias MicrophoneSource = SensorSource<AudioSample>

public enum SensorSourceError: Error, Equatable {
    /// This device does not have the sensor.
    case unsupported
    /// The microphone reported no input format.
    case noInput
    /// A mock told to fail.
    case mockFailure
}

/// The three sources an app uses, live or mock.
@MainActor
public struct SensorSet {
    public let accelerometer: any AccelerometerSource
    public let deviceMotion: any DeviceMotionSource
    public let microphone: any MicrophoneSource

    public init(accelerometer: any AccelerometerSource, deviceMotion: any DeviceMotionSource,
                microphone: any MicrophoneSource) {
        self.accelerometer = accelerometer
        self.deviceMotion = deviceMotion
        self.microphone = microphone
    }

    /// Mock sources on a simulator, or when the app is launched with `--sensor-mock` or the
    /// `SENSOR_MOCK=1` environment variable; live sources otherwise.
    public static func make() -> SensorSet {
        usesMocks ? mocks() : live()
    }

    public static var usesMocks: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let process = ProcessInfo.processInfo
        return process.arguments.contains("--sensor-mock") || process.environment["SENSOR_MOCK"] == "1"
        #endif
    }

    /// The watch's batched sensors on watchOS, and `CMMotionManager` sensors on a phone, which
    /// has no batched sensors.
    public static func live() -> SensorSet {
        #if os(watchOS)
        SensorSet(accelerometer: LiveAccelerometer(), deviceMotion: LiveDeviceMotion(), microphone: LiveMicrophone())
        #else
        SensorSet(accelerometer: PhoneAccelerometer(), deviceMotion: PhoneDeviceMotion(), microphone: LiveMicrophone())
        #endif
    }

    /// Mock sources reading clips and controls from `hub`'s inbox.
    public static func mocks(hub: MockSensorHub = .shared) -> SensorSet {
        SensorSet(accelerometer: MockAccelerometer(hub: hub), deviceMotion: MockDeviceMotion(hub: hub),
                  microphone: MockMicrophone(hub: hub))
    }
}

/// Where the sources' log lines go. The app sets `handler` to send them to its own log.
@MainActor
public enum SensorLog {
    public enum Level: Sendable {
        case notice
        case error
    }

    public static var handler: ((Level, String) -> Void)?

    static func notice(_ message: String) {
        handler?(.notice, message)
    }

    static func error(_ message: String) {
        handler?(.error, message)
    }
}
