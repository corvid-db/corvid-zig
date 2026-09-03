//! geo.zig — points, radius, bbox, nearest-k with real coordinates.
//!
//! Four German cities stored with their real lat/lon (the `[lat, lon]`
//! array encoding; a `{lat=…, lon=…}` map encodes the same point).
//! Distances are haversine kilometres, measured from the query point
//! (52.52, 13.40) — central Berlin, a few hundred metres off the stored
//! landmark:
//!
//!   radius 600 km: berlin 0.338302, potsdam 26.615829,
//!     hamburg 254.929307, munchen 504.247542 — nearest first,
//!     inclusive boundary.
//!   bbox (47..55, 5..15): all four, key order, the 0.0 sentinel
//!     (a box has no center to measure from).
//!   nearest 2: berlin, potsdam — exact haversine order.
//!
//! These are the same points (to the landmark precision here) and
//! tolerances the engine's golden geo fixture asserts (~1e-6 km).
//!
//! Build/run: `zig build run-geo`; CI runs it on every platform.

const std = @import("std");
const corvid = @import("corvid");

fn fail(e: anyerror, what: []const u8) u8 {
    std.debug.print("geo: {s} failed: {s} ({s})\n", .{ what, corvid.lastErrorMessage(), @errorName(e) });
    return 1;
}

// docs:begin:geo
fn putCity(places: corvid.Collection, key: []const u8, name: []const u8, lat: f64, lon: f64) !void {
    var doc = corvid.Value.map();
    defer doc.deinit();
    var n = try corvid.Value.text(name);
    try doc.put("name", &n);
    var loc = corvid.Value.array();
    // put()/push() move each value into its parent as they go
    var la = corvid.Value.float(lat);
    try loc.push(&la);
    var lo = corvid.Value.float(lon);
    try loc.push(&lo);
    try doc.put("loc", &loc);
    try places.insert(key, doc);
}

fn printHits(init: std.process.Init, label: []const u8, hits: *corvid.GeoHits) void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    w.interface.print("{s:<32} [", .{label}) catch {};
    while (hits.next()) |hit| {
        // geo cursors carry their document; neighborsWeighted leaves it null
        if (hit.doc) |d| {
            const name = d.mapGet("name").?.textRef() orelse "?";
            w.interface.print("{s}={d:.6}km({s}) ", .{ hit.key, hit.distance_km, name }) catch {};
        } else {
            w.interface.print("{s}={d:.6} ", .{ hit.key, hit.distance_km }) catch {};
        }
    }
    w.interface.print("]\n", .{}) catch {};
    w.interface.flush() catch {};
}

pub fn main(init: std.process.Init) u8 {
    var db = corvid.Db.openMemory() catch |e| return fail(e, "open");
    defer db.deinit();
    var places = db.collection("places") catch |e| return fail(e, "collection");
    defer places.deinit();

    //               key        lat     lon     (name for the printout)
    const cities = [_]struct { key: []const u8, name: []const u8, lat: f64, lon: f64 }{
        .{ .key = "berlin", .name = "Berlin", .lat = 52.520, .lon = 13.405 },
        .{ .key = "potsdam", .name = "Potsdam", .lat = 52.396, .lon = 13.064 },
        .{ .key = "hamburg", .name = "Hamburg", .lat = 53.551, .lon = 9.994 },
        .{ .key = "munchen", .name = "München", .lat = 48.137, .lon = 11.575 },
    };
    for (cities) |city| {
        putCity(places, city.key, city.name, city.lat, city.lon) catch |e| return fail(e, "insert");
    }

    var r = places.geoWithinRadius("loc", 52.52, 13.40, 600.0) catch |e| return fail(e, "geo_within_radius");
    defer r.deinit();
    printHits(init, "radius 600km from Berlin:", &r);

    var b = places.geoWithinBbox("loc", 47.0, 5.0, 55.0, 15.0) catch |e| return fail(e, "geo_within_bbox");
    defer b.deinit();
    printHits(init, "bbox (47..55, 5..15):", &b);

    var n2 = places.geoNearest("loc", 52.52, 13.40, 2) catch |e| return fail(e, "geo_nearest");
    defer n2.deinit();
    printHits(init, "nearest 2 to Berlin:", &n2);
    return 0;
}
// docs:end:geo
