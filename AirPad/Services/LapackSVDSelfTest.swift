import Foundation

/// live-19 (4) — the Map's two SVDs (`SubstrateWhitening.lapackSVD`, `SubstrateBagLayout.lapackSVDSymmetric`) moved
/// from the deprecated CLAPACK interface to Accelerate's current LAPACK headers (`-DACCELERATE_NEW_LAPACK`). Checked
/// against what an SVD must satisfy, not against a stored dump: a known symmetric eigenproblem; U's columns
/// orthonormal; σᵢ = ‖Aᵀuᵢ‖ (U and σ agree with A); σ descending. Run by `-MapNumericSelfTest` with the Substrate,
/// UMAP and HDBSCAN suites.
enum LapackSVDSelfTest {
    static func run() -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — " + detail)"); if !ok { fails += 1 }
        }
        func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }

        // 1. Symmetric [[2,1],[1,2]]: σ = 3, 1; u₁ = ±(1,1)/√2.
        var sym: [Double] = [2, 1, 1, 2]
        if let (u, s) = SubstrateBagLayout.lapackSVDSymmetric(matrix: &sym, n: 2) {
            row("symmetric-singulars-3-1", near(s[0], 3) && near(s[1], 1), "s=\(s)")
            row("symmetric-u1-is-(1,1)/√2", near(abs(u[0]), 1 / 2.0.squareRoot()) && near(abs(u[1]), 1 / 2.0.squareRoot()), "u1=\(u[0]),\(u[1])")
        } else { row("symmetric-svd-ran", false) }

        // 2. A deterministic 20×8 matrix (column-major) through the whitening SVD.
        let rowsN = 20, colsN = 8
        var x: UInt64 = 0x9E3779B97F4A7C15
        let a: [Double] = (0..<(rowsN * colsN)).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: x >> 11) % 2000) / 1000.0
        }
        var work = a
        if let (u, s) = SubstrateWhitening.lapackSVD(matrix: &work, rows: rowsN, cols: colsN) {
            let k = min(rowsN, colsN)
            row("whitening-shapes", u.count == rowsN * k && s.count == k, "u=\(u.count) s=\(s.count)")
            row("whitening-descending", zip(s, s.dropFirst()).allSatisfy { $0 >= $1 }, "s=\(s.map { String(format: "%.4f", $0) })")
            var maxOrtho = 0.0
            for i in 0..<k { for j in 0..<k {
                var d = 0.0
                for r in 0..<rowsN { d += u[i * rowsN + r] * u[j * rowsN + r] }
                maxOrtho = max(maxOrtho, abs(d - (i == j ? 1 : 0)))
            } }
            row("whitening-U-orthonormal", maxOrtho < 1e-10, String(format: "max |UᵀU − I| = %.2e", maxOrtho))
            var maxSigma = 0.0
            for i in 0..<k {
                var n2 = 0.0
                for c in 0..<colsN {
                    var d = 0.0
                    for r in 0..<rowsN { d += a[c * rowsN + r] * u[i * rowsN + r] }
                    n2 += d * d
                }
                maxSigma = max(maxSigma, abs(n2.squareRoot() - s[i]) / max(1, s[i]))
            }
            row("whitening-sigma-equals-|Aᵀu|", maxSigma < 1e-10, String(format: "max rel err = %.2e", maxSigma))
        } else { row("whitening-svd-ran", false) }

        return "[LapackSVDSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
