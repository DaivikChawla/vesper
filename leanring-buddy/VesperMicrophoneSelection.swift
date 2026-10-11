//
//  VesperMicrophoneSelection.swift
//  leanring-buddy
//
//  Which microphone Vesper records from.
//
//  With Bluetooth headphones (AirPods), the moment any app opens their
//  microphone macOS switches them from high-quality stereo to the low-
//  quality "phone call" profile. Her voice then plays muffled, and every
//  switch back and forth (at each hotkey press and release) causes breaks,
//  delays and odd noises — and the call-quality mic sounds different enough
//  that the "only my voice" check stops recognizing the owner.
//
//  So when the system's input is a Bluetooth device and the Mac has its own
//  microphone, she listens through the Mac's microphone instead. The
//  headphones never leave high-quality mode. With the lid closed (no built-
//  in mic) she falls back to the headphones' mic.
//

import CoreAudio
import Foundation
import IOKit

enum VesperMicrophoneSelection {
    struct MicrophoneDevice: Equatable {
        let deviceIdentifier: AudioDeviceID
        let name: String
    }

    /// The Mac's built-in microphone to use instead of the default input,
    /// or nil to use the default input as it is.
    static func builtInMicrophoneToUseInsteadOfBluetooth() -> MicrophoneDevice? {
        guard let defaultInputDeviceIdentifier = defaultInputDeviceIdentifier(),
              isBluetoothDevice(defaultInputDeviceIdentifier),
              // With the lid closed the built-in mic still exists but records
              // silence — use the headphones' mic instead.
              !isLaptopLidClosed() else {
            return nil
        }
        return allInputDeviceIdentifiers()
            .first { deviceIdentifier in
                transportType(of: deviceIdentifier) == kAudioDeviceTransportTypeBuiltIn
            }
            .map { deviceIdentifier in
                MicrophoneDevice(deviceIdentifier: deviceIdentifier, name: deviceName(of: deviceIdentifier) ?? "MacBook Microphone")
            }
    }

    /// True in clamshell mode (lid closed, external display).
    static func isLaptopLidClosed() -> Bool {
        let powerManagementService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard powerManagementService != 0 else { return false }
        defer { IOObjectRelease(powerManagementService) }
        let clamshellState = IORegistryEntryCreateCFProperty(powerManagementService, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        return clamshellState ?? false
    }

    static func defaultInputDeviceIdentifier() -> AudioDeviceID? {
        var deviceIdentifier = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceIdentifier)
        return status == noErr && deviceIdentifier != 0 ? deviceIdentifier : nil
    }

    static func deviceName(of deviceIdentifier: AudioDeviceID) -> String? {
        var deviceNameReference: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceIdentifier, &propertyAddress, 0, nil, &propertySize, &deviceNameReference)
        guard status == noErr, let deviceNameReference else { return nil }
        return deviceNameReference.takeRetainedValue() as String
    }

    private static func isBluetoothDevice(_ deviceIdentifier: AudioDeviceID) -> Bool {
        let deviceTransportType = transportType(of: deviceIdentifier)
        return deviceTransportType == kAudioDeviceTransportTypeBluetooth
            || deviceTransportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(of deviceIdentifier: AudioDeviceID) -> UInt32 {
        var deviceTransportType = UInt32(0)
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceIdentifier, &propertyAddress, 0, nil, &propertySize, &deviceTransportType)
        return deviceTransportType
    }

    /// Every audio device that can record.
    private static func allInputDeviceIdentifiers() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize) == noErr else {
            return []
        }
        var deviceIdentifiers = [AudioDeviceID](repeating: 0, count: Int(propertySize) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceIdentifiers) == noErr else {
            return []
        }
        return deviceIdentifiers.filter { deviceIdentifier in hasInputChannels(deviceIdentifier) }
    }

    private static func hasInputChannels(_ deviceIdentifier: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceIdentifier, &propertyAddress, 0, nil, &propertySize) == noErr, propertySize > 0 else {
            return false
        }
        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceIdentifier, &propertyAddress, 0, nil, &propertySize, bufferListPointer) == noErr else {
            return false
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.contains { audioBuffer in audioBuffer.mNumberChannels > 0 }
    }
}
