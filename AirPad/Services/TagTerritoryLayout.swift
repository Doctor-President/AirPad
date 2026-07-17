// TagTerritoryLayout.swift
// Tag-anchored Map — GRAVITY MODEL (v2). INITIAL PLACEMENT ONLY; physics /
// engagement / focal / zoom untouched. Position is always re-derived here,
// never stored as truth.
//
// Gravity priority (strongest first): COLLECTION > ANCHOR TAG > LANGUAGE.
//   - A node in a (non-system) collection lands in that collection's territory.
//   - Else a node with an anchor tag lands in that anchor's territory.
//   - Else the node is pulled to the nearest territory by embedding cosine.
//   - Poor fit everywhere → the "unanchored" edge region.
// Territory CENTERS ("continents") are spaced by centroid similarity — similar
// territories sit nearer (a similarity force layout, not a fixed ring).
// Streets (within-territory embedding order) + permeability arrive in later
// phases; `permeability` is threaded now so the signature is stable.

import CoreGraphics
import Foundation

@MainActor
enum TagTerritoryLayout {

    // ws-dark-light-mode — the "vast spacing" dials (hand-set in aec54b2, never
    // tuned). MapTuning defaults == 720/82 → byte-identical when off; applies on
    // the next layout. (Before aec54b2 the density came from a different engine —
    // SubstrateBagLayout MDS — not these values. See the report.)
    private static var territoryRingRadius: CGFloat { MapTuning.territoryRadius }
    private static var nodeRingSpacing: CGFloat { MapTuning.nodeRingSpacing }
    private static let unanchoredThreshold: Double = 0.12

    struct Territory {
        let key: String     // "col:<id>" or "tag:<name>"
        let name: String    // display name (collection or tag)
    }

    struct Layout {
        var positions: [String: CanvasPosition] = [:]
        /// nodeID → territory key (tint + provenance source). Absent = unanchored.
        var nodeTerritory: [String: String] = [:]
        /// Ordered territories (palette + label order). Stable across recomputes
        /// (sorted by key) so palette assignment is deterministic.
        var territories: [Territory] = []
        /// Territory key → center (SwiftUI space).
        var centers: [String: CGPoint] = [:]
        /// Territory key → embedding centroid. Retained so a single new node can
        /// be argmax-placed against the FROZEN formation (drift-in) without
        /// re-running the whole pass. Empty for territories with no vectors.
        var centroids: [String: [Float]] = [:]
    }

    /// Tunable signal weights (the "gravity" strengths). T calibrates on device;
    /// bake later. Not a priority ladder — every signal a node has pulls it, and
    /// it settles at the weighted blend.
    struct SignalWeights {
        var collection: Double = 1.0
        var anchor: Double = 0.6
        var language: Double = 0.3
        /// Backlink gravity — pulls a node toward its connected nodes. Does NOT
        /// enter the argmax (territory law wins); a bounded positional nudge.
        var backlink: Double = 0.4
        static let `default` = SignalWeights()
    }

    static func positions(nodes: [Node], anchors: [Tag], collections: [NodeCollection] = [],
                          weights: SignalWeights = .default,
                          radii: [String: CGFloat] = [:]) -> [String: CanvasPosition] {
        layout(nodes: nodes, anchors: anchors, collections: collections, weights: weights, radii: radii).positions
    }

    static func layout(nodes: [Node], anchors: [Tag], collections: [NodeCollection] = [],
                       weights: SignalWeights = .default,
                       radii: [String: CGFloat] = [:]) -> Layout {
        guard !nodes.isEmpty else { return Layout() }

        let userCollections = collections.filter { !$0.isCorpus && !$0.isJournal && $0.id != NodeCollection.librarianSessionsID }
        let collectionByID = Dictionary(userCollections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let anchorSet = Set(anchors.map(\.name))

        // 1. Territories = collections + anchor tags, by DIRECT membership (a
        //    node can belong to several; that's the whole point of a blend).
        var directMembers: [String: [Node]] = [:]
        var name: [String: String] = [:]
        for node in nodes {
            for cid in node.collectionIDs where collectionByID[cid] != nil {
                let key = "col:" + cid
                directMembers[key, default: []].append(node)
                name[key] = collectionByID[cid]?.name
            }
            for tag in node.tags where anchorSet.contains(tag) {
                let key = "tag:" + tag
                directMembers[key, default: []].append(node)
                name[key] = tag
            }
        }
        guard !directMembers.isEmpty else { return Layout() }

        // 2. Territory embedding centroids (from direct members).
        var centroid: [String: [Float]] = [:]
        for (key, ms) in directMembers {
            let vecs = ms.compactMap { SubstrateLayoutService.shared.substrateVector(for: $0) }
            if let c = mean(vecs) { centroid[key] = c }
        }

        // 3. WINNER (argmax) + RUNNER-UP. Each node's weighted pull toward every
        //    territory (collection + anchor + language×similarity); it BELONGS to
        //    its argmax territory (one winner — hard membership), and its
        //    runner-up biases it toward that border.
        var members: [String: [Node]] = [:]
        var nodeTerritory: [String: String] = [:]
        var runnerUp: [String: (key: String, ratio: Double)] = [:]
        var unanchored: [Node] = []
        for node in nodes {
            var pull: [String: Double] = [:]
            for cid in node.collectionIDs where collectionByID[cid] != nil {
                pull["col:" + cid, default: 0] += weights.collection
            }
            for tag in node.tags where anchorSet.contains(tag) {
                pull["tag:" + tag, default: 0] += weights.anchor
            }
            if weights.language > 0, let vec = SubstrateLayoutService.shared.substrateVector(for: node) {
                for (key, cen) in centroid {
                    let s = max(0, cosine(vec, cen) ?? 0)
                    if s > 0 { pull[key, default: 0] += weights.language * s }
                }
            }
            // Deterministic argmax: sort by pull descending, then key ascending
            // as a stable tiebreaker. Without the tiebreak, two territories with
            // EQUAL pull (e.g. a node carrying two anchor tags, both weight 0.6)
            // order by Dictionary iteration — so the winner (and therefore which
            // territory labels render at all) flips run-to-run on identical
            // membership. That was the shifting-names non-determinism.
            let ranked = pull.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            guard let win = ranked.first, win.value > 0 else { unanchored.append(node); continue }
            members[win.key, default: []].append(node)
            nodeTerritory[node.id] = win.key
            if ranked.count > 1, ranked[1].value > 0 {
                runnerUp[node.id] = (ranked[1].key, min(1, ranked[1].value / win.value))
            }
        }

        // 4. CONTINENT SPACING — footprint pack the winner territories.
        // Sorted (not raw Dictionary order) so territory order — and therefore
        // palette-color assignment downstream — is DETERMINISTIC across recomputes.
        let keys = members.keys.sorted()
        let center = continentSpacing(keys: keys, centroid: centroid,
                                      memberCounts: members.mapValues { $0.count })

        // 5. HARD footprint packing within each territory (radius-aware,
        //    non-overlapping), then biases.
        // 5a. Base positions — the SAME footprint law used for continents, applied
        //    to member nodes by their ACTUAL radii, so a big node (e.g.
        //    "Project: AirPad") claims its real footprint instead of a uniform slot.
        var basePos: [String: CGPoint] = [:]
        for (key, ms) in members {
            for (id, p) in footprintPack(ms, around: center[key] ?? .zero, radii: radii) { basePos[id] = p }
        }
        // 5b. Runner-up border bias + backlink gravity, off the base positions.
        var out: [String: CanvasPosition] = [:]
        for (key, ms) in members {
            let winCenter = center[key] ?? .zero
            for node in ms {
                var p = basePos[node.id] ?? winCenter
                // Runner-up shifts the node toward that border.
                if let ru = runnerUp[node.id], let ruCenter = center[ru.key] {
                    let dx = ruCenter.x - winCenter.x, dy = ruCenter.y - winCenter.y
                    let d = max(1, hypot(dx, dy))
                    let bias = CGFloat(ru.ratio) * borderBias
                    p.x += dx / d * bias
                    p.y += dy / d * bias
                }
                // Backlink gravity — pull toward connected nodes' centroid,
                // CAPPED so territory law still wins (a nudge, not an escape).
                if weights.backlink > 0 {
                    let linked = node.connections.compactMap { basePos[$0.nodeID] }
                    if !linked.isEmpty {
                        let tx = linked.map(\.x).reduce(0, +) / CGFloat(linked.count)
                        let ty = linked.map(\.y).reduce(0, +) / CGFloat(linked.count)
                        let dx = tx - p.x, dy = ty - p.y
                        let d = max(1, hypot(dx, dy))
                        let move = min(min(CGFloat(weights.backlink) * backlinkPull, backlinkCap), d)
                        p.x += dx / d * move
                        p.y += dy / d * move
                    }
                }
                out[node.id] = CanvasPosition(x: Double(p.x), y: Double(p.y))
            }
        }

        // Nodes with no signal at all → the unanchored edge region.
        let edge = CGPoint(x: 0, y: territoryRingRadius * 1.95)
        merge(ringPack(unanchored, around: edge), into: &out)

        // 6. HARD repulsion floor — the biases (border + backlink) can push
        //    nodes into overlap; relax so no two sit closer than a node gap at
        //    rest. Grid-accelerated so it stays O(n) per pass. Radius-aware:
        //    bigger nodes claim more room (min gap = r_i + r_j + padding).
        relaxOverlaps(&out, radii: radii)

        let territories = keys.map { Territory(key: $0, name: name[$0] ?? $0) }
        // Retain centroids for winner territories only (the ones that became
        // `keys`) so drift-in placement argmaxes against the same set.
        let winnerCentroids = centroid.filter { members[$0.key] != nil }
        return Layout(positions: out, nodeTerritory: nodeTerritory,
                      territories: territories, centers: center,
                      centroids: winnerCentroids)
    }

    /// Drift a single NEW node into a FROZEN formation without re-deriving it.
    /// Argmax the node's pull toward the cached territories (collection/anchor
    /// direct membership, else nearest cached embedding centroid by language
    /// cosine — the same rule as `layout`), and seed it near that territory's
    /// cached center. Unanchored → the edge region. Existing nodes are never
    /// touched; the scene's repulsion relaxes the seed into a free slot.
    /// Returns `(key, position)` — key is the winning territory (nil = unanchored)
    /// so the caller can tint the new dot to match its territory.
    static func driftPlacement(for node: Node, anchors: [Tag], collections: [NodeCollection] = [],
                               weights: SignalWeights = .default,
                               in layout: Layout) -> (key: String?, position: CanvasPosition) {
        let userCollections = collections.filter { !$0.isCorpus && !$0.isJournal && $0.id != NodeCollection.librarianSessionsID }
        let collectionByID = Dictionary(userCollections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let anchorSet = Set(anchors.map(\.name))

        var pull: [String: Double] = [:]
        for cid in node.collectionIDs where collectionByID[cid] != nil {
            pull["col:" + cid, default: 0] += weights.collection
        }
        for tag in node.tags where anchorSet.contains(tag) {
            pull["tag:" + tag, default: 0] += weights.anchor
        }
        if weights.language > 0, let vec = SubstrateLayoutService.shared.substrateVector(for: node) {
            for (key, cen) in layout.centroids {
                let s = max(0, cosine(vec, cen) ?? 0)
                if s > 0 { pull[key, default: 0] += weights.language * s }
            }
        }
        // Only territories that exist in the frozen formation are candidates.
        // Same deterministic argmax as `layout` (value desc, key asc tiebreak).
        let winner = pull.filter { layout.centers[$0.key] != nil }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .first

        // Small deterministic jitter off the center so the seed doesn't land
        // exactly on an existing node before physics relaxes it.
        let h = abs(node.id.hashValue)
        let jx = CGFloat(h % 61) - 30
        let jy = CGFloat((h / 61) % 61) - 30

        if let winner, winner.value > 0, let center = layout.centers[winner.key] {
            return (winner.key, CanvasPosition(x: Double(center.x + jx), y: Double(center.y + jy)))
        }
        let edge = CGPoint(x: 0, y: territoryRingRadius * 1.95)
        return (nil, CanvasPosition(x: Double(edge.x + jx), y: Double(edge.y + jy)))
    }

    /// Clear space between two node EDGES at rest (added to each pair's radii).
    private static let nodeGapPadding: Double = 24
    /// Fallback radius when a node isn't in the radii map (≈ base bubble).
    private static let defaultNodeRadius: Double = 26

    private static func relaxOverlaps(_ positions: inout [String: CanvasPosition],
                                      radii: [String: CGFloat]) {
        guard positions.count > 1 else { return }
        let ids = Array(positions.keys)
        func radius(_ id: String) -> Double {
            radii[id].map(Double.init) ?? defaultNodeRadius
        }
        // Grid cell must cover the largest possible interaction distance so
        // overlapping pairs always share or neighbour a cell.
        let maxR = ids.map(radius).max() ?? defaultNodeRadius
        let cell = 2 * maxR + nodeGapPadding
        func cellKey(_ gx: Int64, _ gy: Int64) -> Int64 { gx &* 1_000_003 &+ gy }
        func gxy(_ p: CanvasPosition) -> (Int64, Int64) {
            (Int64((p.x / cell).rounded(.down)), Int64((p.y / cell).rounded(.down)))
        }
        // Iterate to CONVERGENCE (bounded), not a fixed count: a single big node
        // can need many passes of half-pushes to fully clear its neighbours, so a
        // fixed 10 left residual overlap at rest. Break as soon as a whole pass
        // finds nothing closer than a node gap — solidity then holds at rest.
        let maxPasses = 48
        for _ in 0..<maxPasses {
            var grid: [Int64: [String]] = [:]
            for id in ids { let (gx, gy) = gxy(positions[id]!); grid[cellKey(gx, gy), default: []].append(id) }
            var disp: [String: (dx: Double, dy: Double)] = [:]
            var anyOverlap = false
            for id in ids {
                let p = positions[id]!
                let (gx, gy) = gxy(p)
                let ri = radius(id)
                for ox in -1...1 {
                    for oy in -1...1 {
                        guard let bucket = grid[cellKey(gx + Int64(ox), gy + Int64(oy))] else { continue }
                        for other in bucket where other != id {
                            let q = positions[other]!
                            let minGap = ri + radius(other) + nodeGapPadding
                            let dx = p.x - q.x, dy = p.y - q.y
                            let d = (dx * dx + dy * dy).squareRoot()
                            if d > 0.001, d < minGap {
                                anyOverlap = true
                                let push = (minGap - d) / 2
                                disp[id, default: (0, 0)].dx += (dx / d) * push
                                disp[id]!.dy += (dy / d) * push
                            } else if d <= 0.001 {
                                // Exact tie — deterministic nudge so they separate.
                                anyOverlap = true
                                let n = Double(abs(id.hashValue) % 8) - 3.5
                                disp[id, default: (0, 0)].dx += n
                                disp[id]!.dy += Double(abs(other.hashValue) % 8) - 3.5
                            }
                        }
                    }
                }
            }
            if !anyOverlap { break }
            for id in ids {
                positions[id]!.x += disp[id]?.dx ?? 0
                positions[id]!.y += disp[id]?.dy ?? 0
            }
        }
    }

    /// Max shift toward a runner-up territory's border (scaled by runner-up strength).
    private static let borderBias: CGFloat = 130
    /// Backlink pull per unit weight, and its hard cap (so territory law wins).
    private static let backlinkPull: CGFloat = 110
    private static let backlinkCap: CGFloat = 220

    // MARK: - Continent spacing (footprint-aware circle packing)

    /// Gap between territory circles.
    private static let territoryMargin: CGFloat = 90

    /// Territory centers by NON-OVERLAPPING circle packing. Each territory's
    /// circle radius comes from its member count (`packedRadius` — the same ring
    /// packing the members use + a node's extent), so the circle always
    /// contains its nodes. Centroid similarity only ORDERS adjacency: territories
    /// are packed in a greedy similarity chain, so similar ones are placed
    /// consecutively onto the growing front and land next to each other.
    /// Non-overlap is a hard constraint (enforced in `firstFreeSlot`).
    private static func continentSpacing(keys: [String], centroid: [String: [Float]],
                                         memberCounts: [String: Int]) -> [String: CGPoint] {
        guard !keys.isEmpty else { return [:] }
        let radius = Dictionary(uniqueKeysWithValues:
            keys.map { ($0, packedRadius(memberCounts[$0] ?? 1) + 46) })
        let order = similarityOrder(keys: keys, centroid: centroid, memberCounts: memberCounts)

        var placed: [(pos: CGPoint, r: CGFloat)] = []
        var pos: [String: CGPoint] = [:]
        for key in order {
            let r = radius[key] ?? 60
            let p = firstFreeSlot(r: r, placed: placed)
            pos[key] = p
            placed.append((p, r))
        }
        return pos
    }

    /// Greedy similarity chain: start from the largest territory, then repeatedly
    /// append the not-yet-placed territory most similar to the last one — so
    /// similar territories are consecutive (adjacent when packed).
    private static func similarityOrder(keys: [String], centroid: [String: [Float]],
                                        memberCounts: [String: Int]) -> [String] {
        guard keys.count > 2 else {
            return keys.sorted { (memberCounts[$0] ?? 0) > (memberCounts[$1] ?? 0) }
        }
        var remaining = Set(keys)
        var order: [String] = []
        var current = keys.max { (memberCounts[$0] ?? 0) < (memberCounts[$1] ?? 0) } ?? keys[0]
        order.append(current); remaining.remove(current)
        while !remaining.isEmpty {
            let cur = current
            let next = remaining.max { sim(cur, $0, centroid) < sim(cur, $1, centroid) } ?? remaining.first!
            order.append(next); remaining.remove(next); current = next
        }
        return order
    }

    private static func sim(_ a: String, _ b: String, _ centroid: [String: [Float]]) -> Double {
        guard let ca = centroid[a], let cb = centroid[b], let s = cosine(ca, cb) else { return -1 }
        return s
    }

    /// Innermost slot (spiral out from origin) that clears every placed circle by
    /// `territoryMargin`. The hard non-overlap constraint.
    private static func firstFreeSlot(r: CGFloat, placed: [(pos: CGPoint, r: CGFloat)]) -> CGPoint {
        if placed.isEmpty { return .zero }
        var rad: CGFloat = 0
        while rad < 20000 {
            let steps = max(12, Int(2 * .pi * rad / 50))
            for s in 0..<steps {
                let a = 2 * .pi * CGFloat(s) / CGFloat(steps)
                let cand = CGPoint(x: cos(a) * rad, y: sin(a) * rad)
                if placed.allSatisfy({ hypot(cand.x - $0.pos.x, cand.y - $0.pos.y) >= (r + $0.r + territoryMargin) }) {
                    return cand
                }
            }
            rad += 40
        }
        return CGPoint(x: rad, y: 0)
    }

    /// Outer radius of the concentric member ring-pack for `count` nodes — same
    /// ring math `ringPack` uses, so a territory circle contains its members.
    private static func packedRadius(_ count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        var remaining = count, ring = 0
        while remaining > 0 {
            let capacity = ring == 0 ? 1 : max(1, Int(2 * .pi * CGFloat(ring)))
            remaining -= capacity
            ring += 1
        }
        return CGFloat(max(0, ring - 1)) * nodeRingSpacing
    }

    // MARK: - Helpers

    /// Radius-aware footprint packing WITHIN a territory — the same non-overlap
    /// law used for continents, applied to member nodes by their ACTUAL radii.
    /// Largest nodes anchor near the centre; smaller ones fill the gaps, so big
    /// nodes claim their real footprint instead of a uniform ring slot.
    private static func footprintPack(_ nodes: [Node], around center: CGPoint,
                                      radii: [String: CGFloat]) -> [String: CGPoint] {
        func slotRadius(_ id: String) -> CGFloat {
            (radii[id] ?? CGFloat(defaultNodeRadius)) + CGFloat(nodeGapPadding) / 2
        }
        // Largest first for a stable, tight pack.
        let ordered = nodes.sorted { slotRadius($0.id) > slotRadius($1.id) }
        var placed: [(pos: CGPoint, r: CGFloat)] = []
        var out: [String: CGPoint] = [:]
        for node in ordered {
            let r = slotRadius(node.id)
            let p = firstFreeNodeSlot(r: r, around: center, placed: placed)
            out[node.id] = p
            placed.append((p, r))
        }
        return out
    }

    /// Innermost slot spiralling out from `center` that clears every placed node
    /// circle edge-to-edge — the within-territory non-overlap constraint (mirrors
    /// `firstFreeSlot` for continents, but with node gaps rather than territory margin).
    private static func firstFreeNodeSlot(r: CGFloat, around center: CGPoint,
                                          placed: [(pos: CGPoint, r: CGFloat)]) -> CGPoint {
        if placed.isEmpty { return center }
        var rad: CGFloat = 0
        while rad < 20000 {
            let steps = max(10, Int(2 * .pi * rad / 36))
            for s in 0..<steps {
                let a = 2 * .pi * CGFloat(s) / CGFloat(steps)
                let cand = CGPoint(x: center.x + cos(a) * rad, y: center.y + sin(a) * rad)
                if placed.allSatisfy({ hypot(cand.x - $0.pos.x, cand.y - $0.pos.y) >= (r + $0.r) }) {
                    return cand
                }
            }
            rad += 14
        }
        return CGPoint(x: center.x + rad, y: center.y)
    }

    private static func ringPack(_ nodes: [Node], around center: CGPoint) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        var remaining = nodes
        var ring = 0
        while !remaining.isEmpty {
            let radius = CGFloat(ring) * nodeRingSpacing
            let capacity = ring == 0 ? 1 : max(1, Int((2 * .pi * radius) / nodeRingSpacing))
            let forRing = Array(remaining.prefix(capacity))
            remaining.removeFirst(forRing.count)
            let step = (2 * .pi) / CGFloat(forRing.count)
            for (i, node) in forRing.enumerated() {
                let a = CGFloat(i) * step
                positions[node.id] = CGPoint(x: center.x + cos(a) * radius,
                                             y: center.y + sin(a) * radius)
            }
            ring += 1
        }
        return positions
    }

    private static func merge(_ pts: [String: CGPoint], into out: inout [String: CanvasPosition]) {
        for (id, p) in pts { out[id] = CanvasPosition(x: Double(p.x), y: Double(p.y)) }
    }

    private static func mean(_ vecs: [[Float]]) -> [Float]? {
        guard let first = vecs.first else { return nil }
        let dim = first.count
        var acc = [Float](repeating: 0, count: dim)
        var count: Float = 0
        for v in vecs where v.count == dim {
            for i in 0..<dim { acc[i] += v[i] }
            count += 1
        }
        guard count > 0 else { return nil }
        return acc.map { $0 / count }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return nil }
        return Double(dot / (na.squareRoot() * nb.squareRoot()))
    }
}
