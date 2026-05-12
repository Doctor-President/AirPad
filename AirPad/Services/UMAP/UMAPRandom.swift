import Foundation

// SB139 Stage 4a step 1 — deterministic RNGs for UMAP fit/transform.
//
// AirPad's hand-rolled UMAP is diff-validated against `libscran/umappp` via
// the `umap-reference-harness` at the repo top level. umappp uses
// `std::mt19937_64` internally for both `Options.initialize_seed` (spectral
// jitter / random-fallback init) and `Options.optimize_seed` (SGD negative
// sampling). We mirror that exactly here so per-step bit-parity holds
// through SGD — the whole point of the harness is bisection capability.
//
// SplitMix64 is Vigna's standard scalar-to-stream expander, used here to
// derive umappp's two MT19937-64 seeds from a single user-provided seed
// scalar. The expansion order is documented in `umap-reference-harness/
// README.md` and is verified end-to-end by `UMAPSelfTest`.

// MARK: - SplitMix64

/// Vigna's SplitMix64. Mirrors the C++ harness implementation in
/// `umap-reference-harness/src/json_io.{h,cpp}`. Seed-derivation only;
/// not used for any UMAP-internal randomness.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - MersenneTwister64

/// MT19937-64 — Matsumoto-Nishimura 64-bit Mersenne Twister.
///
/// Bit-identical to `std::mt19937_64(seed)` from libc++ when seeded with
/// the same scalar. Verified by `UMAPSelfTest.testMT19937Parity` against
/// the C++ harness fixture `umap-reference-harness/fixtures/
/// mt19937_64_seed42.json`.
///
/// Reference: Matsumoto & Nishimura, "Mersenne Twister with improved
/// initialization" (2000). Constants and seeding match the canonical
/// `init_genrand64` / `genrand64_int64` routines.
struct MersenneTwister64 {
    private static let NN: Int = 312
    private static let MM: Int = 156
    private static let MATRIX_A: UInt64 = 0xB5026F5AA96619E9
    private static let UM: UInt64 = 0xFFFFFFFF80000000   // upper 33 bits
    private static let LM: UInt64 = 0x000000007FFFFFFF   // lower 31 bits

    private var mt: [UInt64]
    private var mti: Int

    init(seed: UInt64) {
        self.mt = [UInt64](repeating: 0, count: Self.NN)
        self.mt[0] = seed
        for i in 1..<Self.NN {
            let prev = self.mt[i &- 1]
            self.mt[i] = 6364136223846793005 &* (prev ^ (prev >> 62)) &+ UInt64(i)
        }
        // Force a refresh on first call to next(). C++ libc++ uses the
        // same "lazy refresh" pattern.
        self.mti = Self.NN
    }

    mutating func next() -> UInt64 {
        if mti >= Self.NN {
            refreshState()
        }
        var y = mt[mti]
        mti &+= 1
        // Tempering (canonical MT19937-64 constants).
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

    // Mirror of `aarand::standard_uniform<double>(std::mt19937_64)` from
    // umappp's RNG helper library. Used by umappp::random_init() in
    // `spectral_init.hpp:222` (Stage 4a UMAP step 4.2). See
    // `aarand/aarand.hpp:34` for the reference implementation.
    //
    // `factor` is `1.0 / (Double(UInt64.max) + 1.0)`. `Double(UInt64.max)`
    // rounds the value 2^64 - 1 to its nearest double under IEEE 754
    // round-to-nearest-even, which is 2^64 (round-up from exactly halfway
    // because 2^64's mantissa LSB is 0). Adding 1.0 stays at 2^64 because
    // 1.0 is below half a ULP of 2^64. So `factor = 2^-64` exactly. C++
    // does the same on the same hardware, so factor is bit-identical
    // both sides.
    //
    // Reject loop on `result == 1.0` matches aarand's safeguard — a u64
    // close enough to 2^64 - 1 to round to 2^64 produces 1.0; never
    // observed in practice with MT19937-64 but kept structurally so the
    // Swift and C++ sides agree on rejection.
    static let standardUniformFactor: Double = 1.0 / (Double(UInt64.max) + 1.0)

    mutating func nextStandardUniform() -> Double {
        var result: Double
        repeat {
            let raw = self.next()
            result = Double(raw) * Self.standardUniformFactor
        } while result == 1.0
        return result
    }

    // Mirror of `aarand::discrete_uniform<std::uint64_t>(std::mt19937_64,
    // bound)` from umappp's RNG helper library. Used by
    // umappp::optimize_layout()'s SGD negative sampling
    // (`optimize_layout.hpp:164, 465`) — `discrete_uniform(rng, num_obs)`
    // picks a random observation index for repulsive-force sampling. See
    // `aarand/aarand.hpp:126-167` for the reference implementation.
    //
    // Algorithm: `mt() % bound`, with rejection of the top
    // `(range % bound) + 1` outcomes so the modulo is unbiased. For
    // std::mt19937_64, `range = max - min = UInt64.max - 0 = UInt64.max`,
    // so `draw = self.next()` directly. The fast-path skip
    // (`draw <= range - bound`) avoids the modulo cost when draw is well
    // below the danger zone — for AirPad's SGD bounds (num_obs ~200-2000),
    // the reject loop is statistically near-dead but kept structurally so
    // Swift and C++ agree on rejection if it ever fires.
    //
    // Bit-exact against aarand's path; verified by `swift_discrete_uniform_
    // parity.swift` against fixtures covering both fast-path (bound=1000)
    // and reject-loop (bound=2^63) coverage.
    mutating func nextDiscreteUniform(bound: UInt64) -> UInt64 {
        precondition(bound > 0, "bound must be positive")
        // For std::mt19937_64: min()=0, max()=UInt64.max, so range = UInt64.max.
        let range = UInt64.max
        var draw = self.next()
        if draw > range &- bound {
            // limit = range - ((range % bound) + 1)
            let limit = range &- ((range % bound) &+ 1)
            while draw > limit {
                draw = self.next()
            }
        }
        return draw % bound
    }
}

// MARK: - Seed expansion

/// Derive umappp's `(initialize_seed, optimize_seed)` pair from a single
/// user-provided scalar seed. Expansion order is documented in
/// `umap-reference-harness/README.md` and must stay byte-identical to the
/// C++ harness `run_fit()`:
///
/// ```
/// state := rngSeed
/// initialize_seed := SplitMix64(state).next()
/// optimize_seed   := SplitMix64(state).next()  // shared state, second draw
/// ```
///
/// Returned in `(initialize, optimize)` order.
func deriveUMAPSeeds(from rngSeed: UInt64) -> (initialize: UInt64, optimize: UInt64) {
    var sm = SplitMix64(seed: rngSeed)
    let initSeed = sm.next()
    let optSeed = sm.next()
    return (initSeed, optSeed)
}

// MARK: - Random init (umappp::random_init)

/// SB139 Stage 4a step 4.2 — random embedding initialization.
///
/// Mirrors `umappp::random_init` in `spectral_init.hpp:209-225`. Each
/// coordinate is drawn uniformly from `[-scale, scale)` via
/// `vals[i] = standard_uniform(rng) * (2*scale) - scale` for `i` in
/// `0..<(num_dim * num_obs)` — pure integer→double conversion + multiply +
/// subtract + FMA, no transcendentals. Bit-exact against umappp's
/// `initialize()` random-init path: `MersenneTwister64.nextStandardUniform()`
/// matches `aarand::standard_uniform<double>(mt19937_64)` (4.0), and
/// `addingProduct` mirrors clang's contraction of `u*mult - shift` to
/// `fma(u, mult, -shift)` under default `-ffp-contract=on` (4.2 finding).
///
/// The FMA contraction matters: separate-rounding produces 1–2 ULP drift
/// vs single-rounding fma on ~37% of coords at this scale. The Swift mirror
/// uses `Double.addingProduct` (FMA semantics) wherever the C++ source
/// expresses `a*b ± c`. Carry-forward rule for 4.3 SGD gradient math.
///
/// Layout (matches umappp's flat `Float_*`): per-observation strided. For
/// 2D output, point `i` lives at indices `[2*i + 0]` (first dim) and
/// `[2*i + 1]` (second dim). Default `scale = 10` matches
/// `Options.initialize_random_scale`.
func umapRandomInit(
    numObs: Int,
    numDim: Int,
    seed: UInt64,
    scale: Double = 10.0
) -> [Double] {
    var rng = MersenneTwister64(seed: seed)
    let mult = scale * 2
    let negShift = -scale
    let total = numDim * numObs
    var vals = [Double](repeating: 0, count: total)
    for i in 0..<total {
        vals[i] = negShift.addingProduct(rng.nextStandardUniform(), mult)
    }
    return vals
}
