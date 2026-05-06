//
//  CErrorHandler.swift
//  mlx-swift-structured
//
//  Created by Ivan Petrukha on 03.04.2026.
//

import Foundation
import CMLXStructured

enum CErrorHandler {

    private static let state = State()

    private static let installHandler: Void = {
        set_error_handler(errorHandlerClosure)
    }()

    private static let errorHandlerClosure: @convention(c) (UnsafePointer<CChar>?) -> Void = {
        state.lastErrorMessage = $0.map {
            String(cString: $0)
        }
    }

    static func initialize() {
        _ = installHandler
    }

    static func clearLastError() {
        state.lastErrorMessage = nil
    }

    static var lastErrorMessage: String {
        state.lastErrorMessage ?? "Unknown Error"
    }

    private final class State: @unchecked Sendable {

        let lock = NSLock()
        var _lastErrorMessage: String? = nil

        var lastErrorMessage: String? {
            get { lock.withLock { _lastErrorMessage } }
            set { lock.withLock { _lastErrorMessage = newValue } }
        }
    }
}

@inline(__always)
func withCErrorHandling<T>(_ body: () throws -> T) rethrows -> T {
    CErrorHandler.initialize()
    CErrorHandler.clearLastError()
    return try body()
}
