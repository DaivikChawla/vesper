//
//  VesperDirectMicrophoneCapture.swift
//  leanring-buddy
//
//  Records from one specific microphone (the Mac's own) without ever
//  opening the system's default input.
//
//  Why not AVAudioEngine: its input node is created bound to the default
//  input — AirPods, when they're connected — and only afterwards can it be
//  pointed at another device. That brief open was enough to switch the
//  AirPods into their low-quality "phone call" mode at every hotkey press
//  (their mic side dropped to 24 kHz), which broke up and muffled whatever
//  was playing in them — a video, or her own voice. The user heard it only
//  on AirPods, never on the Mac's speakers.
//
//  Here the device is set on a bare HAL input unit before it is
//  initialized, so no other device is touched.
//

@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

nonisolated final class VesperDirectMicrophoneCapture: @unchecked Sendable {
    /// What arrives in the delivery block: the same kind of buffer an
    /// AVAudioEngine tap delivers, in `inputFormat`.
    let inputFormat: AVAudioFormat

    private var inputAudioUnit: AudioUnit?
    private var deliverMicrophoneBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Buffers are handed on from the real-time audio thread to this queue,
    /// so the transcriber and voice recorder never run on the audio thread.
    private let deliveryQueue = DispatchQueue(label: "vesper.direct-microphone-delivery")

    /// Builds the input unit for `deviceIdentifier`. Throws if the device
    /// can't be opened (then the caller uses its usual path).
    init(deviceIdentifier: AudioDeviceID) throws {
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let halComponent = AudioComponentFindNext(nil, &componentDescription) else {
            throw Self.error("no HAL audio unit")
        }
        var createdAudioUnit: AudioUnit?
        try Self.check(AudioComponentInstanceNew(halComponent, &createdAudioUnit), "creating the input unit")
        guard let createdAudioUnit else { throw Self.error("no input unit") }

        do {
            // Input on (element 1), output off (element 0) — this unit only records.
            var enableFlag: UInt32 = 1
            try Self.check(AudioUnitSetProperty(createdAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableFlag, UInt32(MemoryLayout<UInt32>.size)), "enabling input")
            var disableFlag: UInt32 = 0
            try Self.check(AudioUnitSetProperty(createdAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableFlag, UInt32(MemoryLayout<UInt32>.size)), "disabling output")

            // The device, before anything is initialized.
            var chosenDeviceIdentifier = deviceIdentifier
            try Self.check(AudioUnitSetProperty(createdAudioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &chosenDeviceIdentifier, UInt32(MemoryLayout<AudioDeviceID>.size)), "choosing the microphone")

            // The hardware's own rate and channel count, delivered as
            // non-interleaved Float32 (AVAudioEngine's standard format).
            var hardwareFormat = AudioStreamBasicDescription()
            var hardwareFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(createdAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardwareFormat, &hardwareFormatSize), "reading the microphone format")
            guard hardwareFormat.mSampleRate > 0, hardwareFormat.mChannelsPerFrame > 0,
                  let deliveredFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.mSampleRate, channels: hardwareFormat.mChannelsPerFrame) else {
                throw Self.error("the microphone reports no format")
            }
            var deliveredStreamDescription = deliveredFormat.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(createdAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &deliveredStreamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "setting the delivered format")
            inputFormat = deliveredFormat
        } catch {
            AudioComponentInstanceDispose(createdAudioUnit)
            throw error
        }
        inputAudioUnit = createdAudioUnit
    }

    deinit {
        stop()
    }

    /// Starts recording. `deliverMicrophoneBuffer` runs on a background queue.
    func start(deliverMicrophoneBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let inputAudioUnit else { throw Self.error("the input unit was already closed") }
        self.deliverMicrophoneBuffer = deliverMicrophoneBuffer

        var inputCallback = AURenderCallbackStruct(
            inputProc: { callbackContext, actionFlags, timeStamp, busNumber, frameCount, _ in
                let capture = Unmanaged<VesperDirectMicrophoneCapture>.fromOpaque(callbackContext).takeUnretainedValue()
                return capture.renderMicrophoneAudio(actionFlags: actionFlags, timeStamp: timeStamp, busNumber: busNumber, frameCount: frameCount)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try Self.check(AudioUnitSetProperty(inputAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "setting the input callback")
        try Self.check(AudioUnitInitialize(inputAudioUnit), "opening the microphone")
        let startStatus = AudioOutputUnitStart(inputAudioUnit)
        if startStatus != noErr {
            AudioUnitUninitialize(inputAudioUnit)
            throw Self.error("starting the microphone (\(startStatus))")
        }
    }

    /// Stops recording and closes the device. Safe to call more than once.
    func stop() {
        guard let inputAudioUnit else { return }
        self.inputAudioUnit = nil
        // After AudioOutputUnitStop returns no more callbacks run, so the
        // unit can be disposed of right away.
        AudioOutputUnitStop(inputAudioUnit)
        AudioUnitUninitialize(inputAudioUnit)
        AudioComponentInstanceDispose(inputAudioUnit)
        deliverMicrophoneBuffer = nil
    }

    /// Runs on the real-time audio thread: pulls this slice of audio into a
    /// fresh buffer and hands it to the delivery queue.
    private func renderMicrophoneAudio(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let inputAudioUnit,
              let microphoneBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return noErr
        }
        microphoneBuffer.frameLength = frameCount
        let renderStatus = AudioUnitRender(inputAudioUnit, actionFlags, timeStamp, busNumber, frameCount, microphoneBuffer.mutableAudioBufferList)
        guard renderStatus == noErr, let deliverMicrophoneBuffer else { return renderStatus }
        deliveryQueue.async {
            deliverMicrophoneBuffer(microphoneBuffer)
        }
        return noErr
    }

    private static func check(_ status: OSStatus, _ whatWasBeingDone: String) throws {
        if status != noErr {
            throw error("\(whatWasBeingDone) (\(status))")
        }
    }

    private static func error(_ description: String) -> NSError {
        NSError(domain: "VesperDirectMicrophoneCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mac microphone: \(description)"])
    }
}
