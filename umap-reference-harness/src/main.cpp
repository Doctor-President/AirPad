// SB139 Stage 4a — UMAP reference harness driver.
//
// Permanent diagnostic infrastructure: drives libscran/umappp end-to-end on a
// JSON fixture and emits the same JSON output schema the AirPad Swift UMAP
// implementation produces, so per-step parity can be diffed mechanically.
//
// Reaching into umappp's PUBLIC headers `neighbor_similarities.hpp` and
// `combine_neighbor_sets.hpp` directly: these are documented and namespaced
// at `umappp::`, not internal. We invoke them on a deep-copied NeighborList
// to capture the fuzzy simplicial set as an intermediate, while feeding the
// untouched raw-distance NeighborList into `umappp::initialize()` so it can
// run its own (identical) pipeline end-to-end. This duplicates the fuzzy-SS
// computation; the cost is negligible relative to the diagnostic value, and
// avoids any fork of umappp.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <knncolle/knncolle.hpp>
#include <umappp/umappp.hpp>
#include <umappp/neighbor_similarities.hpp>
#include <umappp/combine_neighbor_sets.hpp>
#include <umappp/find_ab.hpp>
#include <aarand/aarand.hpp>

#include "json_io.h"

namespace {

constexpr const char* kFitterVersion = "umappp-3.3.2";

void usage() {
    std::cerr <<
        "Usage:\n"
        "  umappp-reference fit --input <in.json> --output <out.json>\n"
        "                       [--dump-intermediates <intermediates.json>]\n"
        "                       [--epoch-limit <int>]   # run SGD up to this epoch (inclusive cap; default = all)\n"
        "  umappp-reference rng-dump --algorithm <splitmix64|mt19937_64|standard_uniform_mt19937_64|discrete_uniform_mt19937_64>\n"
        "                            --seed <uint64> --n <count> --output <path>\n"
        "                            [--bound <uint64>]   # required for discrete_uniform_mt19937_64\n"
        "  umappp-reference find-ab --spread <double> --min-dist <double> --output <path>\n";
}

struct CliArgs {
    std::string command;
    std::string input_path;
    std::string output_path;
    std::string intermediates_path;
    std::string algorithm;
    std::uint64_t seed = 0;
    std::uint64_t bound = 0;
    bool bound_set = false;
    int n = 0;
    double spread = 1.0;
    double min_dist = 0.1;
    bool spread_set = false;
    bool min_dist_set = false;
    int epoch_limit = 0;
    bool epoch_limit_set = false;
};

CliArgs parse_cli(int argc, char** argv) {
    CliArgs a;
    if (argc < 2) throw std::runtime_error("missing subcommand");
    a.command = argv[1];
    for (int i = 2; i < argc; ++i) {
        std::string s = argv[i];
        auto next = [&](const char* flag) -> std::string {
            if (i + 1 >= argc) throw std::runtime_error(std::string(flag) + " missing value");
            return argv[++i];
        };
        if (s == "--input") a.input_path = next("--input");
        else if (s == "--output") a.output_path = next("--output");
        else if (s == "--dump-intermediates") a.intermediates_path = next("--dump-intermediates");
        else if (s == "--algorithm") a.algorithm = next("--algorithm");
        else if (s == "--seed") a.seed = std::stoull(next("--seed"));
        else if (s == "--n") a.n = std::stoi(next("--n"));
        else if (s == "--bound") { a.bound = std::stoull(next("--bound")); a.bound_set = true; }
        else if (s == "--spread") { a.spread = std::stod(next("--spread")); a.spread_set = true; }
        else if (s == "--min-dist") { a.min_dist = std::stod(next("--min-dist")); a.min_dist_set = true; }
        else if (s == "--epoch-limit") { a.epoch_limit = std::stoi(next("--epoch-limit")); a.epoch_limit_set = true; }
        else throw std::runtime_error("unknown flag: " + s);
    }
    return a;
}

// Pack training-point vectors into a single column-major double buffer for
// knncolle / umappp consumption. knncolle expects column-major (each
// observation is a contiguous column of `ndim` rows).
std::vector<double> pack_column_major(
    const std::vector<airpad::umap_ref::TrainingPointInput>& pts,
    int ndim
) {
    std::vector<double> buf(static_cast<std::size_t>(ndim) * pts.size());
    for (std::size_t i = 0; i < pts.size(); ++i) {
        for (int d = 0; d < ndim; ++d) {
            buf[i * ndim + d] = pts[i].input_vector[d];
        }
    }
    return buf;
}

using Index_ = int;
using Float_ = double;
using NL = umappp::NeighborList<Index_, Float_>;

NL compute_knn(const std::vector<double>& data, int ndim, int nobs, int k) {
    auto metric = std::make_shared<knncolle::EuclideanDistance<Float_, Float_>>();
    knncolle::VptreeBuilder<Index_, Float_, Float_> builder(metric);
    knncolle::SimpleMatrix<Index_, Float_> matrix(ndim, nobs, data.data());
    auto prebuilt = builder.build_unique(matrix);

    NL nl(static_cast<std::size_t>(nobs));
    auto searcher = prebuilt->initialize();
    std::vector<Index_> idx_buf;
    std::vector<Float_> dist_buf;
    for (Index_ i = 0; i < nobs; ++i) {
        searcher->search(i, k, &idx_buf, &dist_buf);
        nl[i].clear();
        nl[i].reserve(idx_buf.size());
        for (std::size_t j = 0; j < idx_buf.size(); ++j) {
            nl[i].emplace_back(idx_buf[j], dist_buf[j]);
        }
    }
    return nl;
}

umappp::Options build_umappp_options(
    const airpad::umap_ref::Hyperparameters& h,
    std::uint64_t init_seed,
    std::uint64_t optimize_seed
) {
    umappp::Options opts;
    opts.num_neighbors = h.n_neighbors;
    opts.min_dist = h.min_dist;
    opts.spread = h.spread;
    opts.learning_rate = h.learning_rate;
    opts.negative_sample_rate = h.negative_sample_rate;
    opts.mix_ratio = h.mix_ratio;
    opts.local_connectivity = h.local_connectivity;
    opts.bandwidth = h.bandwidth;
    if (h.n_epochs.has_value()) opts.num_epochs = *h.n_epochs;
    opts.initialize_seed = init_seed;
    opts.optimize_seed = optimize_seed;
    // SB139 Stage 4a decision (C): both sides use random init to skip the
    // IRLBA spectral port. Hardcoded here so the fixture JSON schema stays
    // unchanged — initialize_method is a harness-side property of the
    // experiment, not a per-fixture knob. Random init draws from
    // aarand::standard_uniform<double>(mt19937_64) scaled to [-scale, scale).
    opts.initialize_method = umappp::InitializeMethod::RANDOM;
    return opts;
}

void run_fit(const CliArgs& args) {
    using namespace airpad::umap_ref;

    if (args.input_path.empty() || args.output_path.empty()) {
        throw std::runtime_error("fit requires --input and --output");
    }

    FitInput in = read_fit_input(args.input_path);
    const int nobs = static_cast<int>(in.training_points.size());
    if (nobs <= in.hyperparameters.n_neighbors) {
        throw std::runtime_error("trainingPoints count must exceed nNeighbors");
    }

    SplitMix64 sm(in.rng_seed);
    const std::uint64_t init_seed = sm.next();
    const std::uint64_t opt_seed = sm.next();

    const auto data = pack_column_major(in.training_points, in.input_dimension);

    // Step 1 — k-NN (deterministic, no RNG used)
    NL knn = compute_knn(data, in.input_dimension, nobs, in.hyperparameters.n_neighbors);

    // Step 2 — fuzzy simplicial set (computed on a deep copy so we can dump
    // it without disturbing what we hand to initialize()).
    NL fuzzy_dump = knn;  // deep copy
    {
        umappp::NeighborSimilaritiesOptions<Float_> nsopt;
        nsopt.local_connectivity = in.hyperparameters.local_connectivity;
        nsopt.bandwidth = in.hyperparameters.bandwidth;
        // min_k_dist_scale stays at its default 1e-3 — matches what
        // umappp::initialize() uses internally (see initialize.hpp).
        umappp::neighbor_similarities(fuzzy_dump, nsopt);
        umappp::combine_neighbor_sets(fuzzy_dump, static_cast<Float_>(in.hyperparameters.mix_ratio));
    }

    // Step 3 — initialize embedding (spectral or random per Options default).
    // Pass `std::move(knn)` so umappp consumes the raw-distance NL.
    std::vector<Float_> embedding(static_cast<std::size_t>(2) * nobs, Float_{0});
    const umappp::Options opts = build_umappp_options(in.hyperparameters, init_seed, opt_seed);
    auto status = umappp::initialize(std::move(knn), 2, embedding.data(), opts);

    // Snapshot the initial embedding before run() optimizes it.
    std::vector<Float_> initial = embedding;

    // Step 4 — SGD optimization. By default runs to completion; with
    // --epoch-limit N, runs up to epoch N inclusive (umappp's
    // Status::run(embedding, epoch_limit) advances current_epoch up to
    // epoch_limit). Used for SB139 Stage 4a 4.4 (Status wrapper) parity:
    // generate partial-coords fixtures at intermediate epochs so the
    // Swift UMAPStatus resume semantics can be diffed against umappp's.
    if (args.epoch_limit_set) {
        const int total = status.num_epochs();
        int limit = args.epoch_limit;
        if (limit < 0) throw std::runtime_error("--epoch-limit must be >= 0");
        if (limit > total) {
            std::cerr << "WARN: --epoch-limit " << limit
                      << " exceeds total " << total
                      << "; clamping.\n";
            limit = total;
        }
        status.run(embedding.data(), limit);
    } else {
        status.run(embedding.data());
    }

    // Emit final coords.
    FitOutput out;
    out.fitter_version = kFitterVersion;
    out.hyperparameters = in.hyperparameters;
    out.rng_seed = in.rng_seed;
    out.training_points.reserve(nobs);
    for (int i = 0; i < nobs; ++i) {
        TrainingPointOutput p;
        p.node_id = in.training_points[i].node_id;
        p.coord2d = { embedding[2 * i + 0], embedding[2 * i + 1] };
        out.training_points.push_back(std::move(p));
    }
    write_fit_output(out, args.output_path);

    // Emit intermediates if requested.
    if (!args.intermediates_path.empty()) {
        Intermediates im;
        im.fitter_version = kFitterVersion;

        im.knn_graph.resize(nobs);
        // `knn` was moved into umappp; reconstruct from `fuzzy_dump` won't
        // work because it carries weights now. Recompute the raw k-NN
        // for the dump — cheap, deterministic, same inputs.
        NL knn_for_dump = compute_knn(data, in.input_dimension, nobs, in.hyperparameters.n_neighbors);
        for (int i = 0; i < nobs; ++i) {
            im.knn_graph[i].reserve(knn_for_dump[i].size());
            for (const auto& e : knn_for_dump[i]) {
                im.knn_graph[i].push_back({ static_cast<int>(e.first), e.second });
            }
        }

        im.fuzzy_simplicial_set.resize(nobs);
        for (int i = 0; i < nobs; ++i) {
            im.fuzzy_simplicial_set[i].reserve(fuzzy_dump[i].size());
            for (const auto& e : fuzzy_dump[i]) {
                im.fuzzy_simplicial_set[i].push_back({ static_cast<int>(e.first), e.second });
            }
        }

        im.initial_embedding.reserve(nobs);
        for (int i = 0; i < nobs; ++i) {
            TrainingPointOutput p;
            p.node_id = in.training_points[i].node_id;
            p.coord2d = { initial[2 * i + 0], initial[2 * i + 1] };
            im.initial_embedding.push_back(std::move(p));
        }

        write_intermediates(im, args.intermediates_path);
    }

    std::cerr << "OK fit nobs=" << nobs
              << " dim=" << in.input_dimension
              << " seed=" << in.rng_seed
              << " -> " << args.output_path << "\n";
}

// RNG-dump subcommand. Emits the first N outputs of the named generator,
// seeded directly with the given scalar `seed`. Format: hex strings so
// Swift can embed the expected values as `0x...` literals without
// integer-parse ambiguity. The Swift parity test in SubstrateSelfTest
// reads these and asserts byte-identical output for the same seed.
//
// Why mt19937_64 here: umappp uses std::mt19937_64 internally
// (Options.initialize_seed, Options.optimize_seed both feed it). We mirror
// that in Swift so per-step bit-parity holds through SGD — this fixture
// is what verifies the mirror.
void run_rng_dump(const CliArgs& args) {
    if (args.algorithm.empty() || args.output_path.empty() || args.n <= 0) {
        throw std::runtime_error("rng-dump requires --algorithm, --seed, --n, --output");
    }

    std::vector<std::uint64_t> values;
    values.reserve(args.n);

    if (args.algorithm == "splitmix64") {
        airpad::umap_ref::SplitMix64 sm(args.seed);
        for (int i = 0; i < args.n; ++i) values.push_back(sm.next());
    } else if (args.algorithm == "mt19937_64") {
        std::mt19937_64 rng(args.seed);
        for (int i = 0; i < args.n; ++i) values.push_back(rng());
    } else if (args.algorithm == "standard_uniform_mt19937_64") {
        // Emit the bit-pattern (uint64) of each accepted double draw from
        // aarand::standard_uniform<double>(std::mt19937_64). Pattern lets
        // the Swift parity script reconstruct the double via
        // Double(bitPattern:) without any decimal-parse ambiguity. The
        // function rejects on result == 1.0 internally; both sides must
        // agree on rejection or the sequence desynchronizes.
        std::mt19937_64 rng(args.seed);
        for (int i = 0; i < args.n; ++i) {
            const double v = aarand::standard_uniform<double>(rng);
            std::uint64_t bits = 0;
            static_assert(sizeof(bits) == sizeof(v), "double must be 64-bit");
            std::memcpy(&bits, &v, sizeof(bits));
            values.push_back(bits);
        }
    } else if (args.algorithm == "discrete_uniform_mt19937_64") {
        // Mirror of aarand::discrete_uniform<std::uint64_t>(std::mt19937_64,
        // bound) — used by umappp's optimize_layout (SGD step 4.3) for
        // negative sampling: aarand::discrete_uniform(rng, num_obs). Output
        // is the integer draw in [0, bound), emitted as 16-hex uint64.
        // Pure-integer path: mt() % bound with rejection of the top
        // (range % bound) + 1 outcomes for unbiased modulo. bound must be
        // supplied via --bound; both fast-path and reject-loop coverage
        // belong in the fixture set (e.g., bound=1000 for realistic SGD,
        // bound=2^63 to force frequent reject-loop entry).
        if (!args.bound_set || args.bound == 0) {
            throw std::runtime_error("discrete_uniform_mt19937_64 requires --bound > 0");
        }
        std::mt19937_64 rng(args.seed);
        for (int i = 0; i < args.n; ++i) {
            const std::uint64_t v =
                aarand::discrete_uniform<std::uint64_t>(rng, args.bound);
            values.push_back(v);
        }
    } else {
        throw std::runtime_error("unknown algorithm: " + args.algorithm
                                 + " (expected splitmix64 | mt19937_64 | standard_uniform_mt19937_64 | discrete_uniform_mt19937_64)");
    }

    auto hex = [](std::uint64_t v) {
        std::ostringstream s;
        s << "0x" << std::hex << std::setw(16) << std::setfill('0') << v;
        return s.str();
    };

    std::ostringstream js;
    js << "{\n  \"algorithm\": \"" << args.algorithm << "\",\n"
       << "  \"seed\": " << args.seed << ",\n";
    if (args.bound_set) {
        js << "  \"bound\": " << args.bound << ",\n";
    }
    js << "  \"n\": " << args.n << ",\n"
       << "  \"values\": [\n";
    for (int i = 0; i < args.n; ++i) {
        js << "    \"" << hex(values[i]) << "\"" << (i + 1 < args.n ? "," : "") << "\n";
    }
    js << "  ]\n}\n";

    {
        std::ofstream out(args.output_path);
        if (!out) throw std::runtime_error("cannot open output: " + args.output_path);
        out << js.str();
    }
    std::cerr << "OK rng-dump algorithm=" << args.algorithm
              << " seed=" << args.seed
              << " n=" << args.n
              << " -> " << args.output_path << "\n";
}

// find-ab subcommand — emit umappp::find_ab(spread, min_dist) -> (a, b)
// for parity testing the Swift port. find_ab is a deterministic curve fit
// (Gauss-Newton + LM dampening on a 300-point grid); same input must
// produce the same (a, b) bit-exactly on the same hardware, since both
// sides call into the system libm for log/pow/exp.
//
// Schema: decimal values for human review, hex bit-pattern for authoritative
// equality compare on the Swift side.
void run_find_ab(const CliArgs& args) {
    if (!args.spread_set || !args.min_dist_set || args.output_path.empty()) {
        throw std::runtime_error("find-ab requires --spread, --min-dist, --output");
    }

    const auto result = umappp::find_ab<double>(args.spread, args.min_dist);
    const double a = result.first;
    const double b = result.second;

    auto bits_of = [](double v) -> std::string {
        std::uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(v), "double must be 64-bit");
        std::memcpy(&bits, &v, sizeof(bits));
        std::ostringstream s;
        s << "0x" << std::hex << std::setw(16) << std::setfill('0') << bits;
        return s.str();
    };

    std::ostringstream js;
    js << std::setprecision(17);  // round-trip precision for double
    js << "{\n"
       << "  \"spread\": " << args.spread << ",\n"
       << "  \"min_dist\": " << args.min_dist << ",\n"
       << "  \"a\": " << a << ",\n"
       << "  \"b\": " << b << ",\n"
       << "  \"a_bits\": \"" << bits_of(a) << "\",\n"
       << "  \"b_bits\": \"" << bits_of(b) << "\"\n"
       << "}\n";

    {
        std::ofstream out(args.output_path);
        if (!out) throw std::runtime_error("cannot open output: " + args.output_path);
        out << js.str();
    }
    std::cerr << "OK find-ab spread=" << args.spread
              << " min_dist=" << args.min_dist
              << " -> (a=" << a << ", b=" << b << ") "
              << args.output_path << "\n";
}

}  // namespace

int main(int argc, char** argv) {
    try {
        CliArgs args = parse_cli(argc, argv);
        if (args.command == "fit") {
            run_fit(args);
        } else if (args.command == "rng-dump") {
            run_rng_dump(args);
        } else if (args.command == "find-ab") {
            run_find_ab(args);
        } else {
            usage();
            return 2;
        }
    } catch (const std::exception& e) {
        std::cerr << "ERROR: " << e.what() << "\n";
        usage();
        return 1;
    }
    return 0;
}
