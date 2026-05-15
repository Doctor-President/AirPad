#!/usr/bin/env swift
// SB139 Stage 4a step 1 — host-side Swift RNG parity check.
//
// Compiles and runs the same SplitMix64 and MersenneTwister64 algorithms
// the iOS app uses (mirrored from AirPad/Services/UMAP/UMAPRandom.swift),
// dumping the first 32 values for seed 42 as hex strings. Diff against
// the umappp-reference harness fixtures to verify the Swift implementation
// is bit-identical to libc++ std::mt19937_64.
//
// Run:
//   swift umap-reference-harness/scripts/swift_rng_parity.swift
// Or with one-line diff:
//   diff <(swift .../swift_rng_parity.swift splitmix64) \
//        <(jq -r '.values[]' .../splitmix64_seed42.json)

import Foundation

// --- algorithms (copy of UMAPRandom.swift; keep in sync) ---

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct MersenneTwister64 {
    private static let NN: Int = 312
    private static let MM: Int = 156
    private static let MATRIX_A: UInt64 = 0xB5026F5AA96619E9
    private static let UM: UInt64 = 0xFFFFFFFF80000000
    private static let LM: UInt64 = 0x000000007FFFFFFF
    private var mt: [UInt64]
    private var mti: Int

    init(seed: UInt64) {
        self.mt = [UInt64](repeating: 0, count: Self.NN)
        self.mt[0] = seed
        for i in 1..<Self.NN {
            let prev = self.mt[i &- 1]
            self.mt[i] = 6364136223846793005 &* (prev ^ (prev >> 62)) &+ UInt64(i)
        }
        self.mti = Self.NN
    }

    mutating func next() -> UInt64 {
        if mti >= Self.NN { refreshState() }
        var y = mt[mti]
        mti &+= 1
        y ^= (y >> 29) & 0x5555555555555555
        y ^= (y << 17) & 0x71D67FFFEDA60000
        y ^= (y << 37) & 0xFFF7EEE000000000
        y ^= (y >> 43)
        return y
    }

    private mutating func refreshState() {
        for i in 0..<(Self.NN - Self.MM) {
            let x = (mt[i] & Self.UM) | (mt[i &+ 1] & Self.LM)
            let mag: UInt64 = (x & 1) != 0 ? Self.MATRIX_A : 0
            mt[i] = mt[i &+ Self.MM] ^ (x >> 1) ^ mag
        }
        for i in (Self.NN - Self.MM)..<(Self.NN - 1) {
            let x = (mt[i] & Self.UM) | (mt[i &+ 1] & Self.LM)
            let mag: UInt64 = (x & 1) != 0 ? Self.MATRIX_A : 0
            mt[i] = mt[i &+ Self.MM &- Self.NN] ^ (x >> 1) ^ mag
        }
        let x = (mt[Self.NN - 1] & Self.UM) | (mt[0] & Self.LM)
        let mag: UInt64 = (x & 1) != 0 ? Self.MATRIX_A : 0
        mt[Self.NN - 1] = mt[Self.MM - 1] ^ (x >> 1) ^ mag
        mti = 0
    }
}

// --- driver ---

let args = CommandLine.arguments
let algo = args.count >= 2 ? args[1] : "mt19937_64"
let seed: UInt64 = args.count >= 3 ? UInt64(args[2]) ?? 42 : 42
let n: Int = args.count >= 4 ? Int(args[3]) ?? 32 : 32

func hex(_ v: UInt64) -> String {
    String(format: "0x%016llx", v)
}

switch algo {
case "splitmix64":
    var rng = SplitMix64(seed: seed)
    for _ in 0..<n { print(hex(rng.next())) }
case "mt19937_64":
    var rng = MersenneTwister64(seed: seed)
    for _ in 0..<n { print(hex(rng.next())) }
default:
    FileHandle.standardError.write("unknown algorithm: \(algo)\n".data(using: .utf8)!)
    exit(2)
}
