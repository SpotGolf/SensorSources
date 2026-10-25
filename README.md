# SensorSources

The accelerometer, device motion and microphone of a watch or a phone behind one protocol, `SensorSource`, with live sources for real devices and mock sources for simulators. Mocks send at-rest readings at the live rates and play recorded clips, so an app's sensor code runs unchanged on a simulator.

| Type                                                       | What                                                                                                                                                     |
|------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `AccelerometerSample`, `DeviceMotionSample`, `AudioSample` | One reading, or one mic buffer. Times are seconds of system uptime                                                                                       |
| `SensorSource`                                             | `start(onSamples:onError:)`, `stop()`, `isActive`, `isSupported`. Each start begins afresh                                                               |
| `LiveAccelerometer`, `LiveDeviceMotion`, `LiveMicrophone`  | Core Motion batched sensors and `AVAudioEngine` (a new engine every start)                                                                               |
| `PhoneAccelerometer`, `PhoneDeviceMotion`                  | `CMMotionManager` at 100 Hz, in batches of about a second, for a phone                                                                                   |
| `MockAccelerometer`, `MockDeviceMotion`, `MockMicrophone`  | Baseline data, clips and modes from `MockSensorHub`                                                                                                      |
| `SensorSet.make()`                                         | Mocks on a simulator, or with `--sensor-mock` or `SENSOR_MOCK=1`; live otherwise. Live picks the batched sources on watchOS and the phone sources on iOS |
| `SensorHealth.isReal(_:)`                                  | Whether a batch is real data, not the zeros, NaNs or silence of a broken sensor                                                                          |
| `SensorLog.handler`                                        | Where the sources' log lines go                                                                                                                          |

## Adding the package

Swift Package Manager, watchOS 27 and iOS 27:

```swift
.package(url: "https://github.com/SpotGolf/SensorSources", exact: "0.1.0")
```

In an Xcode project, add the same URL under Package Dependencies. The app needs `NSMotionUsageDescription`, and `NSMicrophoneUsageDescription` for the microphone.

| Device | Accelerometer             | Device motion             | Note                                                      |
|--------|---------------------------|---------------------------|-----------------------------------------------------------|
| Watch  | 800 Hz, batched           | 200 Hz, batched           | The batched sensors deliver only during a workout session |
| Phone  | 100 Hz, `CMMotionManager` | 100 Hz, `CMMotionManager` | No workout session needed                                 |

The mocks send their at-rest readings at the same rates. For an app on both a phone and a watch, add the package to both targets: each app reads its own device's sensors, and the package does not send readings between them.

## Using the sources

Get the three sources once, at launch. `make()` picks mocks on a simulator and live sources on a device, so the rest of the code is the same on both.

```swift
import SensorSources

@MainActor
final class Sensors {
    let sources = SensorSet.make()

    init() {
        // The sources' own log lines, such as the microphone starting
        SensorLog.handler = { level, message in print(level, message) }
    }

    func startAccelerometer() throws {
        // Called on the sensor's own thread, about once a second
        try sources.accelerometer.start(onSamples: { batch in
            guard SensorHealth.isReal(batch) else { return }   // zeros or NaNs from a broken sensor
            let peak = batch.map(\.acceleration.magnitude).max() ?? 0
            print("\(batch.count) readings, peak \(peak) g")
        }, onError: { error in
            print("Accelerometer error: \(error)")
        })
    }

    func startMicrophone() throws {
        try sources.microphone.start(onSamples: { buffers in
            for buffer in buffers {
                // buffer.samples: mono Float samples at buffer.sampleRate, first frame at buffer.hostTime
            }
        }, onError: { _ in })
    }

    func stopAll() {
        sources.accelerometer.stop()
        sources.deviceMotion.stop()
        sources.microphone.stop()
    }
}
```

- Call `start` and `stop` on the main actor. The handlers run on the sensor's thread, so they must not touch main-actor state directly.
- A start can throw: `SensorSourceError.unsupported` on a device without the sensor, or an audio error when the microphone can't start. Each start begins from scratch, so starting again after a failure is the way to recover.
- `isActive` turns false when a source stops on its own. Checking it, and whether `SensorHealth.isReal` batches keep arriving, tells when to restart.
- Sample times are seconds of system uptime (`ProcessInfo.processInfo.systemUptime`), the clock Core Motion and audio host times use.

Tests and previews can drive the mocks directly instead of through files:

```swift
let hub = MockSensorHub(inbox: nil)
let sources = SensorSet.mocks(hub: hub)
hub.setMode(.fail, for: .microphone)        // the next microphone start throws
hub.play(try MockClip(folder: clipURL))     // plays now, in place of the at-rest readings
```

## Clips and modes

Mocks read `Library/SensorMock/Inbox/` in the app's data container every 0.5 s.

- `<name>.clip/` holds any of `accelerometer.csv` (`t,x,y,z`), `motion.csv` (`t,rx,ry,rz,ux,uy,uz,gx,gy,gz,qx,qy,qz,qw`) and `audio.wav` (mono, 48 kHz), with `t` in seconds from the clip's start. It plays once in place of the baseline, then is deleted. An optional `clip.json` with `startAt` (seconds since 1970) starts it at that time instead of when it is picked up, so clips can be sent ahead. Queued clips play one after the other.
- `control.json` maps `accelerometer`, `deviceMotion` and `microphone` to a mode: `ok`, `fail` (start throws), `silent` (active, sends nothing) or `zeros` (sends all-zero data).

`Tools/sensor-mock` sends both to a booted simulator:

```bash
Tools/sensor-mock "<simulator>" <bundle id> play Examples/putt.clip
Tools/sensor-mock "<simulator>" <bundle id> play Examples/putt.clip --at 1793000000
Tools/sensor-mock "<simulator>" <bundle id> set microphone fail
Tools/sensor-mock "<simulator>" <bundle id> reset
```

`Examples/` has a putt, a practice stroke and a chip (13 g) recorded on an Apple Watch. A clip plays at the rate it was recorded at, so on a phone these give watch-rate readings.
