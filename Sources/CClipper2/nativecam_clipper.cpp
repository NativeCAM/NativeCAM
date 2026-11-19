#include "nativecam_clipper.h"

#include "clipper2/clipper.h"

#include <cstdlib>
#include <cstring>

using namespace Clipper2Lib;

static Paths64 to_paths(const ncl_paths_in &in) {
    Paths64 out;
    out.reserve(in.path_count);
    size_t cursor = 0;
    for (size_t i = 0; i < in.path_count; ++i) {
        Path64 path;
        path.reserve(in.counts[i]);
        for (size_t j = 0; j < in.counts[i]; ++j) {
            const ncl_point &p = in.points[cursor + j];
            path.emplace_back(p.x, p.y);
        }
        cursor += in.counts[i];
        out.push_back(std::move(path));
    }
    return out;
}

static ncl_paths *from_paths(const Paths64 &paths) {
    ncl_paths *out = static_cast<ncl_paths *>(std::calloc(1, sizeof(ncl_paths)));
    if (!out) return nullptr;
    size_t total = 0;
    for (const auto &p : paths) total += p.size();
    out->path_count = paths.size();
    out->point_count = total;
    out->counts = static_cast<size_t *>(std::calloc(paths.size() ? paths.size() : 1, sizeof(size_t)));
    out->points = static_cast<ncl_point *>(std::calloc(total ? total : 1, sizeof(ncl_point)));
    if (!out->counts || !out->points) {
        ncl_paths_free(out);
        return nullptr;
    }
    size_t cursor = 0;
    for (size_t i = 0; i < paths.size(); ++i) {
        out->counts[i] = paths[i].size();
        for (const auto &pt : paths[i]) {
            out->points[cursor].x = pt.x;
            out->points[cursor].y = pt.y;
            ++cursor;
        }
    }
    return out;
}

extern "C" ncl_paths *ncl_inflate(ncl_paths_in in, double delta, ncl_join join, ncl_end end,
                                  double miter_limit, double arc_tolerance) {
    try {
        Paths64 subject = to_paths(in);
        ClipperOffset offsetter(miter_limit, arc_tolerance);
        offsetter.AddPaths(subject, static_cast<JoinType>(join), static_cast<EndType>(end));
        Paths64 solution;
        offsetter.Execute(delta, solution);
        return from_paths(solution);
    } catch (...) {
        return nullptr;
    }
}

extern "C" ncl_paths *ncl_boolean(ncl_clip clip_type, ncl_fill fill,
                                  ncl_paths_in subjects, ncl_paths_in open_subjects, ncl_paths_in clips,
                                  ncl_paths **open_out) {
    try {
        Clipper64 clipper;
        clipper.AddSubject(to_paths(subjects));
        if (open_subjects.path_count > 0) clipper.AddOpenSubject(to_paths(open_subjects));
        clipper.AddClip(to_paths(clips));
        Paths64 closed, open;
        clipper.Execute(static_cast<ClipType>(clip_type), static_cast<FillRule>(fill), closed, open);
        if (open_out) *open_out = from_paths(open);
        return from_paths(closed);
    } catch (...) {
        if (open_out) *open_out = nullptr;
        return nullptr;
    }
}

extern "C" void ncl_paths_free(ncl_paths *paths) {
    if (!paths) return;
    std::free(paths->counts);
    std::free(paths->points);
    std::free(paths);
}
