#pragma once
// Brief BE1 — hand-written stand-in for the header msdfgen's CMake generates
// (cmake/msdfgen-config.h.in). We compile the core sources directly into the app target
// rather than via CMake, so this supplies the same macros. Values match v1.12.1.
// Empty MSDFGEN_PUBLIC = static linkage into this target (no dllexport/visibility attrs).

#define MSDFGEN_PUBLIC
#define MSDFGEN_EXT_PUBLIC

#define MSDFGEN_VERSION 1.12.1
#define MSDFGEN_VERSION_MAJOR 1
#define MSDFGEN_VERSION_MINOR 12
#define MSDFGEN_VERSION_REVISION 1
#define MSDFGEN_COPYRIGHT_YEAR 2025
