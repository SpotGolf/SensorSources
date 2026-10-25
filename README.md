# SensorSources

The watch's accelerometer, device motion and microphone behind one protocol, `SensorSource`, with live sources for real devices and mock sources for simulators. Mocks send at-rest readings at the live rates and play recorded clips, so an app's sensor code runs unchanged on a simulator.

| Type | What |
|---|---|
| `AccelerometerSample`, `DeviceMotionSample`, `AudioSample` | One reading, or one mic buffer. Times are seconds of system uptime |
| `SensorSource` | `start(onSamples:onError:)`, `stop()`, `isActive`, `isSupported`. Each start begins afresh |
| `LiveAccelerometer`, `LiveDeviceMotion`, `LiveMicrophone` | Core Motion batched sensors and `AVAudioEngine` (a new engine every start) |
| `MockAccelerometer`, `MockDeviceMotion`, `MockMicrophone` | Baseline data, clips and modes from `MockSensorHub` |
| `SensorSet.make()` | Mocks on a simulator, or with `--sensor-mock` or `SENSOR_MOCK=1`; live otherwise |
| `SensorHealth.isReal(_:)` | Whether a batch is real data, not the zeros, NaNs or silence of a broken sensor |
| `SensorLog.handler` | Where the sources' log lines go |

## Clips and modes

Mocks read `Library/SensorMock/Inbox/` in the app's data container every 0.5 s.

- `<name>.clip/` holds any of `accelerometer.csv` (`t,x,y,z`), `motion.csv` (`t,rx,ry,rz,ux,uy,uz,gx,gy,gz,qx,qy,qz,qw`) and `audio.wav` (mono, 48 kHz), with `t` in seconds from the clip's start. It plays once in place of the baseline, then is deleted. An optional `clip.json` with `startAt` (seconds since 1970) starts it at that time instead of when it is picked up, so clips can be sent ahead. Queued clips play one after the other.
- `control.json` maps `accelerometer`, `deviceMotion` and `microphone` to a mode: `ok`, `fail` (start throws), `silent` (active, sends nothing) or `zeros` (sends all-zero data).

`Tools/sensor-mock` sends both to a booted simulator:

```bash
Tools/sensor-mock "<simulator>" <bundle id> play Examples/putt.clip
Tools/sensor-mock "<simulator>" <bundle id> set microphone fail
Tools/sensor-mock "<simulator>" <bundle id> reset
```

`Examples/` has a putt, a practice stroke and a chip (13 g) recorded on an Apple Watch.

## Simulating a recorded round

`Tools/simulate` plays a simulation folder to a simulator at its recorded pace: GPS fixes through `simctl location`, and clips through the mock sensors.

| File | What |
|---|---|
| `simulation.json` | `name`, and optionally `greens` (`hole`, `t`, `duration`) for `--list` |
| `location.csv` | `t,lat,lon[,alt,hacc]`, with `t` in seconds from the simulation's start |
| `clips.csv` | `t,clip`: when each clip in `clips/` starts |
| `clips/<name>.clip/` | Clip folders as above |

```bash
Tools/simulate <folder> --list
Tools/simulate <folder> --watch "<simulator>" --bundle <bundle id> [--phone "<simulator>"] [--from MIN] [--to MIN]
```

It plays in real time, since detectors depend on real timing; `--from` and `--to` pick a part, in minutes.
