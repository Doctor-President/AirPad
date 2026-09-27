//  MSDFBridge.mm — Brief BE1. Core Text outlines -> msdfgen shapes -> MSDF bitmap.

#import "MSDFBridge.h"
#import "msdfgen.h"

using namespace msdfgen;

@implementation MSDFGlyphResult
- (instancetype)initWithUnicode:(uint32_t)u advance:(double)a rgb:(NSData *)rgb
                          width:(int)w height:(int)h
                           left:(double)l bottom:(double)b right:(double)r top:(double)t {
    if ((self = [super init])) {
        _unicode = u; _advance = a; _rgb = rgb; _width = w; _height = h;
        _hasBitmap = (rgb != nil && w > 0 && h > 0);
        _planeLeft = l; _planeBottom = b; _planeRight = r; _planeTop = t;
    }
    return self;
}
@end

// MARK: - CGPath -> msdfgen::Shape
//
// Core Text hands us outlines in EM-scaled points (we ask for a font of size 1, so the
// coordinates ARE em units, y-up, baseline origin — exactly msdfgen's convention, which is
// why no flip is needed). CGPath's element kinds map 1:1 onto msdfgen edge types.

namespace {

struct PathCtx {
    Shape *shape = nullptr;
    Contour *contour = nullptr;
    Point2 pos = Point2(0, 0);
    Point2 start = Point2(0, 0);
    bool open = false;
};

inline Point2 P(CGPoint p) { return Point2(p.x, p.y); }

void closeIfOpen(PathCtx *c) {
    if (!c->open || !c->contour) return;
    // msdfgen wants an explicitly closed loop; CGPath may leave the final edge implicit.
    if (c->pos != c->start) c->contour->addEdge(EdgeHolder(c->pos, c->start));
    c->open = false;
}

void applyElement(void *info, const CGPathElement *e) {
    PathCtx *c = static_cast<PathCtx *>(info);
    switch (e->type) {
        case kCGPathElementMoveToPoint:
            closeIfOpen(c);
            c->contour = &c->shape->addContour();
            c->pos = c->start = P(e->points[0]);
            c->open = true;
            break;
        case kCGPathElementAddLineToPoint: {
            if (!c->contour) break;
            Point2 p = P(e->points[0]);
            if (p != c->pos) c->contour->addEdge(EdgeHolder(c->pos, p));
            c->pos = p;
            break;
        }
        case kCGPathElementAddQuadCurveToPoint: {
            if (!c->contour) break;
            Point2 ctrl = P(e->points[0]), p = P(e->points[1]);
            c->contour->addEdge(EdgeHolder(c->pos, ctrl, p));
            c->pos = p;
            break;
        }
        case kCGPathElementAddCurveToPoint: {
            if (!c->contour) break;
            Point2 c1 = P(e->points[0]), c2 = P(e->points[1]), p = P(e->points[2]);
            c->contour->addEdge(EdgeHolder(c->pos, c1, c2, p));
            c->pos = p;
            break;
        }
        case kCGPathElementCloseSubpath:
            closeIfOpen(c);
            break;
    }
}

} // namespace

@implementation MSDFBridge

+ (NSString *)generatorVersion {
    return @"msdfgen-1.12.1";
}

+ (nullable MSDFGlyphResult *)generateForCharacter:(uint32_t)codepoint
                                              font:(CTFontRef)font
                                           pxPerEm:(double)pxPerEm
                                           pxRange:(double)pxRange
                                    overlapSupport:(BOOL)overlap {
    // UTF-16 (a codepoint above the BMP needs a surrogate pair).
    UniChar utf16[2]; CFIndex n = 0;
    if (codepoint <= 0xFFFF) { utf16[0] = (UniChar)codepoint; n = 1; }
    else {
        uint32_t v = codepoint - 0x10000;
        utf16[0] = (UniChar)(0xD800 + (v >> 10));
        utf16[1] = (UniChar)(0xDC00 + (v & 0x3FF));
        n = 2;
    }
    CGGlyph glyphs[2] = {0, 0};
    if (!CTFontGetGlyphsForCharacters(font, utf16, glyphs, n) || glyphs[0] == 0) {
        return nil;   // the face has no glyph for this character
    }
    CGGlyph g = glyphs[0];

    // Advance in em. The font was created at size 1, so CT's point advance IS em.
    CGSize adv = CGSizeZero;
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &g, &adv, 1);
    const double advanceEm = adv.width;

    CGPathRef path = CTFontCreatePathForGlyph(font, g, NULL);
    if (!path) {
        // No outline (space, or a blank glyph) — real advance, no bitmap.
        return [[MSDFGlyphResult alloc] initWithUnicode:codepoint advance:advanceEm rgb:nil
                                                  width:0 height:0 left:0 bottom:0 right:0 top:0];
    }

    Shape shape;
    PathCtx ctx; ctx.shape = &shape;
    CGPathApply(path, &ctx, applyElement);
    closeIfOpen(&ctx);
    CGPathRelease(path);

    if (shape.contours.empty()) {
        return [[MSDFGlyphResult alloc] initWithUnicode:codepoint advance:advanceEm rgb:nil
                                                  width:0 height:0 left:0 bottom:0 right:0 top:0];
    }

    shape.normalize();
    // TrueType outlines are y-up with the non-zero winding CGPath gives us; msdfgen needs
    // to know the fill rule orientation is consistent before colouring edges.
    shape.orientContours();
    edgeColoringSimple(shape, 3.0);

    Shape::Bounds b = shape.getBounds();
    // Pad by the distance range so the field isn't clipped at the glyph edge.
    const double padEm = (pxRange + 1.0) / pxPerEm;
    const double l = b.l - padEm, r = b.r + padEm, bo = b.b - padEm, t = b.t + padEm;

    int w = (int)ceil((r - l) * pxPerEm);
    int h = (int)ceil((t - bo) * pxPerEm);
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) {
        return [[MSDFGlyphResult alloc] initWithUnicode:codepoint advance:advanceEm rgb:nil
                                                  width:0 height:0 left:0 bottom:0 right:0 top:0];
    }

    Bitmap<float, 3> msdf(w, h);
    SDFTransformation xf(Projection(Vector2(pxPerEm, pxPerEm), Vector2(-l, -bo)),
                         Range(pxRange / pxPerEm));
    // ★ overlapSupport = the OverlappingContourCombiner path. System variable fonts can
    // emit self-overlapping contours; without this the field corrupts at the joins.
    MSDFGeneratorConfig cfg((bool)overlap);
    generateMSDF(msdf, shape, xf, cfg);

    // Float [0,1] -> RGB8, row 0 = bottom (msdf-atlas-gen `-yorigin bottom`).
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)w * h * 3];
    uint8_t *dst = (uint8_t *)out.mutableBytes;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const float *px = msdf(x, y);
            size_t i = ((size_t)y * w + x) * 3;
            dst[i + 0] = (uint8_t)pixelFloatToByte(px[0]);
            dst[i + 1] = (uint8_t)pixelFloatToByte(px[1]);
            dst[i + 2] = (uint8_t)pixelFloatToByte(px[2]);
        }
    }

    return [[MSDFGlyphResult alloc] initWithUnicode:codepoint advance:advanceEm rgb:out
                                              width:w height:h
                                               left:l bottom:bo right:r top:t];
}

@end
