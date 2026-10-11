//
//  VesperObjectiveCExceptions.swift
//  leanring-buddy
//
//  Swift side of VesperObjectiveCExceptionCatcher (see its header): runs an
//  AVAudioEngine call that can raise an NSException and turns the exception
//  into an ordinary thrown error, so the caller's normal failure path runs
//  (skip the sentence, say the mic wouldn't start) instead of the app
//  swallowing the exception and crashing later.
//

import Foundation

/// An Objective-C exception caught by `VesperObjectiveCExceptions.run`.
nonisolated struct VesperObjectiveCExceptionError: LocalizedError {
    let operationDescription: String
    let exceptionName: String
    let exceptionReason: String

    var errorDescription: String? {
        "\(operationDescription) raised \(exceptionName): \(exceptionReason)"
    }
}

nonisolated enum VesperObjectiveCExceptions {
    /// Runs `operationThatMightRaise`, rethrowing its Swift error or turning
    /// an Objective-C exception it raised into `VesperObjectiveCExceptionError`.
    /// Keep the closure to the raising calls themselves: an exception skips
    /// any Swift cleanup between the raise and the catch.
    static func run(
        _ operationDescription: String,
        _ operationThatMightRaise: () throws -> Void
    ) throws {
        // Swift errors can't cross the Objective-C block, so a thrown error
        // is kept here and rethrown once the block has returned.
        var swiftErrorThrownInsideBlock: Error?
        let raisedException = VesperCatchObjectiveCException {
            do {
                try operationThatMightRaise()
            } catch {
                swiftErrorThrownInsideBlock = error
            }
        }
        if let raisedException {
            let caughtExceptionError = VesperObjectiveCExceptionError(
                operationDescription: operationDescription,
                exceptionName: raisedException.name.rawValue,
                exceptionReason: raisedException.reason ?? "no reason given"
            )
            print("⚠️ Caught an Objective-C exception — \(caughtExceptionError.errorDescription ?? "")")
            throw caughtExceptionError
        }
        if let swiftErrorThrownInsideBlock {
            throw swiftErrorThrownInsideBlock
        }
    }
}
