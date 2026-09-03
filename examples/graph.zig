//! graph.zig — directed edges over a small corpus, and delete cascade.
//!
//! Three documents (ga, gb, gc) linked by a `parent_of` relation, plus
//! one edge pointing at `gd` which never exists as a document (dangling
//! edges are allowed), and a weighted `route` relation. Demonstrates
//! neighbors (key order), in_neighbors, weighted neighbors, BFS traverse
//! at 1 and 2 hops (cycle-safe), and the delete cascade: deleting a key
//! removes its edges in the same transaction — deleting the never-a-
//! document `gd` still drops the `gb -> gd` edge (spec §4.8/§4.11).
//!
//! Build/run: `zig build run-graph`; CI runs it on every platform.

const std = @import("std");
const corvid = @import("corvid");

fn fail(e: anyerror, what: []const u8) u8 {
    std.debug.print("graph: {s} failed: {s} ({s})\n", .{ what, corvid.lastErrorMessage(), @errorName(e) });
    return 1;
}

// docs:begin:graph
fn putNode(nodes: corvid.Collection, key: []const u8) !void {
    var doc = corvid.Value.map();
    defer doc.deinit();
    var n = try corvid.Value.text(key);
    try doc.put("n", &n);
    try nodes.insert(key, doc);
}

// Print one `[a b c ]` line from a key-set cursor (borrowed views).
fn printStrs(init: std.process.Init, label: []const u8, s: *corvid.Strs) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    w.interface.print("{s:<36} [", .{label}) catch {};
    while (s.next()) |item| {
        w.interface.print("{s} ", .{item}) catch {};
    }
    w.interface.print("]\n", .{}) catch {};
    w.interface.flush() catch {};
}

pub fn main(init: std.process.Init) u8 {
    var db = corvid.Db.openMemory() catch |e| return fail(e, "open");
    defer db.deinit();
    var nodes = db.collection("nodes") catch |e| return fail(e, "collection");
    defer nodes.deinit();

    for ([_][]const u8{ "ga", "gb", "gc" }) |key| {
        putNode(nodes, key) catch |e| return fail(e, "insert");
    }

    nodes.link("ga", "parent_of", "gb") catch |e| return fail(e, "link ga->gb");
    nodes.link("ga", "parent_of", "gc") catch |e| return fail(e, "link ga->gc");
    // gb -> gd: gd never exists as a document; the edge dangles fine.
    nodes.link("gb", "parent_of", "gd") catch |e| return fail(e, "link gb->gd");
    nodes.linkWeighted("ga", "route", "gb", 2.5) catch |e| return fail(e, "link_weighted ga->gb");
    nodes.linkWeighted("ga", "route", "gd", 0.75) catch |e| return fail(e, "link_weighted ga->gd");

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);

    var neighbors = nodes.neighbors("ga", "parent_of") catch |e| return fail(e, "neighbors");
    defer neighbors.deinit();
    printStrs(init, "neighbors(ga):", &neighbors);

    var in = nodes.inNeighbors("gb", "parent_of") catch |e| return fail(e, "in_neighbors");
    defer in.deinit();
    printStrs(init, "in_neighbors(gb):", &in);

    var routes = nodes.neighborsWeighted("ga", "route") catch |e| return fail(e, "neighbors_weighted");
    defer routes.deinit();
    w.interface.print("{s:<36} [", .{"routes from ga (weighted):"}) catch {};
    while (routes.next()) |hit| {
        w.interface.print("{s}={d:.2} ", .{ hit.key, hit.distance_km }) catch {};
    }
    w.interface.print("]\n", .{}) catch {};

    var t1 = nodes.traverse("ga", "parent_of", 1) catch |e| return fail(e, "traverse 1");
    defer t1.deinit();
    printStrs(init, "traverse(ga, 1 hop):", &t1);
    var t2 = nodes.traverse("ga", "parent_of", 2) catch |e| return fail(e, "traverse 2");
    defer t2.deinit();
    printStrs(init, "traverse(ga, 2 hops):", &t2);
    w.interface.flush() catch {};

    // Delete cascade: remove gc (a document) and gd (never a document).
    const gc_gone = nodes.delete("gc") catch |e| return fail(e, "delete gc");
    w.interface.print("delete gc: existed={}\n", .{gc_gone}) catch {};
    const gd_gone = nodes.delete("gd") catch |e| return fail(e, "delete gd");
    w.interface.print("delete gd: existed={} (never a document; its edges still cascade)\n", .{gd_gone}) catch {};
    w.interface.flush() catch {};

    var na = nodes.neighbors("ga", "parent_of") catch |e| return fail(e, "neighbors after");
    defer na.deinit();
    printStrs(init, "neighbors(ga) after deletes:", &na);
    var nb = nodes.neighbors("gb", "parent_of") catch |e| return fail(e, "neighbors(gb) after");
    defer nb.deinit();
    printStrs(init, "neighbors(gb) after deletes:", &nb);
    var t3 = nodes.traverse("ga", "parent_of", 2) catch |e| return fail(e, "traverse after");
    defer t3.deinit();
    printStrs(init, "traverse(ga, 2 hops) after:", &t3);
    return 0;
}
// docs:end:graph
