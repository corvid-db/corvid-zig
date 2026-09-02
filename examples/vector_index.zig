//! vector_index.zig — three vector-index families, ANN vs exact.
//!
//! A file-backed database (the on-disk index is a disk-resident HNSW
//! graph persisted inside the db file) with eight 4-d documents. The
//! same embedding is stored under three fields so each index family can
//! be demonstrated side by side:
//!
//!   v_mem  — in-memory HNSW              (createVectorIndex)
//!   v_disk — on-disk HNSW                (createVectorIndexOndisk)
//!   v_q    — in-memory binary-quantized   (createVectorIndexQuantized)
//!
//! The exact (streaming-scan) ranking is printed first, then the ANN
//! (approx) ranking served by each index. The unquantized indexes
//! answer identically to the scan on this corpus; the binary-quantized
//! one genuinely diverges — the recall/footprint trade-off quantization
//! makes (binary packs each float32 to one sign bit, ~32x smaller).
//! Finally the db is closed and reopened: the on-disk graph reloads and
//! serves the same ANN answer without a rebuild.
//!
//! Scores are RRF ranks (1/(60 + rank)) — the lone vector source's row
//! score — so they reflect each lane's own ranking.
//!
//! Build/run: `zig build run-vector_index`; CI runs it on every platform.

const std = @import("std");
const corvid = @import("corvid");

const DB_FILE = "example-vector-index.redb";

const PROBE = [4]f32{ 1.0, 0.0, 0.0, 0.0 };

// Eight 4-d documents: the first four near the probe axis, the last
// four near the opposite axis — near-neighbors are unambiguous.
const DOCS = [8][4]f32{
    .{ 1.0, 0.0, 0.1, 0.0 },  .{ 0.95, 0.05, 0.0, 0.0 }, .{ 0.9, 0.1, 0.1, 0.0 }, .{ 1.0, 0.0, 0.0, 0.05 },
    .{ 0.0, 1.0, 0.0, 0.0 },  .{ 0.0, 0.95, 0.05, 0.0 }, .{ 0.1, 0.9, 0.0, 0.1 }, .{ 0.0, 1.0, 0.05, 0.0 },
};

fn fail(e: anyerror, what: []const u8) u8 {
    std.debug.print("vector_index: {s} failed: {s} ({s})\n", .{ what, corvid.lastErrorMessage(), @errorName(e) });
    return 1;
}

fn putDoc(items: corvid.Collection, key: []const u8, v: []const f32) !void {
    var doc = corvid.Value.map();
    defer doc.deinit();
    var a = corvid.Value.vector(v);
    try doc.put("v_mem", &a);
    var b = corvid.Value.vector(v);
    try doc.put("v_disk", &b);
    var q = corvid.Value.vector(v);
    try doc.put("v_q", &q);
    try items.insert(key, doc);
}

// Run a top-4 vector query over `field`, print its ranked keys.
fn runQuery(init: std.process.Init, items: corvid.Collection, field: []const u8, approx: bool, label: []const u8) u8 {
    var q = items.query() catch |e| return fail(e, "query_new");
    defer q.deinit();
    _ = q.vector(field, &PROBE, 4, .cosine) catch |e| return fail(e, "query_vector");
    if (approx) _ = q.approx() catch |e| return fail(e, "query_approx");
    var rows = q.run() catch |e| return fail(e, "query_run");
    defer rows.deinit();

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    w.interface.print("{s:<38}", .{label}) catch {};
    while (rows.next()) |row| {
        w.interface.print(" {s}({d:.6})", .{ row.key, @as(f64, row.score) }) catch {};
    }
    w.interface.print("\n", .{}) catch {};
    w.interface.flush() catch {};
    return 0;
}

pub fn main(init: std.process.Init) u8 {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const say = struct {
        fn print(writer: *std.Io.File.Writer, comptime fmt: []const u8, args: anytype) void {
            writer.interface.print(fmt, args) catch {};
        }
    }.print;

    std.Io.Dir.cwd().deleteTree(init.io, DB_FILE) catch {};

    var db = corvid.Db.open(DB_FILE) catch |e| return fail(e, "open");
    var items = db.collection("items") catch |e| return fail(e, "collection");

    for (DOCS, 0..) |v, i| {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "i{d}", .{i}) catch unreachable;
        putDoc(items, key, &v) catch |e| return fail(e, "insert");
    }

    items.createVectorIndex("v_mem", .cosine) catch |e| return fail(e, "index v_mem");
    items.createVectorIndexOndisk("v_disk", .cosine) catch |e| return fail(e, "index v_disk");
    items.createVectorIndexQuantized("v_q", .cosine, .binary) catch |e| return fail(e, "index v_q");

    say(&w, "corpus: 8 docs, 4-d; probe (1,0,0,0), top-4 cosine\n", .{});
    say(&w, "scores are RRF ranks of each lane's own ranking\n\n", .{});
    w.interface.flush() catch {};

    var rc = runQuery(init, items, "v_mem", false, "exact scan (no index):");
    if (rc != 0) return rc;
    rc = runQuery(init, items, "v_mem", true, "in-memory HNSW (approx):");
    if (rc != 0) return rc;
    rc = runQuery(init, items, "v_disk", true, "on-disk HNSW (approx):");
    if (rc != 0) return rc;
    rc = runQuery(init, items, "v_q", true, "binary-quantized (approx):");
    if (rc != 0) return rc;

    // Close and reopen: the on-disk graph reloads with the file and
    // serves the same ANN answer without a rebuild.
    items.deinit();
    db.deinit();
    say(&w, "\nclose + reopen (on-disk HNSW reloads):\n", .{});
    w.interface.flush() catch {};

    var db2 = corvid.Db.open(DB_FILE) catch |e| return fail(e, "reopen");
    defer db2.deinit();
    var items2 = db2.collection("items") catch |e| return fail(e, "collection 2");
    defer items2.deinit();
    return runQuery(init, items2, "v_disk", true, "on-disk HNSW (approx):");
}
