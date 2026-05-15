#!/usr/bin/env swift
// SB139 Stage 4a step 4.0 — host-side parity check for
// aarand::standard_uniform<double>(std::mt19937_64).
//
// Mirrors AirPad/Services/UMAP/UMAPRandom.swift's
// MersenneTwister64.nextStandardUniform(). Loads the harness fixture
// (uint64 bit-patterns of the expected double draws) and asserts each
// Swift-produced Double has the exact same IEEE 754 bit pattern.
//
// Why bit-exact: aarand::standard_uniform is `Double(mt()) / 2^64` with a
// reject loop on result == 1.0 — pure integer→double conversion plus
// multiply, no transcendentals. Same hardware, same IEEE 754 round-to-
// nearest-even, same result. Any drift here means a structural bug in
// the Swift mirror, not numerical noise.
//
// Run from the harness root:
//   ./build/umappp-reference rng-dump \
//       --algorithm standard_uniform_mt19937_64 \
//       --seed 42 --n 32 --output fixtures/standard_uniform_seed42.json
//   swift scripts/swift_uniform_parity.swift fixtures/standard_uniform_seed42.json

import Foundation

// --- MersenneTwister64 + nextStandardUniform (copy of UMAPRandom.swift) ---

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

    static let standardUniformFactor: Double = 1.0 / (Double(UInt64.max) + 1.0)

    mutating func nextStandardUniform() -> Double {
        var result: Double
        repeat {
            let raw = self.next()
            result = Double(raw) * Self.standardUniformFactor
        } while result == 1.0
        return result
    }
}

// --- fixture schema ---

struct UniformFixture: Decodable {
    let algorithm: String
    let seed: UInt64
    let n: Int
    let values: [String]
}

// --- driver ---

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(
        "usage: swift_uniform_parity.swift <fixture.json>\n".data(using: .utf8)!)
    exit(2)
}

let fixture = try JSONDecoder().decode(
    UniformFixture.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[1]))
)

guard fixture.algorithm == "standard_uniform_mt19937_64" else {
    print("FAIL: fixture algorithm is '\(fixture.algorithm)', expected standard_uniform_mt19937_64")
    exit(1)
}
guard fixture.values.count == fixture.n else {
    print("FAIL: fixture n=\(fixture.n) but values.count=\(fixture.values.count)")
    exit(1)
}

let expectedBits: [UInt64] = fixture.values.map { hex in
    var s = hex
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
    guard let v = UInt64(s, radix: 16) else {
        FileHandle.standardError.write("cannot parse hex: \(hex)\n".data(using: .utf8)!)
        exit(2)
    }
    return v
}

// Sanity-check the sigma factor matches expected 2^-64 = 0x3BF0000000000000.
let expectedFactorBits: UInt64 = 0x3BF0000000000000
let factorBits = MersenneTwister64.standardUniformFactor.bitPattern
if factorBits != expectedFactorBits {
    print("FAIL: standardUniformFactor bits=0x\(String(factorBits, radix: 16)) expected=0x\(String(expectedFactorBits, radix: 16)) (2^-64)")
    exit(1)
}

var rng = MersenneTwister64(seed: fixture.seed)
var diffs: [String] = []
for i in 0..<fixture.n {
    let v = rng.nextStandardUniform()
    let gotBits = v.bitPattern
    let wantBits = expectedBits[i]
    if gotBits != wantBits {
        let gotDouble = v
        let wantDouble = Double(bitPattern: wantBits)
        let absDelta = abs(gotDouble - wantDouble)
        diffs.append(
            "idx \(i): got=0x\(String(gotBits, radix: 16)) (\(gotDouble)) " +
            "want=0x\(String(wantBits, radix: 16)) (\(wantDouble)) " +
            "|Δ|=\(absDelta)"
        )
    }
}

if diffs.isEmpty {
    print("uniform-draw PARITY OK · n=\(fixture.n) seed=\(fixture.seed) · all bit-patterns match (factor=2^-64 verified)")
} else {
    print("uniform-draw PARITY FAIL · \(diffs.count)/\(fixture.n) bit-pattern mismatches")
    for d in diffs.prefix(20) { print("  " + d) }
    if diffs.count > 20 { print("  ... and \(diffs.count - 20) more") }
    exit(1)
}
