#!/usr/bin/env swift
// SB139 Stage 4a step 4.3-prep — host-side parity check for
// aarand::discrete_uniform<std::uint64_t>(std::mt19937_64, bound).
//
// Mirrors AirPad/Services/UMAP/UMAPRandom.swift's
// MersenneTwister64.nextDiscreteUniform(bound:). Loads the harness fixture
// (uint64 bit-patterns of expected discrete draws) and asserts each
// Swift-produced UInt64 matches exactly.
//
// Why bit-exact: aarand::discrete_uniform is `mt() % bound` with a
// deterministic reject loop — pure integer ops, no floating point. Both
// sides should produce identical sequences for the same (seed, bound).
// Drift here means a structural bug in the Swift mirror.
//
// Two fixtures are recommended for full coverage:
//   - bound=1000      (realistic SGD num_obs; fast-path only — reject-loop
//                      probability per draw ≈ bound/2^64 ≈ 5e-17, never
//                      fires in 64 draws)
//   - bound=2^63      (forces ~50% reject probability per draw; reject
//                      loop fires often, exercising both paths)
//
// Run from the harness root:
//   ./build/umappp-reference rng-dump --algorithm discrete_uniform_mt19937_64 \
//       --seed 42 --bound 1000 --n 64 \
//       --output fixtures/discrete_uniform_seed42_bound1000.json
//   swift scripts/swift_discrete_uniform_parity.swift \
//       fixtures/discrete_uniform_seed42_bound1000.json

import Foundation

// --- MersenneTwister64 + nextDiscreteUniform (copy of UMAPRandom.swift) ---

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

    mutating func nextDiscreteUniform(bound: UInt64) -> UInt64 {
        precondition(bound > 0, "bound must be positive")
        let range = UInt64.max
        var draw = self.next()
        if draw > range &- bound {
            let limit = range &- ((range % bound) &+ 1)
            while draw > limit {
                draw = self.next()
            }
        }
        return draw % bound
    }
}

// --- fixture schema ---

struct DiscreteUniformFixture: Decodable {
    let algorithm: String
    let seed: UInt64
    let bound: UInt64
    let n: Int
    let values: [String]
}

// --- driver ---

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(
        "usage: swift_discrete_uniform_parity.swift <fixture.json>\n".data(using: .utf8)!)
    exit(2)
}

let fixture = try JSONDecoder().decode(
    DiscreteUniformFixture.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[1]))
)

guard fixture.algorithm == "discrete_uniform_mt19937_64" else {
    print("FAIL: fixture algorithm is '\(fixture.algorithm)', expected discrete_uniform_mt19937_64")
    exit(1)
}
guard fixture.values.count == fixture.n else {
    print("FAIL: fixture n=\(fixture.n) but values.count=\(fixture.values.count)")
    exit(1)
}
guard fixture.bound > 0 else {
    print("FAIL: fixture bound must be > 0")
    exit(1)
}

let expected: [UInt64] = fixture.values.map { hex in
    var s = hex
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
    guard let v = UInt64(s, radix: 16) else {
        FileHandle.standardError.write("cannot parse hex: \(hex)\n".data(using: .utf8)!)
        exit(2)
    }
    return v
}

var rng = MersenneTwister64(seed: fixture.seed)
var diffs: [String] = []
for i in 0..<fixture.n {
    let got = rng.nextDiscreteUniform(bound: fixture.bound)
    let want = expected[i]
    if got != want {
        diffs.append(
            "idx \(i): got=\(got) (0x\(String(got, radix: 16))) " +
            "want=\(want) (0x\(String(want, radix: 16)))"
        )
    }
}

if diffs.isEmpty {
    print("discrete-uniform PARITY OK · n=\(fixture.n) seed=\(fixture.seed) " +
          "bound=\(fixture.bound) · all values match")
} else {
    print("discrete-uniform PARITY FAIL · \(diffs.count)/\(fixture.n) mismatches")
    for d in diffs.prefix(20) { print("  " + d) }
    if diffs.count > 20 { print("  ... and \(diffs.count - 20) more") }
    exit(1)
}
