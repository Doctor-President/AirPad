//  MSDFBridge.h
//  Brief BE1 — Objective-C++ bridge from Core Text outlines to msdfgen.
//
//  PROOF-OF-CONCEPT (spike/be-generator). The point of this file is to answer one
//  question: can we generate, on device, the SAME atlas format the Map shader already
//  consumes, from a font resolved through Core Text — so SF Pro / New York can appear on
//  the Map legitimately (Apple's licence forbids bundling their outlines; drawing through
//  iOS at runtime is ordinary app use).
//
//  Everything C++ stays behind this header so Swift never sees msdfgen's types.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>

NS_ASSUME_NONNULL_BEGIN

/// One generated glyph: its MSDF bitmap plus the metrics the atlas JSON needs.
/// Geometry is in EM units with a baseline origin, matching msdf-atlas-gen's `planeBounds`
/// so the existing `MSDFLabel` layout maths is unchanged.
@interface MSDFGlyphResult : NSObject
@property (nonatomic, readonly) uint32_t unicode;
@property (nonatomic, readonly) double advance;        ///< em
@property (nonatomic, readonly) BOOL hasBitmap;        ///< NO for space / empty outline
/// RGB8, `width * height * 3` bytes, row 0 = BOTTOM (msdf-atlas-gen `-yorigin bottom`).
@property (nonatomic, readonly, nullable) NSData *rgb;
@property (nonatomic, readonly) int width;
@property (nonatomic, readonly) int height;
/// planeBounds in em, baseline origin.
@property (nonatomic, readonly) double planeLeft, planeBottom, planeRight, planeTop;
@end

@interface MSDFBridge : NSObject

/// Generate an MSDF for one character of `font`.
///
/// @param pxPerEm    atlas resolution (the shipping atlases use 48)
/// @param pxRange    distance-field spread in texels (shipping: 4)
/// @param overlap    enable msdfgen's overlapping-contour combiner. **Required for system
///                   variable fonts** — SF Pro's instances can emit self-overlapping
///                   contours, the classic source of MSDF corruption at joins.
/// Returns nil only if the character has no glyph in `font`.
+ (nullable MSDFGlyphResult *)generateForCharacter:(uint32_t)codepoint
                                              font:(CTFontRef)font
                                           pxPerEm:(double)pxPerEm
                                           pxRange:(double)pxRange
                                    overlapSupport:(BOOL)overlap;

/// msdfgen version, so a generated atlas can be cache-keyed by generator version.
+ (NSString *)generatorVersion;

@end

NS_ASSUME_NONNULL_END
