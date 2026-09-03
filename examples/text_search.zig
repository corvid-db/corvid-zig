//! text_search.zig — BM25 ranking and POSITIONAL phrase search, English
//! and CJK.
//!
//! Six notes (three English, three CJK) searched two ways:
//!
//!   - the query builder's BM25 source (`Query.text`) — bag-of-words
//!     ranking, row scores are RRF ranks (1/(60 + rank));
//!   - the DIRECT positional search (v0.3.0's `Collection.phraseSearch`)
//!     — documents whose field contains the phrase as a consecutive,
//!     in-order run of analyzed tokens, scored by the phrase's BM25 sum
//!     (its own scale, not the builder's fused RRF).
//!
//! The CJK strings exercise the engine's dictionary-free CJK
//! segmentation: maximal runs of CJK characters are tokenized as
//! sliding BIGRAMS, so an unsegmented CJK query matches by its bigrams —
//! "城市" (city) matches both city notes, "数据库" (database) matches the
//! ML note. Phrase order matters: "database embedded" matches nothing
//! even though both tokens are present; stop words collapse out of
//! adjacency ("embedded the database" ≡ "embedded database"); k == 0 is
//! an empty cursor — inert, never an error.
//!
//! Build/run: `zig build run-text_search`; CI runs it on every platform.

const std = @import("std");
const corvid = @import("corvid");

fn fail(e: anyerror, what: []const u8) u8 {
    std.debug.print("text_search: {s} failed: {s} ({s})\n", .{ what, corvid.lastErrorMessage(), @errorName(e) });
    return 1;
}

// docs:begin:text_search
fn putNote(notes: corvid.Collection, key: []const u8, body: []const u8) !void {
    var doc = corvid.Value.map();
    defer doc.deinit();
    var b = try corvid.Value.text(body);
    try doc.put("body", &b);
    try notes.insert(key, doc);
}

fn searchBm25(init: std.process.Init, notes: corvid.Collection, query: []const u8, label: []const u8) u8 {
    var q = notes.query() catch |e| return fail(e, "query_new");
    defer q.deinit();
    _ = q.text("body", query, 3) catch |e| return fail(e, "query_text");
    var rows = q.run() catch |e| return fail(e, "query_run");
    defer rows.deinit();

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    w.interface.print("{s:<34} ->", .{label}) catch {};
    while (rows.next()) |row| {
        w.interface.print(" {s}({d:.6})", .{ row.key, @as(f64, row.score) }) catch {};
    }
    w.interface.print("\n", .{}) catch {};
    w.interface.flush() catch {};
    return 0;
}

fn searchPhrase(init: std.process.Init, notes: corvid.Collection, phrase: []const u8, k: usize, label: []const u8) u8 {
    var rows = notes.phraseSearch("body", phrase, k) catch |e| return fail(e, "phrase_search");
    defer rows.deinit();

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    w.interface.print("{s:<34} ->", .{label}) catch {};
    var any = false;
    while (rows.next()) |row| {
        any = true;
        w.interface.print(" {s}({d:.6})", .{ row.key, @as(f64, row.score) }) catch {};
    }
    if (!any) w.interface.print(" (none)", .{}) catch {};
    w.interface.print("\n", .{}) catch {};
    w.interface.flush() catch {};
    return 0;
}

pub fn main(init: std.process.Init) u8 {
    var db = corvid.Db.openMemory() catch |e| return fail(e, "open");
    defer db.deinit();
    var notes = db.collection("notes") catch |e| return fail(e, "collection");
    defer notes.deinit();

    const corpus = [_]struct { key: []const u8, body: []const u8 }{
        .{ .key = "n1", .body = "the quick brown fox jumps over the lazy dog" },
        .{ .key = "n2", .body = "a quick red fox leaps over a sleeping dog" },
        .{ .key = "n3", .body = "slow green turtle crosses the road" },
        .{ .key = "n4", .body = "东京是一座巨大的城市" }, // Tokyo is a huge city
        .{ .key = "n5", .body = "大阪是关西最大的城市" }, // Osaka is Kansai's biggest city
        .{ .key = "n6", .body = "机器学习正在改变数据库" }, // ML is changing databases
    };
    for (corpus) |n| putNote(notes, n.key, n.body) catch |e| return fail(e, "insert");

    notes.createTextIndex("body") catch |e| return fail(e, "create_text_index");

    var rc: u8 = 0;
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    w.interface.print("== BM25 (query builder; RRF-rank scores) ==\n", .{}) catch {};
    w.interface.flush() catch {};
    rc = searchBm25(init, notes, "quick fox", "bm25 \"quick fox\":");
    if (rc != 0) return rc;
    rc = searchBm25(init, notes, "quick dog", "bm25 \"quick dog\":");
    if (rc != 0) return rc;
    rc = searchBm25(init, notes, "城市", "bm25 CJK 城市 (city):");
    if (rc != 0) return rc;
    rc = searchBm25(init, notes, "数据库", "bm25 CJK 数据库 (database):");
    if (rc != 0) return rc;

    w.interface.print("\n== phrase (direct positional; BM25 phrase-sum scores) ==\n", .{}) catch {};
    w.interface.flush() catch {};
    // Word order matters: reversed matches nothing.
    rc = searchPhrase(init, notes, "quick brown fox", 3, "phrase \"quick brown fox\":");
    if (rc != 0) return rc;
    rc = searchPhrase(init, notes, "fox quick brown", 3, "phrase \"fox quick brown\":");
    if (rc != 0) return rc;
    // Stop words collapse out of adjacency: the ≡ nothing.
    rc = searchPhrase(init, notes, "over the lazy", 3, "phrase \"over the lazy\":");
    if (rc != 0) return rc;
    rc = searchPhrase(init, notes, "over lazy", 3, "phrase \"over lazy\":");
    if (rc != 0) return rc;
    // CJK bigrams carry the phrase match through.
    rc = searchPhrase(init, notes, "巨大的城市", 3, "phrase CJK 巨大的城市:");
    if (rc != 0) return rc;
    // k == 0: an EMPTY cursor — inert, not an error.
    rc = searchPhrase(init, notes, "quick", 0, "phrase k=0:");
    if (rc != 0) return rc;
    return 0;
}
// docs:end:text_search
