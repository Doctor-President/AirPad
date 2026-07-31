import Foundation

/// Stage 5.1 (atomic fields) — in-process self-test for the field schema and
/// its renderer's formatting. Mirrors `EntryMigrationSelfTest` / `UMAPSelfTest`:
/// no XCTest target, returns a one-line-or-multi-line summary suitable for
/// inline display in `SubstrateInspectView` and for a headless launch-arg run
/// (`-FieldSelfTest`, wired in `CorpusStore.load`).
///
/// This is the OBJECTIVE verification the brief specifies — Stage 1 is
/// verifiable by fixtures, not a user flow.
///
/// Coverage:
///   T1  — a node carrying one value of every one of the twelve kinds (plus a
///         scalar range and a multi-value vocabulary) round-trips through
///         `JSONEncoder/Decoder.airPad` losslessly (items compare equal).
///   T2  — the FieldDefinitionStore (versioned envelope) round-trips losslessly.
///   T3  — legacy `node.json` with NO `field` key decodes clean: `field == nil`,
///         other fields preserved — the additive/decode-tolerant guarantee, no
///         entrySchemaVersion bump.
///   T4  — normalizeAtomicsToFront handles `.field` generically: atomics
///         (fields + rating) move to a contiguous front, payload suffix follows,
///         and the authored foldIndex is translated so foldIndex >= atomicCount.
///   T5  — per-kind formatter output (duration flex, boolean, vocabulary join,
///         rating numeric, scalar range, measurement, text-empty→nil, unfilled→nil,
///         nodeReference via resolver; money/date asserted non-empty for locale).
///   T6  — ★ vocabulary references VALUE IDs, not labels: renaming a value's
///         label reformats the SAME stored value (rename-safe / union-mergeable).
@available(iOS 17.0, *)
@MainActor
enum FieldValueSelfTest {

    private static let date0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func run() -> String {
        var failures: [String] = []
        var ran = 0

        let defs = fixtureDefinitions()
        let byKind = Dictionary(uniqueKeysWithValues: defs.map { ($0.kind, $0) })

        // T1 — twelve-kind node round-trips losslessly.
        do {
            ran += 1
            let node = fixtureNode(defs: defs)
            do {
                let data = try JSONEncoder.airPad.encode(node)
                let decoded = try JSONDecoder.airPad.decode(Node.self, from: data)
                if decoded.items != node.items {
                    failures.append("T1: items not equal after round-trip (\(decoded.items.count) vs \(node.items.count))")
                }
                // Spot-check the field payloads survived (not just count).
                let fields = decoded.items.compactMap { $0.field }
                if fields.count != 13 { failures.append("T1: expected 13 field values, got \(fields.count)") }
                if !decoded.items.contains(where: { $0.field?.upperValue != nil }) {
                    failures.append("T1: range upperValue lost in round-trip")
                }
            } catch {
                failures.append("T1: round-trip threw: \(error)")
            }
        }

        // T2 — FieldDefinitionStore round-trips.
        do {
            ran += 1
            let store = FieldDefinitionStore(definitions: defs)
            do {
                let data = try JSONEncoder.airPad.encode(store)
                let decoded = try JSONDecoder.airPad.decode(FieldDefinitionStore.self, from: data)
                if decoded != store { failures.append("T2: FieldDefinitionStore changed across round-trip") }
                if decoded.version != FieldDefinitionStore.currentVersion {
                    failures.append("T2: version \(decoded.version) != \(FieldDefinitionStore.currentVersion)")
                }
            } catch {
                failures.append("T2: round-trip threw: \(error)")
            }
        }

        // T3 — legacy node.json (no `field` key) decodes clean.
        do {
            ran += 1
            let legacyJSON: [String: Any] = [
                "id": "legacy",
                "title": "old",
                "summary": "",
                "tags": [],
                "is_meta": false,
                "threads": [],
                "items": [
                    ["id": "i1", "type": "text", "created_at": "2023-01-15T10:00:00Z", "content": "hello"]
                ],
                "created_at": "2023-01-15T09:00:00Z",
                "updated_at": "2023-01-15T10:00:00Z"
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: legacyJSON)
                let node = try JSONDecoder.airPad.decode(Node.self, from: data)
                if node.items.first?.field != nil { failures.append("T3: legacy item.field should be nil") }
                if node.items.first?.content != "hello" { failures.append("T3: legacy content lost") }
            } catch {
                failures.append("T3: legacy decode threw: \(error)")
            }
        }

        // T4 — normalizeAtomicsToFront handles `.field` generically.
        do {
            ran += 1
            let payloadA = NodeItem(id: "p1", type: .text, createdAt: date0, content: "a")
            let fieldA   = makeField(defs[0], value: .number(1))
            let payloadB = NodeItem(id: "p2", type: .text, createdAt: date0, content: "b")
            let fieldB   = makeField(byKind[.boolean]!, value: .boolean(true))
            let ratingIt = NodeItem(id: "r1", type: .rating, createdAt: date0, rating: Rating(value: 3))
            // raw order: payload, field, payload, field, rating  (foldIndex=3 →
            // two payloads above the fold: payloadA, payloadB)
            var node = makeNode(items: [payloadA, fieldA, payloadB, fieldB, ratingIt], foldIndex: 3)
            CorpusStore.normalizeAtomicsToFront(&node)
            let atomicCount = node.items.filter { $0.type.isAtomic }.count
            if atomicCount != 3 { failures.append("T4: atomicCount \(atomicCount) != 3") }
            // contiguous atomic prefix
            let prefixLen = node.items.prefix(while: { $0.type.isAtomic }).count
            if prefixLen != atomicCount { failures.append("T4: atomic prefix not contiguous (\(prefixLen) vs \(atomicCount))") }
            // no payload before an atomic
            var seenPayload = false
            for it in node.items {
                if it.type.isAtomic && seenPayload { failures.append("T4: atomic after payload"); break }
                if !it.type.isAtomic { seenPayload = true }
            }
            // foldIndex translated: 2 payloads were above the fold → atomicCount + 2 = 5
            if node.foldIndex != atomicCount + 2 { failures.append("T4: foldIndex \(String(describing: node.foldIndex)) != \(atomicCount + 2)") }
            if let f = node.foldIndex, f < atomicCount { failures.append("T4: foldIndex < atomicCount") }
        }

        // T5 — per-kind formatter output.
        do {
            ran += 1
            func fmt(_ kind: FieldKind, _ value: FieldPayload?, upper: FieldPayload? = nil,
                     resolve: @escaping (String) -> String? = { _ in nil }) -> String? {
                let def = byKind[kind]!
                return FieldValueFormatter.display(FieldValue(definitionID: def.id, value: value, upperValue: upper),
                                                   definition: def, resolveNodeTitle: resolve)
            }
            func expect(_ got: String?, _ want: String?, _ label: String) {
                if got != want { failures.append("T5[\(label)]: '\(got ?? "nil")' != '\(want ?? "nil")'") }
            }
            expect(FieldValueFormatter.durationString(2700), "45 min", "dur45")
            expect(FieldValueFormatter.durationString(4500), "1 hr 15", "dur1h15")
            expect(FieldValueFormatter.durationString(3600), "1 hr", "dur1h")
            expect(fmt(.duration, .duration(seconds: 2700)), "45 min", "durKind")
            expect(fmt(.boolean, .boolean(true)), "Yes", "boolTrue")
            expect(fmt(.boolean, .boolean(false)), "No", "boolFalse")
            expect(fmt(.vocabulary, .vocabulary(valueIDs: ["v-fire", "v-flying"])), "Fire, Flying", "vocabMulti")
            expect(fmt(.rating, .rating(4)), "4/5", "ratingNumeric")
            expect(fmt(.number, .number(4), upper: .number(6)), "4\u{2013}6", "numberRange")
            expect(fmt(.measurement, .measurement(amount: 500, unit: "ml")), "500 ml", "measure")
            expect(fmt(.text, .text("hi")), "hi", "text")
            expect(fmt(.text, .text("")), nil, "textEmpty")
            expect(fmt(.number, nil), nil, "unfilled")
            expect(fmt(.nodeReference, .nodeReference(nodeID: "n1"), resolve: { $0 == "n1" ? "Charmander" : nil }), "Charmander", "nodeRef")
            // .url — DISPLAY is HOST + TLD only (scheme, www, AND path dropped)…
            expect(fmt(.url, .url("https://www.example.com/")), "example.com", "urlStrip")
            expect(fmt(.url, .url("https://www.example.com/recipes/roasted-tomato-soup")), "example.com", "urlDropPath")
            expect(fmt(.url, .url("http://example.com/recipes/soup")), "example.com", "urlDropPath2")
            expect(FieldValueFormatter.prettyURL("not a url"), "not a url", "urlUnparseable")
            // …but the STORED value keeps the full URL VERBATIM (display != storage).
            do {
                let raw = "https://www.example.com/"
                let fv = FieldValue(definitionID: byKind[.url]!.id, value: .url(raw))
                let back = try JSONDecoder.airPad.decode(FieldValue.self, from: JSONEncoder.airPad.encode(fv))
                if back.value != .url(raw) { failures.append("T5[urlStore]: stored URL changed — display leaked into storage") }
            } catch { failures.append("T5[urlStore]: threw \(error)") }
            // money + date are locale-dependent; assert only non-empty presence.
            if (fmt(.money, .money(amount: 12, currencyCode: "USD")) ?? "").isEmpty { failures.append("T5[money]: empty") }
            if (fmt(.date, .date(date0, hasTime: false)) ?? "").isEmpty { failures.append("T5[date]: empty") }
        }

        // T6 — vocabulary references VALUE IDs, not labels (rename-safe).
        do {
            ran += 1
            var vdef = byKind[.vocabulary]!
            let value = FieldValue(definitionID: vdef.id, value: .vocabulary(valueIDs: ["v-fire", "v-flying"]))
            let before = FieldValueFormatter.display(value, definition: vdef)
            if before != "Fire, Flying" { failures.append("T6: pre-rename '\(before ?? "nil")' != 'Fire, Flying'") }
            // rename the label of v-fire; the stored value (value IDs) is untouched.
            vdef.config.vocabularyValues = [
                VocabularyValue(id: "v-fire", label: "Fire type"),
                VocabularyValue(id: "v-flying", label: "Flying"),
                VocabularyValue(id: "v-water", label: "Water")
            ]
            let after = FieldValueFormatter.display(value, definition: vdef)
            if after != "Fire type, Flying" { failures.append("T6: post-rename '\(after ?? "nil")' != 'Fire type, Flying' — value not ID-addressed") }
        }

        // T7 — Stage 2: preset REUSE predicate (a preset tapped twice resolves to
        // the SAME definition) + a definition SURVIVES A RELAUNCH (store
        // round-trip, incl. lastUsedAt + config). The predicate here is exactly
        // what `CorpusStore.resolvePreset` matches on; the live store path is
        // device-verified.
        do {
            ran += 1
            let cook = FieldPreset.seeded.first { $0.kind == .duration }!
            // both a preset-made def and a differently-cased manual def match the
            // find-or-create predicate → no second definition is minted.
            let made = cook.makeDefinition()
            let manual = FieldDefinition(displayName: cook.displayName.uppercased(), kind: cook.kind)
            for candidate in [made, manual] {
                let hit = [candidate].first {
                    $0.kind == cook.kind && $0.displayName.lowercased() == cook.displayName.lowercased()
                }
                if hit?.id != candidate.id { failures.append("T7: preset reuse predicate missed '\(candidate.displayName)'") }
            }
            // relaunch survival: persisted form decodes back intact.
            do {
                let stamped = FieldDefinition(displayName: "Serves", kind: .number,
                                              config: FieldConfig(rangeEnabled: true), lastUsedAt: date0)
                let store = FieldDefinitionStore(definitions: [stamped])
                let back = try JSONDecoder.airPad.decode(FieldDefinitionStore.self, from: JSONEncoder.airPad.encode(store))
                if back.definitions.first?.lastUsedAt != date0 { failures.append("T7: lastUsedAt lost across store round-trip") }
                if back.definitions.first?.config.rangeEnabled != true { failures.append("T7: config lost across store round-trip") }
                if back.definitions.first?.id != stamped.id { failures.append("T7: definition id changed across round-trip") }
                // Stage 5.3 — dateHasTime config round-trips.
                let dateDef = FieldDefinition(displayName: "When", kind: .date, config: FieldConfig(dateHasTime: true))
                let dback = try JSONDecoder.airPad.decode(FieldDefinitionStore.self, from: JSONEncoder.airPad.encode(FieldDefinitionStore(definitions: [dateDef])))
                if dback.definitions.first?.config.dateHasTime != true { failures.append("T7: dateHasTime lost across round-trip") }
            } catch { failures.append("T7: store round-trip threw \(error)") }
        }

        // T8 — Stage 3: clear-to-unfilled is a genuinely NULL value (not "" / a
        // sentinel) and round-trips as null; a filled url value is stored VERBATIM
        // (display-only prettyURL never leaks into storage).
        do {
            ran += 1
            do {
                var fv = FieldValue(definitionID: "d", value: .text("hi"))
                fv.value = nil   // the clear-to-unfilled path
                let back = try JSONDecoder.airPad.decode(FieldValue.self, from: JSONEncoder.airPad.encode(fv))
                if back.value != nil { failures.append("T8: cleared value is not nil after round-trip") }
                let raw = "https://WWW.Example.com/Path?q=1"
                let urlFV = FieldValue(definitionID: "d", value: .url(raw))
                let urlBack = try JSONDecoder.airPad.decode(FieldValue.self, from: JSONEncoder.airPad.encode(urlFV))
                if urlBack.value != .url(raw) { failures.append("T8: url value not stored verbatim") }
            } catch { failures.append("T8: threw \(error)") }
        }

        // T9 — Stage 3 C2: a RANGE survives edit+reload; measurement units are a
        // closed set; money/duration values round-trip.
        do {
            ran += 1
            do {
                let ranged = FieldValue(definitionID: "d", value: .number(4), upperValue: .number(6))
                let rback = try JSONDecoder.airPad.decode(FieldValue.self, from: JSONEncoder.airPad.encode(ranged))
                if rback.value != .number(4) || rback.upperValue != .number(6) { failures.append("T9: range lost across round-trip") }
                for dim in MeasurementDimension.allCases where dim.units.isEmpty {
                    failures.append("T9: \(dim.rawValue) has an empty unit list")
                }
                let meas = FieldValue(definitionID: "d", value: .measurement(amount: 500, unit: "ml"))
                if try JSONDecoder.airPad.decode(FieldValue.self, from: JSONEncoder.airPad.encode(meas)).value != .measurement(amount: 500, unit: "ml") {
                    failures.append("T9: measurement value lost")
                }
                let money = FieldValue(definitionID: "d", value: .money(amount: 12, currencyCode: "USD"))
                if try JSONDecoder.airPad.decode(FieldValue.self, from: JSONEncoder.airPad.encode(money)).value != .money(amount: 12, currencyCode: "USD") {
                    failures.append("T9: money value lost")
                }
                let dur = FieldValue(definitionID: "d", value: .duration(seconds: 2700))
                if try JSONDecoder.airPad.decode(FieldValue.self, from: JSONEncoder.airPad.encode(dur)).value != .duration(seconds: 2700) {
                    failures.append("T9: duration value lost")
                }
            } catch { failures.append("T9: threw \(error)") }
        }

        if failures.isEmpty {
            return "FieldValue: \(ran)/\(ran) passed"
        } else {
            return "FieldValue FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: - Fixtures (also used by the DEBUG render harness in CorpusStore.load)

    /// One definition per kind: measurement carries a dimension, rating carries
    /// scale+style, vocabulary carries an ID-addressed value list, and the four
    /// scalars enable ranges.
    static func fixtureDefinitions() -> [FieldDefinition] {
        [
            FieldDefinition(id: "def-number", displayName: "Serves", kind: .number, config: FieldConfig(rangeEnabled: true)),
            FieldDefinition(id: "def-measurement", displayName: "Volume", kind: .measurement, config: FieldConfig(dimension: .volume, rangeEnabled: true)),
            FieldDefinition(id: "def-duration", displayName: "Cook time", kind: .duration, config: FieldConfig(rangeEnabled: true)),
            FieldDefinition(id: "def-date", displayName: "When", kind: .date),
            FieldDefinition(id: "def-money", displayName: "Price", kind: .money, config: FieldConfig(rangeEnabled: true)),
            FieldDefinition(id: "def-rating", displayName: "Rating", kind: .rating, config: FieldConfig(ratingScale: 5, ratingStyle: .stars)),
            FieldDefinition(id: "def-location", displayName: "Place", kind: .location),
            FieldDefinition(id: "def-text", displayName: "Notes", kind: .text),
            FieldDefinition(id: "def-vocabulary", displayName: "Type", kind: .vocabulary, config: FieldConfig(vocabularyValues: [
                VocabularyValue(id: "v-fire", label: "Fire"),
                VocabularyValue(id: "v-flying", label: "Flying"),
                VocabularyValue(id: "v-water", label: "Water")
            ])),
            FieldDefinition(id: "def-boolean", displayName: "Owned", kind: .boolean),
            FieldDefinition(id: "def-url", displayName: "Source", kind: .url),
            FieldDefinition(id: "def-noderef", displayName: "Evolves from", kind: .nodeReference)
        ]
    }

    /// A node carrying one value of every kind, plus a scalar RANGE (number
    /// 4–6) and a MULTI-value vocabulary (Fire + Flying). Thirteen `.field`
    /// items in total (twelve kinds + one extra ranged scalar is folded into
    /// the number value, so exactly one per kind = 12 filled + 1 unfilled).
    static func fixtureNode(defs: [FieldDefinition]) -> Node {
        let byKind = Dictionary(uniqueKeysWithValues: defs.map { ($0.kind, $0) })
        var items: [NodeItem] = [
            makeField(byKind[.number]!, value: .number(4), upper: .number(6)),          // range
            makeField(byKind[.measurement]!, value: .measurement(amount: 500, unit: "ml")),
            makeField(byKind[.duration]!, value: .duration(seconds: 2700)),
            makeField(byKind[.date]!, value: .date(date0, hasTime: false)),
            makeField(byKind[.money]!, value: .money(amount: 12, currencyCode: "USD")),
            makeField(byKind[.rating]!, value: .rating(4)),
            makeField(byKind[.location]!, value: .location(name: "Paris", latitude: nil, longitude: nil)),
            makeField(byKind[.text]!, value: .text("crispy edges")),
            makeField(byKind[.vocabulary]!, value: .vocabulary(valueIDs: ["v-fire", "v-flying"])),  // multi
            makeField(byKind[.boolean]!, value: .boolean(true)),
            makeField(byKind[.url]!, value: .url("https://www.example.com/recipes/roasted-tomato-soup")),
            makeField(byKind[.nodeReference]!, value: .nodeReference(nodeID: "target"))
        ]
        // one present-but-unfilled value, to exercise the nullable state
        items.append(makeField(byKind[.text]!, value: nil))
        // C8 — a LEGACY `.rating` atomic so the fixture exercises coexistence:
        // the old RatingAttributeRow renders (and stays editable via
        // RatingEditSheet) below the new stacked-pairs grid.
        items.append(NodeItem(id: "fixture-legacy-rating", type: .rating, createdAt: date0, rating: Rating(value: 3)))
        return makeNode(items: items, foldIndex: nil)
    }

    // MARK: - Helpers

    private static func makeField(_ def: FieldDefinition, value: FieldPayload?, upper: FieldPayload? = nil) -> NodeItem {
        NodeItem(
            id: "field-\(def.id)-\(value == nil ? "empty" : "v")",
            type: .field,
            createdAt: date0,
            field: FieldValue(definitionID: def.id, value: value, upperValue: upper)
        )
    }

    private static func makeNode(items: [NodeItem], foldIndex: Int?) -> Node {
        Node(
            id: UUID().uuidString,
            createdAt: date0,
            updatedAt: date0,
            title: "field fixture",
            summary: "",
            tags: [],
            items: items,
            foldIndex: foldIndex
        )
    }
}
