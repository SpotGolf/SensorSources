import XCTest
@testable import SensorSources

final class MockSourceTests: XCTestCase {
    func testAccelerometerBaselineIsAtRestAt800Hz() {
        let batch = MockAccelerometer.samples(from: 10, to: 11, mode: .ok, clips: [])

        XCTAssertEqual(batch.count, 800)
        XCTAssertEqual(batch.first!.timestamp, 10, accuracy: 1e-9)
        XCTAssertTrue(SensorHealth.isReal(batch))
        XCTAssertEqual(batch.map(\.acceleration.magnitude).max()!, 1, accuracy: 0.05)
    }

    func testDeviceMotionBaselineIsRealAt200Hz() {
        let batch = MockDeviceMotion.samples(from: 10, to: 11, mode: .ok, clips: [])

        XCTAssertEqual(batch.count, 200)
        XCTAssertTrue(SensorHealth.isReal(batch))
    }

    func testMicrophoneBaselineIsQuietNoiseInWholeBuffers() {
        let rate = MockSensorHub.audioSampleRate
        let batch = MockMicrophone.samples(from: 10, to: 10 + 4096 / rate, mode: .ok, clips: [])

        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch[0].samples.count, 4096)
        XCTAssertTrue(SensorHealth.isReal(batch))
        XCTAssertLessThanOrEqual(batch[0].samples.map(abs).max()!, 0.001)
    }

    func testZerosModeIsNotReal() {
        XCTAssertFalse(SensorHealth.isReal(MockAccelerometer.samples(from: 0, to: 1, mode: .zeros, clips: [])))
        XCTAssertFalse(SensorHealth.isReal(MockDeviceMotion.samples(from: 0, to: 1, mode: .zeros, clips: [])))
        XCTAssertFalse(SensorHealth.isReal(MockMicrophone.samples(from: 0, to: 0.1, mode: .zeros, clips: [])))
    }

    func testClipReplacesTheBaselineForItsSpanThenStops() {
        let swing = (0..<9).map { AccelerometerSample(timestamp: Double($0) * 0.1, acceleration: Vector3(x: 20, y: 0, z: 0)) }
        let clip = PlayingClip(clip: MockClip(accelerometer: swing), start: 10.5)

        let batch = MockAccelerometer.samples(from: 10, to: 12, mode: .ok, clips: [clip])

        let strong = batch.filter { $0.acceleration.x == 20 }
        XCTAssertEqual(strong.count, 9)
        XCTAssertEqual(strong.first!.timestamp, 10.5, accuracy: 1e-9)
        // No baseline inside the clip's span, and the baseline on either side of it
        XCTAssertFalse(batch.contains { $0.acceleration.x != 20 && $0.timestamp > 10.5 && $0.timestamp < 11.3 })
        XCTAssertTrue(batch.contains { $0.timestamp < 10.5 })
        XCTAssertTrue(batch.contains { $0.timestamp > 11.4 })
        XCTAssertEqual(zip(batch, batch.dropFirst()).filter { $0.timestamp > $1.timestamp }.count, 0)
    }

    func testClipAudioPlaysInPlaceOfTheNoise() {
        let rate = MockSensorHub.audioSampleRate
        let clip = PlayingClip(clip: MockClip(audio: [Float](repeating: 0.5, count: 4096)), start: 10)

        let batch = MockMicrophone.samples(from: 10, to: 10 + 2 * 4096 / rate, mode: .ok, clips: [clip])

        XCTAssertEqual(batch.count, 2)
        XCTAssertTrue(batch[0].samples.allSatisfy { $0 == 0.5 })
        XCTAssertTrue(batch[1].samples.allSatisfy { abs($0) <= 0.001 })
    }

    @MainActor
    func testFailModeMakesStartThrow() {
        let hub = MockSensorHub(inbox: nil)
        hub.setMode(.fail, for: .microphone)
        let microphone = MockMicrophone(hub: hub)

        XCTAssertThrowsError(try microphone.start(onSamples: { _ in }, onError: { _ in }))
        XCTAssertFalse(microphone.isActive)
    }

    @MainActor
    func testStartedMockDeliversBatches() throws {
        let hub = MockSensorHub(inbox: nil)
        let microphone = MockMicrophone(hub: hub)
        let delivered = expectation(description: "a buffer")
        delivered.assertForOverFulfill = false

        try microphone.start(onSamples: { batch in
            if SensorHealth.isReal(batch) { delivered.fulfill() }
        }, onError: { _ in })
        XCTAssertTrue(microphone.isActive)
        wait(for: [delivered], timeout: 2)
        microphone.stop()
        XCTAssertFalse(microphone.isActive)
    }

    @MainActor
    func testSilentModeStaysActiveAndSendsNothing() throws {
        let hub = MockSensorHub(inbox: nil)
        hub.setMode(.silent, for: .microphone)
        let microphone = MockMicrophone(hub: hub)
        let nothing = expectation(description: "no buffer")
        nothing.isInverted = true

        try microphone.start(onSamples: { _ in nothing.fulfill() }, onError: { _ in })
        XCTAssertTrue(microphone.isActive)
        wait(for: [nothing], timeout: 0.5)
        microphone.stop()
    }

    func testInboxControlAndClipAreRead() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = inbox.appendingPathComponent("swing.clip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "t,x,y,z\n0,1,2,3\n0.5,4,5,6\n".write(to: folder.appendingPathComponent("accelerometer.csv"), atomically: true, encoding: .utf8)
        try #"{"microphone": "fail", "deviceMotion": "zeros"}"#.write(to: inbox.appendingPathComponent("control.json"), atomically: true, encoding: .utf8)
        let hub = MockSensorHub(inbox: inbox)

        hub.poll()

        XCTAssertEqual(hub.mode(of: .microphone), .fail)
        XCTAssertEqual(hub.mode(of: .deviceMotion), .zeros)
        XCTAssertEqual(hub.mode(of: .accelerometer), .ok)
        let now = ProcessInfo.processInfo.systemUptime
        let playing = try XCTUnwrap(hub.playing(from: now - 1, to: now + 1).first)
        XCTAssertEqual(playing.clip.accelerometer.map(\.acceleration), [Vector3(x: 1, y: 2, z: 3), Vector3(x: 4, y: 5, z: 6)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a played clip is deleted")

        try FileManager.default.removeItem(at: inbox.appendingPathComponent("control.json"))
        hub.poll()
        XCTAssertEqual(hub.mode(of: .microphone), .ok)
    }

    func testClipWithAStartTimeWaitsForIt() throws {
        let hub = MockSensorHub(inbox: nil)
        let now = ProcessInfo.processInfo.systemUptime
        let swing = [AccelerometerSample(timestamp: 0, acceleration: Vector3(x: 20, y: 0, z: 0))]

        hub.play(MockClip(accelerometer: swing, startAt: Date().addingTimeInterval(30)))

        XCTAssertTrue(hub.playing(from: now, to: now + 1).isEmpty)
        let later = try XCTUnwrap(hub.playing(from: now + 29.5, to: now + 30.5).first)
        XCTAssertEqual(later.start, now + 30, accuracy: 0.1)
    }

    func testQueuedClipsPlayOneAfterTheOther() {
        let swing = [AccelerometerSample(timestamp: 0, acceleration: Vector3(x: 20, y: 0, z: 0)),
                     AccelerometerSample(timestamp: 0.1, acceleration: Vector3(x: 20, y: 0, z: 0))]
        let first = PlayingClip(clip: MockClip(accelerometer: swing), start: 10.2)
        let second = PlayingClip(clip: MockClip(accelerometer: swing), start: 10.6)

        let batch = MockAccelerometer.samples(from: 10, to: 11, mode: .ok, clips: [first, second])

        let strong = batch.filter { $0.acceleration.x == 20 }.map(\.timestamp)
        XCTAssertEqual(strong.count, 4)
        for (time, expected) in zip(strong, [10.2, 10.3, 10.6, 10.7]) {
            XCTAssertEqual(time, expected, accuracy: 1e-9)
        }
    }

    func testOldClipsAreDropped() {
        let hub = MockSensorHub(inbox: nil)
        hub.play(MockClip(accelerometer: [AccelerometerSample(timestamp: 0, acceleration: .zero)]), at: 10)

        XCTAssertEqual(hub.playing(from: 10, to: 11).count, 1)
        XCTAssertTrue(hub.playing(from: 20, to: 21).isEmpty)
        XCTAssertTrue(hub.playing(from: 10, to: 11).isEmpty, "a dropped clip does not come back")
    }

    func testBadClipLineIsAnError() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".clip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "0,1,2\n".write(to: folder.appendingPathComponent("accelerometer.csv"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MockClip(folder: folder))
    }
}

final class ExampleClipTests: XCTestCase {
    private static let examples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Examples")

    func testEveryExampleClipReadsWithAllThreeSensors() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.examples.path).filter { $0.hasSuffix(".clip") }
        XCTAssertEqual(Set(names), ["chip.clip", "practice-stroke.clip", "putt.clip"])
        for name in names {
            let clip = try MockClip(folder: Self.examples.appendingPathComponent(name))
            XCTAssertEqual(clip.accelerometerDuration, 4, accuracy: 0.05, name)
            XCTAssertEqual(clip.deviceMotionDuration, 4, accuracy: 0.05, name)
            XCTAssertEqual(clip.audioDuration, 4, accuracy: 0.05, name)
            XCTAssertTrue(SensorHealth.isReal(clip.accelerometer), name)
            XCTAssertTrue(SensorHealth.isReal(clip.deviceMotion), name)
        }
    }

    func testTheChipIsAFullSwing() throws {
        let clip = try MockClip(folder: Self.examples.appendingPathComponent("chip.clip"))

        XCTAssertGreaterThan(clip.accelerometer.map(\.acceleration.magnitude).max()!, 13)
    }
}
