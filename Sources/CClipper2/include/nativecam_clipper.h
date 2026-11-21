// C bridge over the vendored Clipper2 library so Swift can call it without C++ interop.
// All coordinates are 64-bit integers; the Swift side scales real units into this space.

#ifndef NATCAM_CLIPPER_H
#define NATCAM_CLIPPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int64_t x;
    int64_t y;
} ncl_point;

/// A flat list of paths: path i owns points [offsets[i], offsets[i] + counts[i]).
typedef struct {
    size_t path_count;
    const size_t *counts;
    const ncl_point *points;
} ncl_paths_in;

/// Result paths allocated by the bridge. Release with ncl_paths_free.
typedef struct {
    size_t path_count;
    size_t *counts;
    ncl_point *points;
    size_t point_count;
} ncl_paths;

typedef enum { NCL_JOIN_SQUARE = 0, NCL_JOIN_BEVEL = 1, NCL_JOIN_ROUND = 2, NCL_JOIN_MITER = 3 } ncl_join;
typedef enum { NCL_END_POLYGON = 0, NCL_END_JOINED = 1, NCL_END_BUTT = 2, NCL_END_SQUARE = 3, NCL_END_ROUND = 4 } ncl_end;
typedef enum { NCL_CLIP_INTERSECTION = 1, NCL_CLIP_UNION = 2, NCL_CLIP_DIFFERENCE = 3, NCL_CLIP_XOR = 4 } ncl_clip;
typedef enum { NCL_FILL_EVENODD = 0, NCL_FILL_NONZERO = 1, NCL_FILL_POSITIVE = 2, NCL_FILL_NEGATIVE = 3 } ncl_fill;

/// Offsets (inflates when delta > 0, shrinks when delta < 0) closed or open paths.
ncl_paths *ncl_inflate(ncl_paths_in in, double delta, ncl_join join, ncl_end end,
                       double miter_limit, double arc_tolerance);

/// Boolean operation on closed subject/clip paths, plus optional open subject paths.
/// Closed results go to the return value; clipped open paths go to *open_out when it is non-null.
ncl_paths *ncl_boolean(ncl_clip clip_type, ncl_fill fill,
                       ncl_paths_in subjects, ncl_paths_in open_subjects, ncl_paths_in clips,
                       ncl_paths **open_out);

/// Minkowski sum of the first path of `pattern` swept along the first path of `path` (Clipper2's MinkowskiSum: the
/// union, non-zero, of one quad per pair of edges). For closed paths that is the sum of the two boundaries; callers add
/// the filled interiors themselves.
ncl_paths *ncl_minkowski_sum(ncl_paths_in pattern, ncl_paths_in path, int closed);

/// Triangles covering closed, non-intersecting paths (Clipper2's Triangulate, Delaunay). Null when they can't be
/// triangulated (intersecting paths, say).
ncl_paths *ncl_triangulate(ncl_paths_in paths);

void ncl_paths_free(ncl_paths *paths);

#ifdef __cplusplus
}
#endif

#endif
