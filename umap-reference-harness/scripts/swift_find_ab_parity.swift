#!/usr/bin/env swift
// SB139 Stage 4a step 4.1 — host-side parity check for umappp::find_ab.
//
// Loads the harness fixture (a, b) for given (spread, min_dist), computes
// the same curve fit via the Swift mirror, and reports bit-pattern +
// absolute-error diff.
//
// Bit-exact is the target — both sides call libm log/exp/pow on the same
// hardware. If actual drift exceeds 1e-15 absolute on either coefficient,
// something is wrong (accumulation order, parenthesization, libm divergence).
// 1e-15 ≈ 4 ULP at a~1.57 / b~0.9; finite but suspiciously wide.
//
// Run from the harness root:
//   ./build/umappp-reference find-ab --spread 1.0 --min-dist 0.1 \
//       --output fixtures/find_ab_default.json
//   swift scripts/swift_find_ab_parity.swift fixtures/find_ab_default.json

import Foundation

// --- algorithm (mirror of AirPad/Services/UMAP/UMAPFindAB.swift) ---

func umapFindAB(spread: Double, minDist: Double) -> (a: Double, b: Double) {
    let grid = 300
    var gridX = [Double](repeating: 0, count: grid)
    var gridY = [Double](repeating: 0, count: grid)
    var logX = [Double](repeating: 0, count: grid)

    let delta = spread * 3.0 / Double(grid)
    for g in 0..<grid {
        gridX[g] = Double(g + 1) * delta
        logX[g] = Foundation.log(gridX[g])
        gridY[g] = gridX[g] <= minDist ? 1.0 : Foundation.exp(-(gridX[g] - minDist) / spread)
    }

    let limit: Double = 0.5
    let xHalf = Foundation.log(limit) * -spread + minDist
    let dHalf = limit / -spread
    var b = -dHalf * xHalf / (1.0 / limit - 1.0) / (2.0 * limit * limit)
    var a = (1.0 / limit - 1.0) / Foundation.pow(xHalf, 2.0 * b)

    var fitY = [Double](repeating: 0, count: grid)
    var xpow = [Double](repeating: 0, count: grid)
    var gridResid = [Double](repeating: 0, count: grid)

    func computeSS(_ A: Double, _ B: Double) -> Double {
        var ss: Double = 0
        for g in 0..<grid {
            xpow[g] = Foundation.pow(gridX[g], 2.0 * B)
            fitY[g] = 1.0 / (1.0 + A * xpow[g])
            gridResid[g] = gridY[g] - fitY[g]
            ss += gridResid[g] * gridResid[g]
        }
        return ss
    }

    var ss = computeSS(a, b)
    var lmDampener: Double = 0
    let gnIter = 50
    let maxDampener: Double = 1024
    let tol: Double = 1e-6

    for _ in 0..<gnIter {
        var da2: Double = 0, db2: Double = 0, dadb: Double = 0
        var daResid: Double = 0, dbResid: Double = 0

        for g in 0..<grid {
            let x2b = xpow[g]
            let oy = fitY[g]
            let resid = gridResid[g]
            let da = x2b * oy * oy
            let db = a * (logX[g] * 2.0) * da
            da2 += da * da
            db2 += db * db
            dadb += da * db
            daResid += da * resid
            dbResid += db * resid
        }

        var okay = false
        var candidateA: Double = 0, candidateB: Double = 0, ssNext: Double = 0

        while lmDampener < maxDampener {
            let mult = 1.0 + lmDampener
            let dampedDa2 = da2 * mult
            let dampedDb2 = db2 * mult
            let determinant = dampedDa2 * dampedDb2 - dadb * dadb
            let deltaA = -(daResid * dampedDb2 - dadb * dbResid) / determinant
            let deltaB = -(-daResid * dadb + dampedDa2 * dbResid) / determinant
            candidateA = a + deltaA
            candidateB = b + deltaB
            ssNext = computeSS(candidateA, candidateB)
            if ssNext < ss { okay = true; lmDampener /= 2.0; break }
            if lmDampener == 0 { lmDampener = Double.ulpOfOne } else { lmDampener *= 2.0 }
        }

        if !okay { break }
        if ss - ssNext <= ss * tol { break }

        a = candidateA
        b = candidateB
        ss = ssNext
    }

    return (a, b)
}

// --- fixture schema ---

struct FindABFixture: Decodable {
    let spread: Double
    let min_dist: Double
    let a: Double
    let b: Double
    let a_bits: String
    let b_bits: String
}

// --- driver ---

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(
        "usage: swift_find_ab_parity.swift <fixture.json>\n".data(using: .utf8)!)
    exit(2)
}

let fx = try JSONDecoder().decode(
    FindABFixture.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[1]))
)

func parseHex(_ s: String) -> UInt64? {
    var t = s
    if t.hasPrefix("0x") || t.hasPrefix("0X") { t.removeFirst(2) }
    return UInt64(t, radix: 16)
}

guard let wantABits = parseHex(fx.a_bits), let wantBBits = parseHex(fx.b_bits) else {
    print("FAIL: cannot parse a_bits/b_bits as hex")
    exit(1)
}

let (gotA, gotB) = umapFindAB(spread: fx.spread, minDist: fx.min_dist)
let gotABits = gotA.bitPattern
let gotBBits = gotB.bitPattern

let aAbsErr = abs(gotA - fx.a)
let bAbsErr = abs(gotB - fx.b)

let bitExact = (gotABits == wantABits) && (gotBBits == wantBBits)

print(String(
    format: "find_ab spread=%g min_dist=%g  want (a=%.17g, b=%.17g) got (a=%.17g, b=%.17g)",
    fx.spread, fx.min_dist, fx.a, fx.b, gotA, gotB))
print(String(format: "  a_bits want=0x%016llx got=0x%016llx |Δa|=%.3e",
             wantABits, gotABits, aAbsErr))
print(String(format: "  b_bits want=0x%016llx got=0x%016llx |Δb|=%.3e",
             wantBBits, gotBBits, bAbsErr))

let tol = 1e-15
if bitExact {
    print("find_ab PARITY OK · bit-exact match on both (a, b)")
} else if aAbsErr <= tol && bAbsErr <= tol {
    print("find_ab PARITY OK · within tolerance \(tol) (not bit-exact — investigate before SGD if drift surprises)")
} else {
    print("find_ab PARITY FAIL · drift exceeds tol=\(tol) on at least one coefficient")
    exit(1)
}
