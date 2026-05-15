#include "json_io.h"

#include <fstream>
#include <stdexcept>

#include <nlohmann/json.hpp>

using nlohmann::json;

namespace airpad::umap_ref {

namespace {

Hyperparameters parse_hyperparameters(const json& j) {
    Hyperparameters h;
    if (j.contains("nComponents"))         h.n_components = j.at("nComponents").get<int>();
    if (j.contains("nNeighbors"))          h.n_neighbors = j.at("nNeighbors").get<int>();
    if (j.contains("minDist"))             h.min_dist = j.at("minDist").get<double>();
    if (j.contains("spread"))              h.spread = j.at("spread").get<double>();
    if (j.contains("learningRate"))        h.learning_rate = j.at("learningRate").get<double>();
    if (j.contains("negativeSampleRate"))  h.negative_sample_rate = j.at("negativeSampleRate").get<double>();
    if (j.contains("nEpochs") && !j.at("nEpochs").is_null()) {
        h.n_epochs = j.at("nEpochs").get<int>();
    }
    if (j.contains("mixRatio"))            h.mix_ratio = j.at("mixRatio").get<double>();
    if (j.contains("localConnectivity"))   h.local_connectivity = j.at("localConnectivity").get<double>();
    if (j.contains("bandwidth"))           h.bandwidth = j.at("bandwidth").get<double>();
    return h;
}

json emit_hyperparameters(const Hyperparameters& h) {
    json j;
    j["nComponents"] = h.n_components;
    j["nNeighbors"] = h.n_neighbors;
    j["minDist"] = h.min_dist;
    j["spread"] = h.spread;
    j["learningRate"] = h.learning_rate;
    j["negativeSampleRate"] = h.negative_sample_rate;
    if (h.n_epochs.has_value()) j["nEpochs"] = *h.n_epochs;
    else j["nEpochs"] = nullptr;
    j["mixRatio"] = h.mix_ratio;
    j["localConnectivity"] = h.local_connectivity;
    j["bandwidth"] = h.bandwidth;
    return j;
}

json emit_coord(const Coord2D& c) {
    return json{{"x", c.x}, {"y", c.y}};
}

void atomic_write(const std::string& path, const std::string& text) {
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp);
        if (!out) throw std::runtime_error("cannot open for write: " + tmp);
        out << text;
        if (!out) throw std::runtime_error("write failed: " + tmp);
    }
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        throw std::runtime_error("rename failed: " + tmp + " -> " + path);
    }
}

}  // namespace

FitInput read_fit_input(const std::string& path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error("cannot open input: " + path);
    json j;
    in >> j;

    FitInput f;
    f.hyperparameters = parse_hyperparameters(j.at("hyperparameters"));
    f.rng_seed = j.at("rngSeed").get<std::uint64_t>();
    f.input_dimension = j.at("inputDimension").get<int>();

    for (const auto& pj : j.at("trainingPoints")) {
        TrainingPointInput p;
        p.node_id = pj.at("nodeID").get<std::string>();
        p.input_vector = pj.at("inputVector").get<std::vector<double>>();
        if (static_cast<int>(p.input_vector.size()) != f.input_dimension) {
            throw std::runtime_error("dimension mismatch on point " + p.node_id);
        }
        f.training_points.push_back(std::move(p));
    }
    return f;
}

void write_fit_output(const FitOutput& out, const std::string& path) {
    json j;
    j["fitterVersion"] = out.fitter_version;
    j["hyperparameters"] = emit_hyperparameters(out.hyperparameters);
    j["rngSeed"] = out.rng_seed;

    json pts = json::array();
    for (const auto& p : out.training_points) {
        pts.push_back(json{{"nodeID", p.node_id}, {"coord2D", emit_coord(p.coord2d)}});
    }
    j["trainingPoints"] = std::move(pts);

    atomic_write(path, j.dump(2));
}

void write_intermediates(const Intermediates& im, const std::string& path) {
    json j;
    j["fitterVersion"] = im.fitter_version;

    json knn = json::array();
    for (const auto& row : im.knn_graph) {
        json r = json::array();
        for (const auto& e : row) {
            r.push_back(json{{"to", e.to}, {"distance", e.distance}});
        }
        knn.push_back(std::move(r));
    }
    j["knnGraph"] = std::move(knn);

    json fss = json::array();
    for (const auto& row : im.fuzzy_simplicial_set) {
        json r = json::array();
        for (const auto& e : row) {
            r.push_back(json{{"to", e.to}, {"weight", e.weight}});
        }
        fss.push_back(std::move(r));
    }
    j["fuzzySimplicialSet"] = std::move(fss);

    json init = json::array();
    for (const auto& p : im.initial_embedding) {
        init.push_back(json{{"nodeID", p.node_id}, {"coord2D", emit_coord(p.coord2d)}});
    }
    j["initialEmbedding"] = std::move(init);

    atomic_write(path, j.dump(2));
}

// SplitMix64 — Vigna's canonical seed-derivation generator. Both umappp's
// uint64 seeds and Swift's xoshiro256** state-vector words are drawn from
// successive calls to this stream so the C++ and Swift reproductions stay
// bit-identical from the same `rngSeed` JSON scalar.
std::uint64_t SplitMix64::next() {
    state_ += static_cast<std::uint64_t>(0x9E3779B97F4A7C15);
    std::uint64_t z = state_;
    z = (z ^ (z >> 30)) * static_cast<std::uint64_t>(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)) * static_cast<std::uint64_t>(0x94D049BB133111EB);
    return z ^ (z >> 31);
}

}  // namespace airpad::umap_ref
