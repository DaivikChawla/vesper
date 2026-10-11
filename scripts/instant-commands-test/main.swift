//
//  Tests the fast lane (VesperInstantCommands): what's done on the Mac at
//  once, and — just as important — what still goes to Claude.
//

import Foundation

var failureCount = 0
func expect(_ spokenText: String, _ expectedCommand: VesperInstantCommand?) {
    let actualCommand = VesperInstantCommands.command(in: spokenText)
    if actualCommand == expectedCommand {
        print("✅ \"\(spokenText)\" → \(expectedCommand.map { "\($0)" } ?? "Claude")")
    } else {
        failureCount += 1
        print("❌ \"\(spokenText)\": expected \(expectedCommand.map { "\($0)" } ?? "Claude"), got \(actualCommand.map { "\($0)" } ?? "Claude")")
    }
}

print("— timers")
expect("Set a timer for ten minutes.", .startTimer(durationSeconds: 600, label: nil))
expect("set a timer for 10 minutes for pasta", .startTimer(durationSeconds: 600, label: "pasta"))
expect("Hey Vesper, timer 5 minutes please", .startTimer(durationSeconds: 300, label: nil))
expect("start a twenty five minute timer", .startTimer(durationSeconds: 1500, label: nil))
expect("set a timer for 1 hour and 30 minutes", .startTimer(durationSeconds: 5400, label: nil))
expect("set a timer for half an hour", .startTimer(durationSeconds: 1800, label: nil))
expect("set a timer for 90 seconds", .startTimer(durationSeconds: 90, label: nil))
expect("set a timer for two and a half minutes", .startTimer(durationSeconds: 150, label: nil))
expect("can you set a 3 minute timer for tea", .startTimer(durationSeconds: 180, label: "tea"))
expect("set a timer", nil)
expect("how do I set a timer in this app", nil)
expect("set a timer for when the build finishes", nil)

print("— volume")
expect("volume down", .changeVolume(.down))
expect("Turn the volume up.", .changeVolume(.up))
expect("louder", .changeVolume(.up))
expect("mute", .changeVolume(.mute))
expect("unmute the mac", .changeVolume(.unmute))
expect("set the volume to 40 percent", .changeVolume(.setLevel(percent: 40)))
expect("volume forty", .changeVolume(.setLevel(percent: 40)))
expect("why is the volume so low", nil)
expect("volume is too low on this video", nil)

print("— music")
expect("pause the music", .controlMusic(.pause))
expect("Pause.", .controlMusic(.pause))
expect("next song", .controlMusic(.nextTrack))
expect("skip this song", .controlMusic(.nextTrack))
expect("previous track", .controlMusic(.previousTrack))
expect("resume the music", .controlMusic(.play))
expect("play some lofi", nil)
expect("pause and tell me what this error is", nil)
expect("skip to the part about xor gates", nil)

print("— time and date")
expect("What time is it?", .tellTime)
expect("what's the time now", .tellTime)
expect("what's the date today", .tellDate)
expect("what day is it", .tellDate)
expect("what time is my meeting", nil)
expect("what's this", nil)

print("— what she says")
let fixedDate = Date(timeIntervalSince1970: 1_791_000_000)
let timeLine = VesperInstantCommands.spokenLine(for: .tellTime, now: fixedDate)
if timeLine.hasPrefix("it's ") && (timeLine.hasSuffix("am.") || timeLine.hasSuffix("pm.")) { print("✅ time line: \(timeLine)") } else { failureCount += 1; print("❌ time line: \(timeLine)") }
let timerLine = VesperInstantCommands.spokenLine(for: .startTimer(durationSeconds: 5400, label: "pasta"))
if timerLine == "1 hour 30 minute timer for pasta, starting now." { print("✅ timer line: \(timerLine)") } else { failureCount += 1; print("❌ timer line: \(timerLine)") }

print(failureCount == 0 ? "\n✅ all instant command tests passed" : "\n❌ \(failureCount) instant command test(s) failed")
exit(failureCount == 0 ? 0 : 1)
