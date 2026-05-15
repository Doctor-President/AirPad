#pragma once

// SB139 Stage 4a — UMAP reference harness I/O schema.
//
// This header pins the on-the-wire JSON format that both the umappp C++
// reference and the Swift `UMAP.fit` implementation read/write. Keep these
// declarations narrow and stable — both sides depend on them byte-for-byte.

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace airpad::umap_ref {

struct Hyperparameters {
    int n_components = 2;
    int n_neighbors = 15;
    double min_dist = 0.1;
    double spread = 1.0;
    double learning_rate = 1.0;
    double negative_sample_rate = 5.0;
    std::optional<int> n_epochs;  // null in JSON = umappp auto-pick

    // umappp options that AirPad doesn't expose to callers but the harness
    // captures so reproductions are exact. Defaults match umappp defaults.
    double mix_ratio = 1.0;
    double local_connectivity = 1.0;
    double bandwidth = 1.0;
};

struct TrainingPointInput {
    std::string node_id;
    std::vector<double> input_vector;
};

struct FitInput {
    Hyperparameters hyperparameters;
    std::uint64_t rng_seed = 0;
    int input_dimension = 0;
    std::vector<TrainingPointInput> training_points;
};

struct Coord2D {
    double x = 0.0;
    double y = 0.0;
};

struct TrainingPointOutput {
    std::string node_id;
    Coord2D coord2d;
};

struct FitOutput {
    std::string fitter_version;     // e.g., "umappp-3.3.2"
    Hyperparameters hyperparameters; // echoed
    std::uint64_t rng_seed = 0;
    std::vector<TrainingPointOutput> training_points;
};

struct KnnEdge {
    int to = 0;
    double distance = 0.0;
};

struct FuzzyEdge {
    int to = 0;
    double weight = 0.0;
};

struct Intermediates {
    std::string fitter_version;
    // For each input vertex (in trainingPoints order): sorted neighbors
    // with raw distances. Length per row equals n_neighbors.
    std::vector<std::vector<KnnEdge>> knn_graph;
    // Per-vertex fuzzy edges after neighbor_similarities + combine_neighbor_sets.
    // Length varies per vertex (symmetrization adds edges).
    std::vector<std::vector<FuzzyEdge>> fuzzy_simplicial_set;
    // Initial 2D embedding after umappp::initialize, before run().
    std::vector<TrainingPointOutput> initial_embedding;
};

FitInput read_fit_input(const std::string& path);
void write_fit_output(const FitOutput& out, const std::string& path);
void write_intermediates(const Intermediates& im, const std::string& path);

// SplitMix64 seed expansion. Given a scalar seed, yields a deterministic
// stream of uint64 values. Both umappp's two internal seeds (initialize_seed,
// optimize_seed) and Swift's xoshiro256** state are derived from this stream
// in documented order — see README.md.
class SplitMix64 {
public:
    explicit SplitMix64(std::uint64_t seed) : state_(seed) {}
    std::uint64_t next();
private:
    std::uint64_t state_;
};

}  // namespace airpad::umap_ref
