//! quickstart.zig — the README tour as a runnable file.
//!
//! Open an in-memory database, create a collection, insert three small
//! documents carrying 2-d embeddings, run a kNN vector query under
//! cosine, and print the ranked rows. Every handle is freed on the path
//! that created it (`defer` is the ownership model; `run()` consumes
//! the query builder, so its `deinit` after that is a no-op).
//!
//! Build/run: `zig build run-quickstart`; CI runs it on every platform.

const std = @import("std");
const corvid = @import("corvid");

// docs:begin:quickstart
fn putDoc(docs: corvid.Collection, key: []const u8, title: []const u8, kind: []const u8, v: []const f32) !void {
    var doc = corvid.Value.map();
    defer doc.deinit(); // insert CLONES the value; ours is still ours
    var t = try corvid.Value.text(title);
    try doc.put("title", &t); // moves t into the map
    var k = try corvid.Value.text(kind);
    try doc.put("kind", &k);
    var vec = corvid.Value.vector(v);
    try doc.put("v", &vec);
    try docs.insert(key, doc);
}

pub fn main(init: std.process.Init) u8 {
    var db = corvid.Db.openMemory() catch |e| return fail(e, "open");
    defer db.deinit();
    var docs = db.collection("docs") catch |e| return fail(e, "collection");
    defer docs.deinit();

    putDoc(docs, "p1", "rust embedded database", "doc", &.{ 1.0, 0.0 }) catch |e| return fail(e, "insert");
    putDoc(docs, "p2", "python web frameworks", "doc", &.{ 0.0, 1.0 }) catch |e| return fail(e, "insert");
    putDoc(docs, "p3", "rust again database", "doc", &.{ 0.9, 0.1 }) catch |e| return fail(e, "insert");

    // kNN: the 3 nearest documents to (1, 0) under cosine. The builder
    // methods chain; run() consumes the builder.
    var q = docs.query() catch |e| return fail(e, "query_new");
    defer q.deinit(); // no-op after run()
    var rows = (q
        .vector("v", &.{ 1.0, 0.0 }, 3, .cosine) catch |e| return fail(e, "query_vector")
    ).run() catch |e| return fail(e, "query_run");
    defer rows.deinit();

    var rank: usize = 0;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    while (rows.next()) |row| {
        rank += 1;
        const title = row.doc.mapGet("title").?.textRef().?;
        w.interface.print("{d}. {s} score={d:.6} {s}\n", .{ rank, row.key, @as(f64, row.score), title }) catch {};
    }
    w.interface.flush() catch {};
    return 0;
}
// docs:end:quickstart

fn fail(e: anyerror, what: []const u8) u8 {
    std.debug.print("quickstart: {s} failed: {s} ({s})\n", .{ what, corvid.lastErrorMessage(), @errorName(e) });
    return 1;
}
