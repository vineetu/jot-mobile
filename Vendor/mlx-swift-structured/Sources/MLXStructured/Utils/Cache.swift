//
//  Cache.swift
//  mlx-swift-structured
//
//  Created by Ivan Petrukha on 03.04.2026.
//

import Foundation

actor Cache<Key: Hashable & Sendable, Value: Sendable> {

    private var cache: [Key: Value] = [:]

    func value(for key: Key) -> Value? {
        cache[key]
    }

    func set(_ value: Value, for key: Key) {
        cache[key] = value
    }
}
