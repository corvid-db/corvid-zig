//! hybrid.zig — the flagship: filter + vector + BM25, RRF fusion, MMR
//! rerank, limit.
//!
//! Hybrid retrieval over a 4-document corpus: a pre-ranking `kind`
//! filter, a vector (ANN) source and a BM25 text source, both
//! contributing top-2 candidate lists, fused with Reciprocal Rank
//! Fusion (k = 60) and reranked for diversity with MMR (lambda = 1.0),
//! capped at 2 rows. The printed scores are RRF rank sums: s1 is rank 1
//! of both sources (1/61 + 1/61 = 2/61), s3 rank 2 of both (2/62).
//!
//! Build/run: `zig build run-hybrid`; CI runs it on every platform.

const std = @import("std");
const corvid = @import("corvid");

fn fail(e: anyerror, what: []const u8) u8 {
    std.debug.print("hybrid: {s} failed: {s} ({s})\n", .{ what, corvid.lastErrorMessage(), @errorName(e) });
    return 1;
}

// docs:begin:hybrid
fn putDoc(docs: corvid.Collection, key: []const u8, kind: []const u8, body: ?[]const u8, v: ?[]const f32) !void {
    var doc = corvid.Value.map();
    defer doc.deinit();
    var k = try corvid.Value.text(kind);
    try doc.put("kind", &k);
    if (body) |b| {
        var t = try corvid.Value.text(b);
        try doc.put("body", &t);
    }
    if (v) |vec| {
        var val = corvid.Value.vector(vec);
        try doc.put("v", &val);
    }
    try docs.insert(key, doc);
}

fn printRows(init: std.process.Init, rows: *corvid.Rows) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    var rank: usize = 0;
    while (rows.next()) |row| {
        rank += 1;
        const body = row.doc.mapGet("body").?.textRef() orelse "?";
        w.interface.print("{d}. {s} score={d:.6} {s}\n", .{ rank, row.key, @as(f64, row.score), body }) catch {};
    }
    w.interface.flush() catch {};
}

pub fn main(init: std.process.Init) u8 {
    var db = corvid.Db.openMemory() catch |e| return fail(e, "open");
    defer db.deinit();
    var docs = db.collection("docs") catch |e| return fail(e, "collection");
    defer docs.deinit();

    putDoc(docs, "s1", "doc", "rust embedded database", &.{ 1.0, 0.0 }) catch |e| return fail(e, "insert");
    putDoc(docs, "s2", "doc", "python web frameworks", &.{ 0.0, 1.0 }) catch |e| return fail(e, "insert");
    putDoc(docs, "s3", "doc", "rust again database", &.{ 0.9, 0.1 }) catch |e| return fail(e, "insert");
    putDoc(docs, "m1", "meta", null, null) catch |e| return fail(e, "insert"); // filtered out below

    // The flagship query: filter + vector + text, RRF + MMR + limit.
    var q = docs.query() catch |e| return fail(e, "query_new");
    defer q.deinit(); // no-op after run()

    var kind = corvid.Value.text("doc") catch |e| return fail(e, "text");
    defer kind.deinit(); // pred_compare CLONES it; ours is still ours
    var only_docs = corvid.Pred.compare("kind", .eq, kind) catch |e| return fail(e, "pred_compare");
    defer only_docs.deinit(); // safe no-op after filter moves it
    _ = q.filter(&only_docs) catch |e| return fail(e, "query_filter"); // moves the pred

    // The setters mutate the builder and return it, so each step is one
    // statement with its own named failure; run() consumes the builder.
    _ = q.vector("v", &.{ 1.0, 0.0 }, 2, .cosine) catch |e| return fail(e, "query_vector");
    _ = q.text("body", "rust database", 2) catch |e| return fail(e, "query_text");
    _ = q.fuseRrf(60.0) catch |e| return fail(e, "query_fuse_rrf");
    _ = q.rerankMmr(1.0) catch |e| return fail(e, "query_rerank_mmr");
    _ = q.limit(2) catch |e| return fail(e, "query_limit");
    var rows = q.run() catch |e| return fail(e, "query_run");
    defer rows.deinit();
    printRows(init, &rows);
    return 0;
}
// docs:end:hybrid
