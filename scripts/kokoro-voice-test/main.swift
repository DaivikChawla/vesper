//
//  main.swift — test driver for KokoroSpeechSynthesisProvider
//
//  Runs the real provider with the real Kokoro model (FluidAudio, pinned to
//  the same version as the Xcode project): loading and warm-up, per-sentence
//  speed, the audio format handed to the playback engine, and memory.
//  Silent: audio is generated, not played. Built and run by
//  scripts/test-kokoro-voice.sh.
//

@preconcurrency import AVFoundation
import Darwin
import Foundation

var failedCheckCount = 0

func check(_ didPass: Bool, _ checkDescription: String, _ detail: String = "") {
    print("\(didPass ? "✅" : "❌") \(checkDescription)\(detail.isEmpty ? "" : " — \(detail)")")
    if !didPass { failedCheckCount += 1 }
}

/// This process's current memory footprint in MB (what Activity Monitor shows).
func currentMemoryFootprintMegabytes() -> Double {
    var vmInfo = task_vm_info_data_t()
    var infoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kernelResult = withUnsafeMutablePointer(to: &vmInfo) { vmInfoPointer in
        vmInfoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &infoCount)
        }
    }
    return kernelResult == KERN_SUCCESS ? Double(vmInfo.phys_footprint) / 1_048_576 : -1
}

func runAllChecks() async {
    let memoryBeforeLoad = currentMemoryFootprintMegabytes()
    let kokoroProvider = KokoroSpeechSynthesisProvider()
    check(!kokoroProvider.isAvailable, "not available before loading", kokoroProvider.statusDescription ?? "")

    print("\n— loading (the model is already downloaded, so this is a normal launch)")
    let loadStartedAt = Date()
    kokoroProvider.prewarmVoice()
    while !kokoroProvider.isAvailable && Date().timeIntervalSince(loadStartedAt) < 180 {
        if case .some(let status) = kokoroProvider.statusDescription, status.hasPrefix("unavailable") { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    let loadSeconds = Date().timeIntervalSince(loadStartedAt)
    check(kokoroProvider.isAvailable, "loads and warms up", String(format: "%.1fs — %@", loadSeconds, kokoroProvider.statusDescription ?? ""))
    guard kokoroProvider.isAvailable else { return }
    let memoryAfterLoad = currentMemoryFootprintMegabytes()

    print("\n— speaking Vesper-length sentences")
    let sentences = [
        "hey, i'm vesper.",
        "that button's in the top right, the little gear.",
        "and no, it wasn't hiding, you just didn't look.",
        "file menu first, then export, and png is in the format dropdown.",
        "it's the skeleton of every web page, the structure the css you're staring at gets draped over."
    ]
    var sentenceSeconds: [TimeInterval] = []
    for sentence in sentences {
        let startedAt = Date()
        do {
            let speechBuffers = try await kokoroProvider.synthesizeSpeechAudio(for: sentence)
            let elapsedSeconds = Date().timeIntervalSince(startedAt)
            sentenceSeconds.append(elapsedSeconds)
            let speechBuffer = speechBuffers[0]
            let audioSeconds = Double(speechBuffer.frameLength) / speechBuffer.format.sampleRate
            print(String(format: "   %.0f ms for %.1fs of audio — \"%@\"", elapsedSeconds * 1000, audioSeconds, sentence))
            if sentence == sentences.first {
                check(speechBuffer.format.sampleRate == 24_000 && speechBuffer.format.channelCount == 1
                        && speechBuffer.format.commonFormat == .pcmFormatFloat32,
                      "hands the engine 24 kHz mono float audio (its exact playback format — no conversion)")
            }
        } catch {
            check(false, "speaks \"\(sentence)\"", "\(error)")
        }
    }
    if !sentenceSeconds.isEmpty {
        let sortedSeconds = sentenceSeconds.sorted()
        let medianMilliseconds = sortedSeconds[sortedSeconds.count / 2] * 1000
        let slowestMilliseconds = (sortedSeconds.last ?? 0) * 1000
        check(slowestMilliseconds < 1000, "every sentence is ready in under a second",
              String(format: "median %.0f ms, slowest %.0f ms", medianMilliseconds, slowestMilliseconds))
    }

    print(String(format: "\nmemory: %.0f MB before loading, %.0f MB with Kokoro loaded (+%.0f MB)",
                 memoryBeforeLoad, memoryAfterLoad, memoryAfterLoad - memoryBeforeLoad))
}

Task { @MainActor in
    await runAllChecks()
    print(failedCheckCount == 0 ? "\n✅ all Kokoro voice checks passed" : "\n❌ \(failedCheckCount) Kokoro voice check(s) failed")
    exit(failedCheckCount == 0 ? 0 : 1)
}
dispatchMain()
