#if DEBUG
import UIKit
import CoreText

/// Brief BE1 — `-MSDFGenProof`. Generates atlases on device/Simulator for the three faces
/// that decide the question, logs time/memory/bytes, and writes the PNG+JSON to Documents
/// so they can be pulled and diffed against the baked atlas.
enum MSDFGenProof {

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-MSDFGenProof") else { return }
        DispatchQueue.global(qos: .userInitiated).async { run() }
    }

    private static func run() {
        NSLog("[MSDFGEN] generator=%@ charset=%d codepoints",
              MSDFBridge.generatorVersion(), MSDFAtlasGenerator.defaultCharset.count)

        var faces: [(String, CTFont)] = []

        // 1 — SF Pro Condensed Bold. The Label-role candidate that CANNOT be bundled.
        let sfBase = UIFont.systemFont(ofSize: 1, weight: .bold, width: .condensed)
        faces.append(("sfpro-condensed-bold", sfBase as CTFont))

        // 2 — New York Bold (system serif).
        let nyBase = UIFont.systemFont(ofSize: 1, weight: .bold)
        if let d = nyBase.fontDescriptor.withDesign(.serif) {
            faces.append(("newyork-bold", UIFont(descriptor: d, size: 1) as CTFont))
        }

        // 3 — CONTROL: Space Grotesk Bold from tools/fonts, the face the shipping atlas was
        //     baked from. If the generated atlas matches the baked one, the pipeline is sound.
        if let ctrl = controlFont() {
            faces.append(("spacegrotesk-bold-CONTROL", ctrl))
        } else {
            NSLog("[MSDFGEN] CONTROL SKIPPED — SpaceGrotesk-Bold.ttf not registered in this build")
        }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for (name, font) in faces {
            let a = MSDFAtlasGenerator.generate(font: font)
            NSLog("[MSDFGEN] %@ | %.2fs | %.1f MB | %d/%d glyphs | %dx%d | png %d B | json %d B",
                  name, a.seconds, a.peakMemoryMB, a.glyphCount, a.requestedCount,
                  a.width, a.height, a.png.count, a.json.count)
            try? a.png.write(to: dir.appendingPathComponent("\(name)_msdf.png"))
            try? a.json.write(to: dir.appendingPathComponent("\(name)_msdf.json"))
        }
        NSLog("[MSDFGEN] DONE -> %@", dir.path)
    }

    /// The control face. The TTF lives in `tools/fonts` (outside the bundle on purpose), so
    /// for the spike it is registered at runtime if a copy was dropped into the bundle.
    private static func controlFont() -> CTFont? {
        guard let url = Bundle.main.url(forResource: "SpaceGrotesk-Bold", withExtension: "ttf") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return CTFontCreateWithName("SpaceGrotesk-Bold" as CFString, 1, nil)
    }
}
#endif
