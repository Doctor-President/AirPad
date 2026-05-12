import Foundation

// SB139 Stage 4a step 4.1 — find_ab curve fit.
//
// Mirrors umappp::find_ab<double>(spread, min_dist) from umappp v3.3.2
// (`find_ab.hpp`). Returns the (a, b) coefficients used by the SGD
// attractive/repulsive force formulas in optimize_layout:
//
//   y(x) = 1 / (1 + a * x^(2b))
//
// fit against the target curve `pmin(1, exp(-(x - min_dist) / spread))`
// via Gauss-Newton with Levenberg-Marquardt dampening on a 300-point grid.
//
// Bit-exact parity with the C++ reference is the goal: all transcendental
// ops (log/exp/pow) route through Darwin's libm — the same library
// Apple clang's libc++ uses — so on the same hardware, same inputs
// should yield byte-identical (a, b). Accumulation order in the
// gradient sums must match the C++ loop exactly (left-to-right `+=` on
// each scalar). Validated by `umap-reference-harness/scripts/
// swift_find_ab_parity.swift`.

struct UMAPCurveFitParameters {
    let a: Double
    let b: Double
}

func umapFindAB(spread: Double, minDist: Double) -> UMAPCurveFitParameters {
    let grid = 300
    var gridX = [Double](repeating: 0, count: grid)
    var gridY = [Double](repeating: 0, count: grid)
    var logX = [Double](repeating: 0, count: grid)

    // +1 inside the index avoids the trivial least-squares result at x=0,
    // where both curves are y=1 and the derivative w.r.t. b is undefined.
    let delta = spread * 3.0 / Double(grid)
    for g in 0..<grid {
        gridX[g] = Double(g + 1) * delta
        logX[g] = Foundation.log(gridX[g])
        gridY[g] = gridX[g] <= minDist ? 1.0 : Foundation.exp(-(gridX[g] - minDist) / spread)
    }

    // Analytic starting estimates by matching curve value and gradient at
    // the half-saturation point (limit = 0.5).
    let limit: Double = 0.5
    let xHalf = Foundation.log(limit) * -spread + minDist
    let dHalf = limit / -spread
    var b = -dHalf * xHalf / (1.0 / limit - 1.0) / (2.0 * limit * limit)
    var a = (1.0 / limit - 1.0) / Foundation.pow(xHalf, 2.0 * b)

    var fitY = [Double](repeating: 0, count: grid)
    var xpow = [Double](repeating: 0, count: grid)
    var gridResid = [Double](repeating: 0, count: grid)

    // Side-effecting helper: writes xpow/fitY/gridResid for (A, B). The
    // outer gradient loop reads back those arrays — matches the C++
    // structure where compute_ss leaves its working state in named
    // vectors for the subsequent J^T J / J^T r computation.
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
        var da2: Double = 0
        var db2: Double = 0
        var dadb: Double = 0
        var daResid: Double = 0
        var dbResid: Double = 0

        for g in 0..<grid {
            let x2b = xpow[g]
            let oy = fitY[g]
            let resid = gridResid[g]

            // ∂resid/∂a  =  x^(2b) / (1 + a x^(2b))^2
            let da = x2b * oy * oy

            // ∂resid/∂b  =  a * (x^(2b) * 2 log x) / (1 + a x^(2b))^2
            let db = a * (logX[g] * 2.0) * da

            da2 += da * da
            db2 += db * db
            dadb += da * db
            daResid += da * resid
            dbResid += db * resid
        }

        var okay = false
        var candidateA: Double = 0
        var candidateB: Double = 0
        var ssNext: Double = 0

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
            if ssNext < ss {
                okay = true
                lmDampener /= 2.0
                break
            }

            // .ulpOfOne == numeric_limits<double>::epsilon() == 2^-52.
            if lmDampener == 0 {
                lmDampener = Double.ulpOfOne
            } else {
                lmDampener *= 2.0
            }
        }

        if !okay { break }
        if ss - ssNext <= ss * tol { break }

        a = candidateA
        b = candidateB
        ss = ssNext
    }

    return UMAPCurveFitParameters(a: a, b: b)
}
