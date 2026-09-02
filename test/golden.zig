// golden.zig — the STANDALONE golden-suite harness, corvid-zig's port of
// the engine's reference implementation (corvid-db/corvid,
// crates/corvid-ffi/c/smoke.c, MIT), as ported standalone by
// corvid-c/test/golden.c.
//
// Same job as upstream, different moment of truth: the engine's harness
// links the cdylib cargo JUST BUILT and reads the golden/ fixtures
// committed in the engine repo; this one links the cdylib DOWNLOADED from
// the pinned GitHub release (fetch.sh / fetch.ps1 put it, corvid.h, and
// the release's golden/ under deps/) and zig builds it offline against
// deps/. If the published .so/.dylib/.dll, header, or fixtures disagree,
// THIS fails where the engine's own suite stayed green — that divergence
// is a finding for the engine repo, never patched around here.
//
// The body below is kept deliberately equivalent to upstream's harness so
// the two suites stay diffable and their pass/fail verdicts comparable:
// the same fixture grammar, the same dispatch table, the same checks, one
// OP<TAB>args<TAB>expected line at a time, every line dispatched, every
// expectation checked. The harness drives the RAW C ABI (its own
// @cImport of corvid.h) exactly as upstream's does — the idiomatic
// wrapper (src/corvid.zig) is a consumer of the same artifacts, proven
// separately by its unit tests and the examples tour.
//
// Conventions carried over from upstream:
//   - every handle/buffer this harness creates is freed on the path that
//     created it: an ASan-style build must report ZERO leaks, exercising
//     every handle family's free function plus corvid_free's buffer
//     domain. (The failure path exits the process without unwinding —
//     same as upstream's exit(1) — and is not a leak verdict.)
//
// Fixture grammar (per line): OP \t ARGS \t EXPECTED
//   - '#' lines and blank lines are ignored (not counted as executable).
//   - ARGS / EXPECTED are top-level comma-separated tokens; nesting
//     inside []{}() protects its commas.
//   - Value literals: null true false | -123 | 3.5 | inf -inf |
//     bits:0x7ff8000000000001 (f64 from bits) | bits32:0x7fc00000 (f32)
//     | t(text) | b(bytes) | vec(1.5,bits32:0x...,2) | [a,b] |
//     {k=v,k2=v2}; keys/paths/relations are bare words.
//   - Computed doubles (distances, scores, sums) expect `~x` (1e-6
//     relative tolerance, libm-safe across platforms); stored literals
//     compare bit-exactly (parseFloat is correctly rounded and the engine
//     preserves f64 bits — NaN payloads included).
//
// Output protocol (kept identical to upstream):
//   stdout: "SMOKE <file> lines=<n> executed=<n>" per fixture file.
//   stderr + exit 1 on the first failure, naming file:line, the OP, and
//   expected vs got.
//
// Usage: golden <workdir> <fixture.txt> [fixture.txt ...]

const std = @import("std");

const c = @cImport({
    @cInclude("corvid.h");
});

// The process-wide Io context (0.16's main receives one via
// std.process.Init; file APIs take it explicitly).
var g_io: ?std.Io = null;

fn io() std.Io {
    return g_io.?;
}

fn stdoutf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io(), &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

// ------------------------------------------------------------------
// Failure and check plumbing
// ------------------------------------------------------------------

var g_file: []const u8 = "?";
var g_line: usize = 0;
var g_op: []const u8 = "?";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("FAIL {s}:{d} OP={s}: " ++ fmt ++ "\n", .{ g_file, g_line, g_op } ++ args);
    std.process.exit(1);
}

fn check(cond: bool, comptime fmt: []const u8, args: anytype) void {
    if (!cond) fail(fmt, args);
}

// Expect a CORVID_ERR status with exactly this code (and a recorded
// message — every error expectation drives the error-reporting pair,
// corvid_last_error_code and corvid_last_error_message).
fn expectErr(st: c.corvid_status, code: c.corvid_err) void {
    if (st != c.CORVID_ERR) fail("expected CORVID_ERR, got CORVID_OK", .{});
    if (c.corvid_last_error_code() != code)
        fail("expected error code {d}, got {d}", .{ code, c.corvid_last_error_code() });
    var msg_len: usize = 0;
    const msg = c.corvid_last_error_message(&msg_len);
    if (msg == null or msg_len == 0)
        fail("error code {d} recorded but the message is missing", .{code});
}

fn expectOk(st: c.corvid_status) void {
    if (st != c.CORVID_OK)
        fail("expected CORVID_OK, got CORVID_ERR code {d}", .{c.corvid_last_error_code()});
}

// Infallible constructors still cross an ABI: a NULL return here is an
// artifact divergence, named with the recorded message.
fn mustVal(h: ?*c.corvid_value) *c.corvid_value {
    return h orelse fail("value constructor returned NULL", .{});
}

// ------------------------------------------------------------------
// Spans and tokenizing
// ------------------------------------------------------------------

const Span = []const u8;

fn spanIs(a: Span, s: []const u8) bool {
    return std.mem.eql(u8, a, s);
}

// Split `in` on top-level commas (depth-aware over []{}()), into `out`
// (cap entries). Empty input yields 0 tokens.
fn splitTop(in: Span, out: []Span) usize {
    var count: usize = 0;
    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= in.len) : (i += 1) {
        const ch: u8 = if (i < in.len) in[i] else ',';
        if (ch == '[' or ch == '{' or ch == '(') {
            depth += 1;
        } else if (ch == ']' or ch == '}' or ch == ')') {
            depth -= 1;
        }
        if (ch == ',' and depth == 0) {
            var end = i;
            while (end > start and (in[end - 1] == ' ' or in[end - 1] == '\r')) end -= 1;
            if (end > start) {
                if (count >= out.len) fail("too many tokens (max {d})", .{out.len});
                out[count] = in[start..end];
                count += 1;
            }
            start = i + 1;
        }
    }
    return count;
}

fn parseDouble(s: Span) f64 {
    if (s.len > 5 and std.mem.startsWith(u8, s, "bits:")) {
        // strtoull(base 16) semantics: an optional 0x prefix is accepted.
        var hex = s[5..];
        if (hex.len > 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) hex = hex[2..];
        const bits = std.fmt.parseInt(u64, hex, 16) catch fail("bad bits: literal '{s}'", .{s});
        return @bitCast(bits);
    }
    if (spanIs(s, "inf")) return std.math.inf(f64);
    if (spanIs(s, "-inf")) return -std.math.inf(f64);
    if (spanIs(s, "nan")) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, s) catch fail("bad float literal '{s}'", .{s});
}

fn doubleBits(d: f64) u64 {
    return @bitCast(d);
}

fn doubleExact(got: f64, want: f64) bool {
    return doubleBits(got) == doubleBits(want);
}

fn doubleNear(got: f64, want: f64) bool {
    const diff = @abs(got - want);
    return diff <= 1e-6 * (1.0 + @abs(want));
}

// Match one expected-double token: `~x` near; `=x`/`x`/bits:/inf
// bit-exact.
fn doubleMatches(got: f64, tok: Span) bool {
    if (tok.len > 0 and tok[0] == '~') return doubleNear(got, parseDouble(tok[1..]));
    if (tok.len > 0 and tok[0] == '=') return doubleExact(got, parseDouble(tok[1..]));
    return doubleExact(got, parseDouble(tok));
}

fn parseI64(s: Span) i64 {
    return std.fmt.parseInt(i64, s, 10) catch fail("bad int literal '{s}'", .{s});
}

// The err:N expected token → its code.
fn errToken(expected: Span) c.corvid_err {
    check(expected.len > 4 and std.mem.startsWith(u8, expected, "err:"),
        "error expectation must be err:N, got '{s}'", .{expected});
    return @intCast(std.fmt.parseInt(u32, expected[4..], 10) catch
        fail("bad err:N token '{s}'", .{expected}));
}

// A bounded append-only buffer (std's fixed-buffer writers moved in the
// 0.16 Io overhaul; this three-liner is all the harness needs).
const Buf = struct {
    data: []u8,
    len: usize = 0,

    fn append(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.data[self.len..], fmt, args) catch {
            self.len = self.data.len;
            return;
        };
        self.len += s.len;
    }

    fn slice(self: *const Buf) []const u8 {
        return self.data[0..self.len];
    }
};

// ------------------------------------------------------------------
// Value literals: parse + build
// ------------------------------------------------------------------

fn skipWs(p: *Span) void {
    while (p.len > 0 and (p.*[0] == ' ' or p.*[0] == '\r')) p.* = p.*[1..];
}

// Find the offset of the ')' matching the '(' at pp[0].
fn matchParenOffset(pp: Span) usize {
    var depth: i32 = 0;
    for (pp, 0..) |ch, q| {
        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return q;
        }
    }
    fail("unbalanced () in literal '{s}'", .{pp[0..@min(pp.len, 24)]});
}

// Does the text at p start with `word` as a delimited token?
fn startsWord(p: Span, word: []const u8) bool {
    if (p.len < word.len or !std.mem.startsWith(u8, p, word)) return false;
    const after: u8 = if (p.len == word.len) 0 else p[word.len];
    return after == 0 or after == ',' or after == ']' or after == '}' or
        after == ' ' or after == '\r';
}

fn buildNumber(pp: *Span) *c.corvid_value {
    const start = pp.*;
    var is_float = false;
    var is_bits = false;
    if (startsWord(start, "inf") or startsWord(start, "-inf") or startsWord(start, "nan")) {
        const wl: usize = if (startsWord(start, "-inf")) 4 else 3;
        const tok = start[0..wl];
        pp.* = start[wl..];
        return mustVal(c.corvid_value_float(parseDouble(tok)));
    }
    if (start.len > 5 and std.mem.startsWith(u8, start, "bits:")) {
        is_float = true;
        is_bits = true;
        pp.* = start[5..]; // scan the hex payload only
    }
    while (pp.len > 0) {
        const ch = pp.*[0];
        if ((ch >= '0' and ch <= '9') or ch == '-' or ch == '+') {
            pp.* = pp.*[1..];
        } else if (ch == '.' or ch == 'e' or ch == 'E') {
            is_float = true;
            pp.* = pp.*[1..];
        } else if (is_bits and ((ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F') or ch == 'x' or ch == 'X')) {
            pp.* = pp.*[1..];
        } else break;
    }
    // tok re-includes the bits: prefix parseDouble expects (as upstream).
    const tok = start[0 .. start.len - pp.len];
    if (tok.len == 0) fail("empty numeric literal", .{});
    if (is_bits) return mustVal(c.corvid_value_float(parseDouble(tok)));
    if (is_float) {
        return mustVal(c.corvid_value_float(std.fmt.parseFloat(f64, tok) catch
            fail("bad float literal '{s}'", .{tok})));
    }
    return mustVal(c.corvid_value_int(parseI64(tok)));
}

fn parseVecBody(body: Span) *c.corvid_value {
    var toks: [32]Span = undefined;
    const n = splitTop(body, &toks);
    var vals: [32]f32 = undefined;
    for (toks[0..n], 0..) |t, i| {
        if (t.len > 7 and std.mem.startsWith(u8, t, "bits32:")) {
            var hex = t[7..];
            if (hex.len > 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) hex = hex[2..];
            const bits: u32 = std.fmt.parseInt(u32, hex, 16) catch
                fail("bad bits32 token '{s}'", .{t});
            vals[i] = @bitCast(bits);
        } else {
            vals[i] = @floatCast(parseDouble(t));
        }
    }
    return mustVal(c.corvid_value_vector(&vals, n));
}

fn buildLit(pp: *Span) *c.corvid_value {
    skipWs(pp);
    if (pp.len == 0) fail("empty literal", .{});
    const start = pp.*;
    const ch = start[0];

    if (ch == '-' or (ch >= '0' and ch <= '9')) return buildNumber(pp);

    // bits:0x... (f64 from bits) starts with 'b' but is a NUMBER, not
    // the b(...) bytes literal; inf/-inf/nan likewise.
    if ((start.len > 5 and std.mem.startsWith(u8, start, "bits:")) or
        startsWord(start, "inf") or startsWord(start, "-inf") or
        startsWord(start, "nan"))
        return buildNumber(pp);

    if (startsWord(start, "null")) {
        pp.* = start[4..];
        return mustVal(c.corvid_value_null());
    }
    if (startsWord(start, "true")) {
        pp.* = start[4..];
        return mustVal(c.corvid_value_bool(1));
    }
    if (startsWord(start, "false")) {
        pp.* = start[5..];
        return mustVal(c.corvid_value_bool(0));
    }

    // t(...) / b(...) — balanced-paren payload, one-char heads.
    if ((ch == 't' or ch == 'b') and start.len > 1 and start[1] == '(') {
        const close = matchParenOffset(start[1..]) + 1;
        const body = start[2..close];
        pp.* = start[close + 1 ..];
        if (ch == 't') return mustVal(c.corvid_value_text(body.ptr, body.len));
        return mustVal(c.corvid_value_bytes(body.ptr, body.len));
    }

    // vec(...) — three-char head.
    if (ch == 'v' and start.len > 4 and std.mem.startsWith(u8, start, "vec(")) {
        const close = matchParenOffset(start[3..]) + 3;
        const body = start[4..close];
        pp.* = start[close + 1 ..];
        return parseVecBody(body);
    }

    if (ch == '[') {
        var depth: i32 = 0;
        var close: ?usize = null;
        for (start, 0..) |sc, q| {
            if (sc == '[') {
                depth += 1;
            } else if (sc == ']') {
                depth -= 1;
                if (depth == 0) {
                    close = q;
                    break;
                }
            }
        }
        const cl = close orelse fail("unbalanced [] in literal", .{});
        const arr = mustVal(c.corvid_value_array_new());
        var cur: Span = start[1..cl];
        while (cur.len > 0) {
            const item = buildLit(&cur);
            expectOk(c.corvid_value_array_push(arr, item)); // consumes item
            skipWs(&cur);
            if (cur.len > 0 and cur[0] == ',') cur = cur[1..];
        }
        pp.* = start[cl + 1 ..];
        return arr;
    }

    if (ch == '{') {
        var depth: i32 = 0;
        var close: ?usize = null;
        for (start, 0..) |sc, q| {
            if (sc == '{') {
                depth += 1;
            } else if (sc == '}') {
                depth -= 1;
                if (depth == 0) {
                    close = q;
                    break;
                }
            }
        }
        const cl = close orelse fail("unbalanced {{}} in literal", .{});
        const map = mustVal(c.corvid_value_map_new());
        var cur: Span = start[1..cl];
        skipWs(&cur);
        while (cur.len > 0) {
            const ks = cur;
            while (cur.len > 0 and cur[0] != '=' and cur[0] != ',' and cur[0] != '}')
                cur = cur[1..];
            if (cur.len == 0 or cur[0] != '=')
                fail("map literal needs k=v pairs", .{});
            var key = ks[0 .. ks.len - cur.len];
            while (key.len > 0 and key[0] == ' ') key = key[1..];
            cur = cur[1..]; // past '='
            const val = buildLit(&cur);
            expectOk(c.corvid_value_map_put(map, key.ptr, key.len, val)); // consumes
            skipWs(&cur);
            if (cur.len > 0 and cur[0] == ',') cur = cur[1..];
            skipWs(&cur);
        }
        pp.* = start[cl + 1 ..];
        return map;
    }

    fail("unparseable literal at '{s}'", .{start[0..@min(start.len, 24)]});
}

fn lit(s: Span) *c.corvid_value {
    if (s.len == 0) fail("empty literal token", .{});
    var p: Span = s;
    return buildLit(&p);
}

// ------------------------------------------------------------------
// Structural comparison through the READ API
// ------------------------------------------------------------------

fn valuesEqual(got: ?*const c.corvid_value, want: ?*const c.corvid_value) bool {
    if (got == null or want == null) return (got == null) == (want == null);
    const gt = c.corvid_value_type(got);
    const wt = c.corvid_value_type(want);
    if (gt != wt) return false;
    switch (gt) {
        c.CORVID_TYPE_NULL => return true,
        c.CORVID_TYPE_BOOL => {
            var go: c_int = 0;
            var wo: c_int = 0;
            const gb = c.corvid_value_as_bool(got, &go);
            const wb = c.corvid_value_as_bool(want, &wo);
            return go != 0 and wo != 0 and gb == wb;
        },
        c.CORVID_TYPE_INT => {
            var go: c_int = 0;
            var wo: c_int = 0;
            const gi = c.corvid_value_as_int(got, &go);
            const wi = c.corvid_value_as_int(want, &wo);
            return go != 0 and wo != 0 and gi == wi;
        },
        c.CORVID_TYPE_FLOAT => {
            var go: c_int = 0;
            var wo: c_int = 0;
            const gd = c.corvid_value_as_float(got, &go);
            const wd = c.corvid_value_as_float(want, &wo);
            return go != 0 and wo != 0 and doubleExact(gd, wd);
        },
        c.CORVID_TYPE_TEXT => {
            var gl: usize = 0;
            var wl: usize = 0;
            const gp = c.corvid_value_text_ref(got, &gl);
            const wp = c.corvid_value_text_ref(want, &wl);
            return gp != null and wp != null and gl == wl and
                std.mem.eql(u8, gp[0..gl], wp[0..wl]);
        },
        c.CORVID_TYPE_BYTES => {
            var gl: usize = 0;
            var wl: usize = 0;
            const gp = c.corvid_value_bytes_ref(got, &gl);
            const wp = c.corvid_value_bytes_ref(want, &wl);
            return gp != null and wp != null and gl == wl and
                std.mem.eql(u8, gp[0..gl], wp[0..wl]);
        },
        c.CORVID_TYPE_VECTOR => {
            var gl: usize = 0;
            var wl: usize = 0;
            const gp = c.corvid_value_vector_ref(got, &gl);
            const wp = c.corvid_value_vector_ref(want, &wl);
            if (gp == null or wp == null or gl != wl) return false;
            var i: usize = 0;
            while (i < gl) : (i += 1) {
                if (@as(u32, @bitCast(gp[i])) != @as(u32, @bitCast(wp[i]))) return false;
            }
            return true;
        },
        c.CORVID_TYPE_ARRAY => {
            const gl = c.corvid_value_len(got);
            const wl = c.corvid_value_len(want);
            if (gl != wl) return false;
            var i: usize = 0;
            while (i < gl) : (i += 1) {
                if (!valuesEqual(c.corvid_value_array_get(got, i), c.corvid_value_array_get(want, i)))
                    return false;
            }
            return true;
        },
        c.CORVID_TYPE_MAP => return false, // handled by check_value via the want token's keys
        else => return false,
    }
}

// Map comparison key-by-key: re-walk the expected literal's k=v pairs
// (maps in this ABI expose corvid_value_map_keys since v0.3.0; the
// fixture's expectation stays the key source for equality — the
// VMAP_KEYS/GET_KEYS OPs exercise the real key iterator on their own
// lines).
fn mapsEqual(g: ?*const c.corvid_value, w: ?*const c.corvid_value, want_tok: Span) bool {
    if (c.corvid_value_len(g) != c.corvid_value_len(w)) return false;
    var p: Span = want_tok;
    skipWs(&p);
    if (p.len == 0) return c.corvid_value_len(g) == 0; // {}
    p = p[1..]; // past {
    while (p.len > 0) {
        skipWs(&p);
        const ks = p;
        while (p.len > 0 and p[0] != '=' and p[0] != '}') p = p[1..];
        if (p.len == 0 or p[0] != '=') fail("malformed map expectation", .{});
        var key = ks[0 .. ks.len - p.len];
        while (key.len > 0 and key[0] == ' ') key = key[1..];
        p = p[1..]; // past =
        var depth: i32 = 0;
        const vs = p;
        while (p.len > 0) {
            if (p[0] == '[' or p[0] == '{' or p[0] == '(') {
                depth += 1;
            } else if (p[0] == ']' or p[0] == '}' or p[0] == ')') {
                if (depth == 0) break;
                depth -= 1;
            } else if (p[0] == ',' and depth == 0) break;
            p = p[1..];
        }
        const vtok = vs[0 .. vs.len - p.len];
        if (c.corvid_value_map_get(w, key.ptr, key.len) == null)
            fail("want-side map lacks key '{s}' — parser bug", .{key});
        const wv = lit(vtok);
        const eq = valuesEqual(c.corvid_value_map_get(g, key.ptr, key.len), wv) or
            (c.corvid_value_type(wv) == c.CORVID_TYPE_MAP and
                mapsEqual(c.corvid_value_map_get(g, key.ptr, key.len), wv, vtok));
        c.corvid_value_free(wv);
        if (!eq) return false;
        skipWs(&p);
        if (p.len == 0 or p[0] == '}') break;
        if (p[0] == ',') p = p[1..];
    }
    return true;
}

// Render a value into buf for failure messages (best effort).
fn renderValue(v: ?*const c.corvid_value, buf: []u8) []const u8 {
    var b = Buf{ .data = buf };
    if (v == null) return "NULL";
    switch (c.corvid_value_type(v)) {
        c.CORVID_TYPE_NULL => return "null",
        c.CORVID_TYPE_BOOL => {
            var ok: c_int = 0;
            b.append("bool({d})", .{c.corvid_value_as_bool(v, &ok)});
        },
        c.CORVID_TYPE_INT => {
            var ok: c_int = 0;
            b.append("int({d})", .{c.corvid_value_as_int(v, &ok)});
        },
        c.CORVID_TYPE_FLOAT => {
            var ok: c_int = 0;
            const d = c.corvid_value_as_float(v, &ok);
            b.append("float(0x{x}={d})", .{ doubleBits(d), d });
        },
        c.CORVID_TYPE_TEXT => {
            var l: usize = 0;
            const p = c.corvid_value_text_ref(v, &l);
            if (p == null) return "text(?)";
            b.append("text({s})", .{p[0..@min(l, 40)]});
        },
        c.CORVID_TYPE_BYTES => {
            var l: usize = 0;
            const p = c.corvid_value_bytes_ref(v, &l);
            if (p == null) return "bytes(?)";
            b.append("bytes({s})", .{p[0..@min(l, 40)]});
        },
        c.CORVID_TYPE_VECTOR => {
            var l: usize = 0;
            const p = c.corvid_value_vector_ref(v, &l);
            if (p == null) return "vec(?)";
            b.append("vec(dim={d}", .{l});
            var i: usize = 0;
            while (i < l and i < 6) : (i += 1) b.append(",{d}", .{p[i]});
            b.append(")", .{});
        },
        c.CORVID_TYPE_ARRAY => b.append("array(len={d})", .{c.corvid_value_len(v)}),
        c.CORVID_TYPE_MAP => b.append("map(len={d})", .{c.corvid_value_len(v)}),
        else => return "?",
    }
    return b.slice();
}

// Compare a got value (owned or borrowed) against an expected literal
// token; the want value is built, compared, freed.
fn checkValue(got: ?*const c.corvid_value, want_tok: Span) void {
    const want = lit(want_tok);
    var gbuf: [160]u8 = undefined;
    var wbuf: [160]u8 = undefined;
    const gr = renderValue(got, &gbuf);
    const wr = renderValue(want, &wbuf);
    const eq = valuesEqual(got, want) or
        (c.corvid_value_type(want) == c.CORVID_TYPE_MAP and
            got != null and mapsEqual(got, want, want_tok));
    c.corvid_value_free(want);
    check(eq, "value mismatch: got {s}, want {s}", .{ gr, wr });
}

// ------------------------------------------------------------------
// Scenario state
// ------------------------------------------------------------------

const Scenario = struct {
    db: ?*c.corvid_db = null,
    coll: ?*c.corvid_coll = null,
    workdir_buf: [512]u8 = undefined,
    workdir: Span = "",
    db_path_buf: [512]u8 = undefined,
    db_path: Span = "",
    db2_path_buf: [512]u8 = undefined,
    db2_path: Span = "",
    dump_path_buf: [512]u8 = undefined,
    dump_path: Span = "",
    backup_path_buf: [512]u8 = undefined,
    backup_path: Span = "",
    last_auto_id: i64 = 0, // INSERT_AUTO monotonicity
};

var scn: Scenario = .{};

fn closeColl() void {
    if (scn.coll) |coll| {
        c.corvid_collection_free(coll);
        scn.coll = null;
    }
}

fn closeDb() void {
    closeColl();
    if (scn.db) |db| {
        expectOk(c.corvid_close(db));
        scn.db = null;
    }
}

// (Re)acquire the primary "docs" collection handle.
fn docs() *c.corvid_coll {
    if (scn.coll == null) {
        check(scn.db != null, "no database open in this scenario", .{});
        scn.coll = c.corvid_collection(scn.db, "docs", 4);
        check(scn.coll != null, "corvid_collection(docs) failed", .{});
    }
    return scn.coll.?;
}

fn openMemory() void {
    closeDb();
    scn.db = c.corvid_open_memory();
    check(scn.db != null, "corvid_open_memory failed", .{});
    _ = docs();
}

fn openFile(path: []const u8) void {
    closeDb();
    scn.db = c.corvid_open(path.ptr, path.len);
    check(scn.db != null, "corvid_open({s}) failed", .{path});
    _ = docs();
}

// ------------------------------------------------------------------
// Callbacks (§1.6)
// ------------------------------------------------------------------

const ScanCtx = struct {
    count: usize = 0,
    stop_after: i64 = 0,
};

fn scanSink(ctx: ?*anyopaque, key: [*c]const u8, key_len: usize, doc: ?*const c.corvid_value) callconv(.c) c_int {
    _ = key;
    _ = key_len;
    _ = doc;
    const cc: *ScanCtx = @ptrCast(@alignCast(ctx.?));
    cc.count += 1;
    if (cc.stop_after > 0 and cc.count >= cc.stop_after) return 0;
    return 1;
}

fn updateBump(ctx: ?*anyopaque, current: ?*const c.corvid_value, out: [*c]?*c.corvid_value) callconv(.c) c.corvid_status {
    _ = ctx;
    out[0] = null;
    var n: i64 = 0;
    if (current) |cur| {
        const f = c.corvid_value_map_get(cur, "n", 1);
        check(f != null, "update_bump: current doc lacks field n", .{});
        var ok: c_int = 0;
        n = c.corvid_value_as_int(f, &ok);
        check(ok != 0, "update_bump: field n is not an int", .{});
    }
    const map = mustVal(c.corvid_value_map_new());
    expectOk(c.corvid_value_map_put(map, "n", 1, c.corvid_value_int(n + 1)));
    out[0] = map;
    return c.CORVID_OK;
}

fn updateAbort(ctx: ?*anyopaque, current: ?*const c.corvid_value, out: [*c]?*c.corvid_value) callconv(.c) c.corvid_status {
    _ = ctx;
    _ = current;
    out[0] = null;
    return c.CORVID_ERR; // the aborting-callback contract (§1.6)
}

// ------------------------------------------------------------------
// Cursor walkers
// ------------------------------------------------------------------

const MAX_ROWS = 64;

const RowWalk = struct {
    keys: [MAX_ROWS][128]u8 = undefined,
    key_lens: [MAX_ROWS]usize = undefined,
    scores: [MAX_ROWS]f32 = undefined,
    n: usize = 0,

    fn key(self: *const RowWalk, i: usize) Span {
        return self.keys[i][0..self.key_lens[i]];
    }
};

fn walkRows(rows: *c.corvid_rows, w: *RowWalk) void {
    w.n = 0;
    while (true) {
        var key_p: [*c]const u8 = null;
        var key_len: usize = 0;
        var doc: ?*const c.corvid_value = null;
        var score: f32 = 0.0;
        if (c.corvid_rows_next(rows, &key_p, &key_len, &doc, &score) != 1) break;
        check(w.n < MAX_ROWS, "more rows than the walker holds", .{});
        check(key_len < w.keys[0].len, "row key too long", .{});
        @memcpy(w.keys[w.n][0..key_len], key_p[0..key_len]);
        w.key_lens[w.n] = key_len;
        w.scores[w.n] = score;
        w.n += 1;
    }
}

// Match "k(a,b,c)" — key order exact.
fn checkKeys(w: *const RowWalk, expected: Span) void {
    check(expected.len >= 3 and expected[0] == 'k' and expected[1] == '(' and
        expected[expected.len - 1] == ')',
        "key expectation must be k(...), got '{s}'", .{expected});
    const body = expected[2 .. expected.len - 1];
    var want: [32]Span = undefined;
    const nw = if (body.len == 0) 0 else splitTop(body, &want);
    check(w.n == nw, "row count {d}, expected {d}", .{ w.n, nw });
    var i: usize = 0;
    while (i < nw) : (i += 1) {
        check(spanIs(w.key(i), want[i]), "row {d} key '{s}', expected '{s}'", .{ i, w.key(i), want[i] });
    }
}

// Match a "|~s1,~s2" suffix — one double token per row.
fn checkScores(w: *const RowWalk, suffix: Span) void {
    if (suffix.len == 0) return;
    check(suffix[0] == '|', "score suffix must start with |", .{});
    const body = suffix[1..];
    if (body.len == 0) return;
    var toks: [32]Span = undefined;
    const nw = splitTop(body, &toks);
    check(w.n == nw, "score count {d}, expected {d}", .{ w.n, nw });
    var i: usize = 0;
    while (i < nw) : (i += 1) {
        const got: f64 = w.scores[i];
        check(doubleMatches(got, toks[i]), "row {d} score {d} does not match '{s}'", .{ i, got, toks[i] });
    }
}

fn keyPart(expected: Span) Span {
    for (expected, 0..) |ch, i| {
        if (ch == '|') return expected[0..i];
    }
    return expected;
}

fn suffixPart(expected: Span) Span {
    for (expected, 0..) |ch, i| {
        if (ch == '|') return expected[i..];
    }
    return expected[0..0];
}

// ------------------------------------------------------------------
// Predicate helpers
// ------------------------------------------------------------------

fn parseCmp(t: Span) c.corvid_cmp {
    if (spanIs(t, "eq")) return c.CORVID_CMP_EQ;
    if (spanIs(t, "ne")) return c.CORVID_CMP_NE;
    if (spanIs(t, "lt")) return c.CORVID_CMP_LT;
    if (spanIs(t, "le")) return c.CORVID_CMP_LE;
    if (spanIs(t, "gt")) return c.CORVID_CMP_GT;
    if (spanIs(t, "ge")) return c.CORVID_CMP_GE;
    fail("bad cmp op '{s}'", .{t});
}

fn parseMetric(t: Span) c.corvid_metric {
    if (spanIs(t, "cosine")) return c.CORVID_METRIC_COSINE;
    if (spanIs(t, "dot")) return c.CORVID_METRIC_DOT;
    if (spanIs(t, "l2")) return c.CORVID_METRIC_L2;
    fail("bad metric '{s}'", .{t});
}

fn parseQuant(t: Span) c.corvid_quant {
    if (spanIs(t, "none")) return c.CORVID_QUANT_NONE;
    if (spanIs(t, "binary")) return c.CORVID_QUANT_BINARY;
    if (spanIs(t, "scalar")) return c.CORVID_QUANT_SCALAR;
    fail("bad quant '{s}'", .{t});
}

fn parseFieldType(t: Span) c.corvid_field_type {
    if (spanIs(t, "any")) return c.CORVID_FIELD_ANY;
    if (spanIs(t, "bool")) return c.CORVID_FIELD_BOOL;
    if (spanIs(t, "int")) return c.CORVID_FIELD_INT;
    if (spanIs(t, "float")) return c.CORVID_FIELD_FLOAT;
    if (spanIs(t, "text")) return c.CORVID_FIELD_TEXT;
    if (spanIs(t, "bytes")) return c.CORVID_FIELD_BYTES;
    if (spanIs(t, "vector")) return c.CORVID_FIELD_VECTOR;
    if (spanIs(t, "array")) return c.CORVID_FIELD_ARRAY;
    if (spanIs(t, "map")) return c.CORVID_FIELD_MAP;
    fail("bad field type '{s}'", .{t});
}

// Build a compare pred from (path, op, literal) tokens.
fn cmpPred(path: Span, op: Span, val_lit: Span) *c.corvid_pred {
    const v = lit(val_lit);
    const p = c.corvid_pred_compare(path.ptr, path.len, parseCmp(op), v);
    c.corvid_value_free(v); // CLONED into the tree (§5 rule 3)
    check(p != null, "corvid_pred_compare failed", .{});
    return p.?;
}

// The (filter) → count workhorse: builds, filters, counts, all consumed.
fn filteredCount(p: *c.corvid_pred) i64 {
    const q = c.corvid_query_new(docs());
    check(q != null, "corvid_query_new failed", .{});
    expectOk(c.corvid_query_filter(q, p)); // consumes p
    var n: usize = 0;
    expectOk(c.corvid_query_count(q, &n)); // consumes q
    return @intCast(n);
}

// ------------------------------------------------------------------
// Misc small helpers
// ------------------------------------------------------------------

fn expectNum(expected: Span, got: i64) void {
    check(parseI64(expected) == got, "expected {d}, want '{s}'", .{ got, expected });
}

// Walk a child path like a.b.0.c from a value; null when absent.
fn walkPath(root: ?*const c.corvid_value, path: Span) ?*const c.corvid_value {
    var cur = root;
    var p = path;
    while (p.len > 0 and cur != null) {
        if (p[0] == '.') p = p[1..];
        const ks = p;
        while (p.len > 0 and p[0] != '.') p = p[1..];
        const seg = ks[0 .. ks.len - p.len];
        if (seg.len == 0) break;
        var is_index = true;
        for (seg) |ch| {
            if (ch < '0' or ch > '9') is_index = false;
        }
        cur = if (is_index)
            c.corvid_value_array_get(cur, @intCast(parseI64(seg)))
        else
            c.corvid_value_map_get(cur, seg.ptr, seg.len);
    }
    return cur;
}

// The t(...) literal body.
fn textBody(tok: Span) Span {
    check(tok.len >= 3 and tok[0] == 't' and tok[1] == '(' and
        tok[tok.len - 1] == ')',
        "expected a t(...) literal, got '{s}'", .{tok});
    return tok[2 .. tok.len - 1];
}

// The k(...) list body.
fn listBody(tok: Span) Span {
    check(tok.len >= 3 and tok[0] == 'k' and tok[1] == '(' and
        tok[tok.len - 1] == ')',
        "expected a k(...) list, got '{s}'", .{tok});
    return tok[2 .. tok.len - 1];
}

// ------------------------------------------------------------------
// OP implementations
// ------------------------------------------------------------------

fn runLine(op: Span, args: Span, expected: Span) void {
    var a: [16]Span = [_]Span{""} ** 16;
    const na = if (args.len != 0) splitTop(args, &a) else 0;

    // ---- pure value ops (no db) ----
    if (spanIs(op, "VERSION")) {
        check(c.corvid_ffi_version() == 1, "FFI_VERSION must be 1", .{});
        return;
    }
    if (spanIs(op, "VTYPE")) {
        const names = [_][]const u8{ "null", "bool", "int", "float", "text", "bytes", "array", "map", "vector" };
        const v = lit(a[0]);
        const t: usize = @intCast(c.corvid_value_type(v));
        check(t <= 8, "type tag {d} out of range", .{t});
        check(spanIs(expected, names[t]), "type {s}, want '{s}'", .{ names[t], expected });
        c.corvid_value_free(v);
        return;
    }
    if (spanIs(op, "VLEN")) {
        const v = lit(a[0]);
        expectNum(expected, @intCast(c.corvid_value_len(v)));
        c.corvid_value_free(v);
        return;
    }
    if (spanIs(op, "VAS_INT") or spanIs(op, "VAS_FLOAT") or spanIs(op, "VAS_BOOL")) {
        const v = lit(a[0]);
        var ok: c_int = 0;
        var gotbuf: [160]u8 = undefined;
        var g = Buf{ .data = &gotbuf };
        if (op[4] == 'I') {
            const got = c.corvid_value_as_int(v, &ok);
            if (spanIs(expected, "fail")) {
                check(ok == 0, "as_int unexpectedly ok ({d})", .{got});
            } else {
                check(ok != 0, "as_int failed", .{});
                g.append("ok:{d}", .{got});
                check(spanIs(expected, g.slice()), "as_int {s}, want '{s}'", .{ g.slice(), expected });
            }
        } else if (op[4] == 'F') {
            const got = c.corvid_value_as_float(v, &ok);
            if (spanIs(expected, "fail")) {
                check(ok == 0, "as_float unexpectedly ok", .{});
            } else {
                check(ok != 0, "as_float failed", .{});
                check(expected.len > 3 and std.mem.startsWith(u8, expected, "ok:"),
                    "as_float expectation must be ok:<double>", .{});
                const w = expected[3..];
                check(doubleMatches(got, w), "as_float 0x{x} ({d}) does not match '{s}'", .{ doubleBits(got), got, w });
            }
        } else {
            const got = c.corvid_value_as_bool(v, &ok);
            if (spanIs(expected, "fail")) {
                check(ok == 0, "as_bool unexpectedly ok", .{});
            } else {
                check(ok != 0, "as_bool failed", .{});
                g.append("ok:{d}", .{got});
                check(spanIs(expected, g.slice()), "as_bool {s}, want '{s}'", .{ g.slice(), expected });
            }
        }
        c.corvid_value_free(v);
        return;
    }
    if (spanIs(op, "VTEXT_REF") or spanIs(op, "VBYTES_REF") or spanIs(op, "VVECTOR_REF")) {
        const v = lit(a[0]);
        if (op[1] == 'T') {
            var len: usize = 0;
            const p = c.corvid_value_text_ref(v, &len);
            const body = textBody(expected);
            check(p != null, "text_ref returned NULL for a text value", .{});
            check(len == body.len and std.mem.eql(u8, p[0..len], body), "text bytes differ", .{});
        } else if (op[1] == 'B') {
            var len: usize = 0;
            const p = c.corvid_value_bytes_ref(v, &len);
            check(expected.len >= 3 and expected[0] == 'b' and expected[1] == '(',
                "bytes expectation must be b(...)", .{});
            const body = expected[2 .. expected.len - 1];
            check(p != null, "bytes_ref returned NULL for a bytes value", .{});
            check(len == body.len and std.mem.eql(u8, p[0..len], body), "bytes differ", .{});
        } else {
            var dim: usize = 0;
            const p = c.corvid_value_vector_ref(v, &dim);
            const w = lit(a[0]);
            var wdim: usize = 0;
            const wp = c.corvid_value_vector_ref(w, &wdim);
            check(p != null, "vector_ref returned NULL for a vector value", .{});
            check(dim == wdim, "ref dim {d}, rebuilt dim {d}", .{ dim, wdim });
            var i: usize = 0;
            while (i < dim) : (i += 1) {
                check(@as(u32, @bitCast(p[i])) == @as(u32, @bitCast(wp[i])),
                    "vector elem {d} differs bit-exactly", .{i});
            }
            c.corvid_value_free(w);
        }
        c.corvid_value_free(v);
        return;
    }
    if (spanIs(op, "VNEST") or spanIs(op, "VCLONE")) {
        const root = lit(a[0]);
        const holder = if (spanIs(op, "VCLONE")) c.corvid_value_clone(root) else root;
        check(holder != null, "clone failed", .{});
        const child = walkPath(holder, a[1]);
        if (spanIs(expected, "absent")) {
            check(child == null, "path unexpectedly present", .{});
        } else {
            checkValue(child, expected);
        }
        if (holder != root) c.corvid_value_free(holder);
        c.corvid_value_free(root);
        return;
    }
    if (spanIs(op, "VPUSH")) {
        const arr = lit(a[0]);
        const item = lit(a[1]);
        expectOk(c.corvid_value_array_push(arr, item)); // consumes item
        expectNum(expected, @intCast(c.corvid_value_len(arr)));
        c.corvid_value_free(arr);
        return;
    }
    if (spanIs(op, "VPUT")) {
        const map = lit(a[0]);
        const val = lit(a[2]);
        expectOk(c.corvid_value_map_put(map, a[1].ptr, a[1].len, val)); // consumes
        expectNum(expected, @intCast(c.corvid_value_len(map)));
        c.corvid_value_free(map);
        return;
    }
    if (spanIs(op, "VMAP_KEYS") or spanIs(op, "GET_KEYS")) {
        // VMAP_KEYS enumerates a literal's keys (pure form, values.txt);
        // GET_KEYS fetches an inserted document by key first, proving the
        // decode-from-storage half bindings need. Both drive the §4.12
        // strs cursor over corvid_value_map_keys' ascending byte order
        // (the v0.3.0 §4.4 addition).
        var v: ?*c.corvid_value = null;
        if (op[0] == 'G') {
            expectOk(c.corvid_get(docs(), a[0].ptr, a[0].len, &v));
            check(v != null, "GET_KEYS on an absent document", .{});
        } else {
            v = lit(a[0]);
        }
        const cur = c.corvid_value_map_keys(v);
        check(cur != null, "corvid_value_map_keys failed", .{});
        var w = RowWalk{};
        while (true) {
            var item: [*c]const u8 = null;
            var ilen: usize = 0;
            if (c.corvid_strs_next(cur, &item, &ilen) != 1) break;
            check(w.n < MAX_ROWS, "map_keys overflow", .{});
            check(ilen < w.keys[0].len, "map key too long", .{});
            @memcpy(w.keys[w.n][0..ilen], item[0..ilen]);
            w.key_lens[w.n] = ilen;
            w.n += 1;
        }
        c.corvid_strs_free(cur);
        c.corvid_value_free(v);
        checkKeys(&w, expected);
        return;
    }
    if (spanIs(op, "NULLFREES")) {
        c.corvid_value_free(null);
        c.corvid_pred_free(null);
        c.corvid_query_free(null);
        c.corvid_rows_free(null);
        c.corvid_strs_free(null);
        c.corvid_geohits_free(null);
        c.corvid_groupiter_free(null);
        c.corvid_schemaiter_free(null);
        c.corvid_collection_free(null);
        c.corvid_free(null);
        return;
    }

    // ---- db-required ops from here on ----
    if (spanIs(op, "COLL")) {
        closeColl();
        scn.coll = c.corvid_collection(scn.db, a[0].ptr, a[0].len);
        check(scn.coll != null, "corvid_collection failed", .{});
        var len: usize = 0;
        const name = c.corvid_collection_name(scn.coll, &len);
        check(name != null and len == a[0].len and
            std.mem.eql(u8, name[0..len], a[0]),
            "collection_name round trip failed", .{});
        return;
    }
    if (spanIs(op, "INSERT") or spanIs(op, "INSERT_ERR")) {
        const v = lit(a[1]);
        const st = c.corvid_insert(docs(), a[0].ptr, a[0].len, v);
        c.corvid_value_free(v); // CLONED into the engine
        if (op.len > 6) { // INSERT_ERR
            expectErr(st, errToken(expected));
        } else {
            expectOk(st);
        }
        return;
    }
    if (spanIs(op, "LEN")) {
        var n: usize = 0;
        expectOk(c.corvid_len(docs(), &n));
        expectNum(expected, @intCast(n));
        return;
    }
    if (spanIs(op, "GET") or spanIs(op, "GETFIELD")) {
        var out: ?*c.corvid_value = null;
        expectOk(c.corvid_get(docs(), a[0].ptr, a[0].len, &out));
        if (op.len > 3) { // GETFIELD
            check(out != null, "GETFIELD on an absent document", .{});
            const child = walkPath(out, a[1]);
            if (spanIs(expected, "absent")) {
                check(child == null, "field unexpectedly present", .{});
            } else {
                checkValue(child, expected);
            }
        } else if (spanIs(expected, "absent")) {
            check(out == null, "expected absence, got a document", .{});
        } else {
            check(out != null, "expected a document, got absence", .{});
            checkValue(out, expected);
        }
        c.corvid_value_free(out);
        return;
    }
    if (spanIs(op, "PUTMANY") or spanIs(op, "PUTMANY_ROLLBACK")) {
        check(na % 2 == 0, "PUTMANY wants key/literal pairs", .{});
        const count = na / 2;
        check(count <= 8, "PUTMANY cap is 8 pairs", .{});
        var items: [8]c.corvid_kv = undefined;
        var vals: [8]*c.corvid_value = undefined;
        for (0..count) |i| {
            vals[i] = lit(a[2 * i + 1]);
            items[i] = .{ .key = a[2 * i].ptr, .key_len = a[2 * i].len, .val = vals[i] };
        }
        const st = c.corvid_put_many(docs(), &items, count);
        for (vals[0..count]) |v| c.corvid_value_free(v); // cloned
        if (op.len > 7) { // PUTMANY_ROLLBACK
            expectErr(st, errToken(expected));
        } else {
            expectOk(st);
        }
        return;
    }
    if (spanIs(op, "INSERT_AUTO")) {
        const v = lit(a[0]);
        var klen: usize = 0;
        const key = c.corvid_insert_auto(docs(), v, &klen);
        c.corvid_value_free(v);
        check(key != null, "insert_auto failed", .{});
        check(klen == 20, "auto key length {d}, want 20", .{klen});
        var id: i64 = 0;
        for (key[0..klen]) |ch| {
            check(ch >= '0' and ch <= '9', "auto key not zero-padded digits", .{});
            id = id * 10 + @as(i64, ch - '0');
        }
        check(scn.last_auto_id == 0 or id > scn.last_auto_id,
            "auto id {d} not monotonic (previous {d})", .{ id, scn.last_auto_id });
        scn.last_auto_id = id;
        c.corvid_free(key);
        return;
    }
    if (spanIs(op, "UPDATE")) {
        expectOk(c.corvid_update(docs(), a[0].ptr, a[0].len, updateBump, null));
        return;
    }
    if (spanIs(op, "UPDATE_ABORT")) {
        const st = c.corvid_update(docs(), a[0].ptr, a[0].len, updateAbort, null);
        expectErr(st, c.CORVID_E_ARGUMENT);
        return;
    }
    if (spanIs(op, "PATCH")) {
        const v = lit(a[1]);
        const st = c.corvid_patch(docs(), a[0].ptr, a[0].len, v);
        c.corvid_value_free(v);
        expectOk(st);
        return;
    }
    if (spanIs(op, "CAS")) {
        const ex: ?*c.corvid_value = if (spanIs(a[1], "absent")) null else lit(a[1]);
        const re: ?*c.corvid_value = if (spanIs(a[2], "absent")) null else lit(a[2]);
        var applied: i32 = -1;
        expectOk(c.corvid_compare_and_set(docs(), a[0].ptr, a[0].len, ex, re, &applied));
        if (ex) |x| c.corvid_value_free(x);
        if (re) |r| c.corvid_value_free(r);
        const want: []const u8 = if (applied != 0) "applied:1" else "applied:0";
        check(spanIs(expected, want), "CAS applied={d}, want '{s}'", .{ applied, expected });
        return;
    }
    if (spanIs(op, "DELETE")) {
        var existed: i32 = -1;
        expectOk(c.corvid_delete(docs(), a[0].ptr, a[0].len, &existed));
        const want: []const u8 = if (existed != 0) "existed:1" else "existed:0";
        check(spanIs(expected, want), "delete existed={d}, want '{s}'", .{ existed, expected });
        return;
    }
    if (spanIs(op, "DELETE_WHERE")) {
        var removed: usize = 0;
        expectOk(c.corvid_delete_where(docs(), cmpPred(a[0], a[1], a[2]), &removed)); // consumes the pred
        var buf: [32]u8 = undefined;
        const got = std.fmt.bufPrint(&buf, "removed:{d}", .{removed}) catch unreachable;
        check(spanIs(expected, got), "removed {s}, want '{s}'", .{ got, expected });
        return;
    }
    if (spanIs(op, "DELETE_IN")) {
        var vals: [8]*c.corvid_value = undefined;
        var ptrs: [8]*const c.corvid_value = undefined;
        const n = na - 1;
        check(n <= 8, "DELETE_IN cap is 8 values", .{});
        for (0..n) |i| {
            vals[i] = lit(a[i + 1]);
            ptrs[i] = vals[i];
        }
        const p = c.corvid_pred_in(a[0].ptr, a[0].len, &ptrs, n);
        for (vals[0..n]) |v| c.corvid_value_free(v); // cloned
        check(p != null, "pred_in failed", .{});
        var removed: usize = 0;
        expectOk(c.corvid_delete_where(docs(), p, &removed)); // consumes
        var buf: [32]u8 = undefined;
        const got = std.fmt.bufPrint(&buf, "removed:{d}", .{removed}) catch unreachable;
        check(spanIs(expected, got), "removed {s}, want '{s}'", .{ got, expected });
        return;
    }
    if (spanIs(op, "DELETE_BATCH")) {
        check(na <= 16, "DELETE_BATCH cap is 16 keys", .{});
        var keys: [16][*c]const u8 = undefined;
        var lens: [16]usize = undefined;
        for (0..na) |i| {
            keys[i] = a[i].ptr;
            lens[i] = a[i].len;
        }
        var removed: usize = 0;
        expectOk(c.corvid_delete_batch(docs(), &keys, &lens, na, &removed));
        var buf: [32]u8 = undefined;
        const got = std.fmt.bufPrint(&buf, "removed:{d}", .{removed}) catch unreachable;
        check(spanIs(expected, got), "removed {s}, want '{s}'", .{ got, expected });
        return;
    }
    if (spanIs(op, "INSERT_TTL")) {
        const v = lit(a[1]);
        const st = c.corvid_insert_with_ttl(docs(), a[0].ptr, a[0].len, v, parseI64(a[2]));
        c.corvid_value_free(v);
        expectOk(st);
        return;
    }
    if (spanIs(op, "GET_TTL")) {
        var exp: i64 = 0;
        var has: i32 = -1;
        expectOk(c.corvid_get_ttl(docs(), a[0].ptr, a[0].len, &exp, &has));
        var buf: [40]u8 = undefined;
        const got = if (has != 0)
            std.fmt.bufPrint(&buf, "ttl:{d}", .{exp}) catch unreachable
        else
            std.fmt.bufPrint(&buf, "nottl", .{}) catch unreachable;
        check(spanIs(expected, got), "ttl {s}, want '{s}'", .{ got, expected });
        return;
    }
    if (spanIs(op, "SET_TTL")) {
        expectOk(c.corvid_set_ttl(docs(), a[0].ptr, a[0].len, parseI64(a[1])));
        return;
    }
    if (spanIs(op, "PURGE")) {
        var purged: usize = 0;
        expectOk(c.corvid_purge_expired(docs(), parseI64(a[0]), &purged));
        var buf: [32]u8 = undefined;
        const got = std.fmt.bufPrint(&buf, "purged:{d}", .{purged}) catch unreachable;
        check(spanIs(expected, got), "purged {s}, want '{s}'", .{ got, expected });
        return;
    }
    if (spanIs(op, "SCAN") or spanIs(op, "SCAN_STOP")) {
        var ctx = ScanCtx{ .stop_after = if (op.len > 4) parseI64(a[0]) else 0 };
        expectOk(c.corvid_scan(docs(), scanSink, &ctx));
        expectNum(expected, @intCast(ctx.count));
        return;
    }
    if (spanIs(op, "PAGE")) {
        const from_start = spanIs(a[0], "-");
        const after: [*c]const u8 = if (from_start) null else a[0].ptr;
        const after_len: usize = if (from_start) 0 else a[0].len;
        var rows: ?*c.corvid_rows = null;
        var next: [*c]u8 = null;
        var next_len: usize = 0;
        expectOk(c.corvid_page(docs(), after, after_len, @intCast(parseI64(a[1])), &rows, &next, &next_len));
        var w = RowWalk{};
        walkRows(rows.?, &w);
        c.corvid_rows_free(rows);
        const at_end = (next == null);
        if (next != null) c.corvid_free(next);
        checkKeys(&w, keyPart(expected));
        const sp = suffixPart(expected);
        const want_end: []const u8 = if (at_end) "|end" else "|more";
        check(spanIs(sp, want_end), "page cursor {s}, want '{s}'", .{ if (at_end) "end" else "more", sp });
        return;
    }

    // ---- predicates + queries ----
    if (spanIs(op, "QF_COUNT")) {
        expectNum(expected, filteredCount(cmpPred(a[0], a[1], a[2])));
        return;
    }
    if (spanIs(op, "QF_EXISTS")) {
        const p = c.corvid_pred_exists(a[0].ptr, a[0].len);
        check(p != null, "pred_exists failed", .{});
        expectNum(expected, filteredCount(p.?));
        return;
    }
    if (spanIs(op, "QF_BETWEEN")) {
        const lo = lit(a[1]);
        const hi = lit(a[2]);
        const p = c.corvid_pred_between(a[0].ptr, a[0].len, lo, hi);
        c.corvid_value_free(lo);
        c.corvid_value_free(hi);
        check(p != null, "pred_between failed", .{});
        expectNum(expected, filteredCount(p.?));
        return;
    }
    if (spanIs(op, "QF_STARTS") or spanIs(op, "QF_CONTAINS")) {
        const body = textBody(a[1]);
        const p = if (op[3] == 'S')
            c.corvid_pred_starts_with(a[0].ptr, a[0].len, body.ptr, body.len)
        else
            c.corvid_pred_contains(a[0].ptr, a[0].len, body.ptr, body.len);
        check(p != null, "text pred failed", .{});
        expectNum(expected, filteredCount(p.?));
        return;
    }
    if (spanIs(op, "QF_GEO")) {
        const p = c.corvid_pred_geo_within(a[0].ptr, a[0].len, parseDouble(a[1]), parseDouble(a[2]), parseDouble(a[3]));
        check(p != null, "pred_geo_within failed", .{});
        expectNum(expected, filteredCount(p.?));
        return;
    }
    if (spanIs(op, "QF_AND") or spanIs(op, "QF_OR")) {
        const l = cmpPred(a[0], a[1], a[2]);
        const r = cmpPred(a[3], a[4], a[5]);
        const p = if (op[3] == 'A') c.corvid_pred_and(l, r) else c.corvid_pred_or(l, r);
        check(p != null, "combinator failed (children consumed)", .{});
        expectNum(expected, filteredCount(p.?));
        return;
    }
    if (spanIs(op, "QF_NOT")) {
        const inner = cmpPred(a[0], a[1], a[2]);
        const p = c.corvid_pred_not(inner); // consumes
        check(p != null, "pred_not failed", .{});
        expectNum(expected, filteredCount(p.?));
        return;
    }
    if (spanIs(op, "PRED_FREE")) {
        const p = cmpPred(a[0], a[1], a[2]);
        c.corvid_pred_free(p); // the never-consumed-root free path
        return;
    }
    if (spanIs(op, "Q_ABANDON")) {
        const q = c.corvid_query_new(docs());
        check(q != null, "query_new failed", .{});
        c.corvid_query_free(q); // the abandoned-builder free path
        return;
    }
    if (spanIs(op, "QVEC") or spanIs(op, "APPROX")) {
        const q = c.corvid_query_new(docs());
        check(q != null, "query_new failed", .{});
        const qv = lit(a[1]); // vec(...)
        var dim: usize = 0;
        const elems = c.corvid_value_vector_ref(qv, &dim);
        if (op[0] == 'A') expectOk(c.corvid_query_approx(q));
        expectOk(c.corvid_query_vector(q, a[0].ptr, a[0].len, elems, dim, @intCast(parseI64(a[2])), c.CORVID_METRIC_COSINE));
        c.corvid_value_free(qv);
        const rows = c.corvid_query_run(q); // consumes q
        check(rows != null, "query_run failed", .{});
        var w = RowWalk{};
        walkRows(rows.?, &w);
        c.corvid_rows_free(rows);
        checkKeys(&w, keyPart(expected));
        checkScores(&w, suffixPart(expected));
        return;
    }
    if (spanIs(op, "QTEXT")) {
        const q = c.corvid_query_new(docs());
        check(q != null, "query_new failed", .{});
        const body = textBody(a[1]);
        expectOk(c.corvid_query_text(q, a[0].ptr, a[0].len, body.ptr, body.len, @intCast(parseI64(a[2]))));
        const rows = c.corvid_query_run(q);
        check(rows != null, "query_run failed", .{});
        var w = RowWalk{};
        walkRows(rows.?, &w);
        c.corvid_rows_free(rows);
        checkKeys(&w, expected);
        return;
    }
    if (spanIs(op, "PHRASE") or spanIs(op, "PHRASE_K0")) {
        // The direct positional search (spec §4.6's erratum, the v0.3.0
        // addition): args are field, t(phrase), k — expected is k(keys)
        // plus an optional |~score suffix (the BM25 phrase sum, the rows
        // cursor's other score scale). PHRASE_K0 is the inert k==0
        // shape: an EMPTY cursor, never NULL (the nothing-recorded half
        // of k == 0's inertness is pinned by the query.rs unit test on a
        // fresh thread — the smoke thread's last-error slot may hold an
        // earlier line's intentional failure, by §3's contract that
        // successful calls never clear it).
        const body = textBody(a[1]);
        const rows = c.corvid_phrase_search(docs(), a[0].ptr, a[0].len, body.ptr, body.len, @intCast(parseI64(a[2])));
        check(rows != null, "corvid_phrase_search failed", .{});
        var w = RowWalk{};
        walkRows(rows.?, &w);
        c.corvid_rows_free(rows);
        checkKeys(&w, keyPart(expected));
        checkScores(&w, suffixPart(expected));
        if (op.len > 6) { // PHRASE_K0: the empty-cursor half
            check(w.n == 0, "k == 0 must answer an empty cursor", .{});
        }
        return;
    }
    if (spanIs(op, "HYBRID") or spanIs(op, "HYBRID_F")) {
        // args: vfield vec k tfield t(query) tk [tagvalue] limit — the
        // tagvalue (HYBRID_F) slides the limit to the LAST slot.
        // (HYBRID adds a kind=doc filter; HYBRID_F a tag=<arg6> filter)
        const tagged = op.len > 6;
        const vk = parseI64(a[2]);
        const tk = parseI64(a[5]);
        const lim = parseI64(if (tagged) a[7] else a[6]);
        const q = c.corvid_query_new(docs());
        check(q != null, "query_new failed", .{});
        if (tagged) {
            const tv = lit(a[6]);
            const tag = c.corvid_pred_compare("tag", 3, c.CORVID_CMP_EQ, tv);
            c.corvid_value_free(tv);
            check(tag != null, "tag filter build failed", .{});
            expectOk(c.corvid_query_filter(q, tag)); // consumes
        } else {
            const kind = c.corvid_value_text("doc", 3);
            const p = c.corvid_pred_compare("kind", 4, c.CORVID_CMP_EQ, kind);
            c.corvid_value_free(kind);
            check(p != null, "kind filter build failed", .{});
            expectOk(c.corvid_query_filter(q, p)); // consumes
        }
        const qv = lit(a[1]);
        var dim: usize = 0;
        const elems = c.corvid_value_vector_ref(qv, &dim);
        expectOk(c.corvid_query_vector(q, a[0].ptr, a[0].len, elems, dim, @intCast(vk), c.CORVID_METRIC_COSINE));
        c.corvid_value_free(qv);
        const body = textBody(a[4]);
        expectOk(c.corvid_query_text(q, a[3].ptr, a[3].len, body.ptr, body.len, @intCast(tk)));
        expectOk(c.corvid_query_fuse_rrf(q, 60.0));
        expectOk(c.corvid_query_rerank_mmr(q, 1.0));
        expectOk(c.corvid_query_limit(q, @intCast(lim)));
        const rows = c.corvid_query_run(q); // consumes q
        check(rows != null, "query_run failed", .{});
        var w = RowWalk{};
        walkRows(rows.?, &w);
        c.corvid_rows_free(rows);
        checkKeys(&w, keyPart(expected));
        checkScores(&w, suffixPart(expected));
        return;
    }
    if (spanIs(op, "ORDER_BY")) {
        const q = c.corvid_query_new(docs());
        check(q != null, "query_new failed", .{});
        expectOk(c.corvid_query_order_by(q, a[0].ptr, a[0].len, @intCast(parseI64(a[1]))));
        expectOk(c.corvid_query_offset(q, @intCast(parseI64(a[2]))));
        expectOk(c.corvid_query_limit(q, @intCast(parseI64(a[3]))));
        const rows = c.corvid_query_run(q);
        check(rows != null, "query_run failed", .{});
        var w = RowWalk{};
        walkRows(rows.?, &w);
        c.corvid_rows_free(rows);
        checkKeys(&w, expected);
        return;
    }
    if (spanIs(op, "SELECT")) {
        // args: (field,field,...) k(row-key); expected: that row's
        // projected document. The paren group keeps the field list one
        // token at the args level; strip it before splitting.
        var fields_arg = a[0];
        check(fields_arg.len >= 2 and fields_arg[0] == '(' and
            fields_arg[fields_arg.len - 1] == ')',
            "SELECT's first arg must be a (field,...) group", .{});
        fields_arg = fields_arg[1 .. fields_arg.len - 1];
        var toks: [8]Span = undefined;
        const nf = splitTop(fields_arg, &toks);
        var fields: [8][*c]const u8 = undefined;
        var flens: [8]usize = undefined;
        for (0..nf) |i| {
            fields[i] = toks[i].ptr;
            flens[i] = toks[i].len;
        }
        const want_key = listBody(a[1]);
        // Two identical runs: the first finds the row's position, the
        // second stops on it and checks the projected document.
        var found: i64 = -1;
        for (0..2) |pass| {
            const q = c.corvid_query_new(docs());
            check(q != null, "query_new failed", .{});
            expectOk(c.corvid_query_select(q, &fields, &flens, nf));
            const rows = c.corvid_query_run(q);
            check(rows != null, "query_run failed", .{});
            if (pass == 0) {
                var w = RowWalk{};
                walkRows(rows.?, &w);
                for (0..w.n) |i| {
                    if (spanIs(w.key(i), want_key)) found = @intCast(i);
                }
                check(found >= 0, "row '{s}' not in the result", .{want_key});
            } else {
                var doc: ?*const c.corvid_value = null;
                var i: i64 = 0;
                while (i <= found) : (i += 1) {
                    var k: [*c]const u8 = null;
                    var kl: usize = 0;
                    var sc: f32 = 0;
                    if (c.corvid_rows_next(rows, &k, &kl, &doc, &sc) != 1)
                        fail("rows disappeared on the second pass", .{});
                }
                checkValue(doc, expected);
            }
            c.corvid_rows_free(rows);
        }
        return;
    }
    if (spanIs(op, "AGG_COUNT")) {
        const q = c.corvid_query_new(docs());
        var n: usize = 0;
        expectOk(c.corvid_query_count(q, &n)); // consumes
        expectNum(expected, @intCast(n));
        return;
    }
    if (spanIs(op, "AGG_DISTINCT")) {
        const q = c.corvid_query_new(docs());
        var n: usize = 0;
        expectOk(c.corvid_query_count_distinct(q, a[0].ptr, a[0].len, &n));
        expectNum(expected, @intCast(n));
        return;
    }
    if (spanIs(op, "AGG_SUM")) {
        const q = c.corvid_query_new(docs());
        var sum: f64 = 0;
        expectOk(c.corvid_query_sum(q, a[0].ptr, a[0].len, &sum));
        check(doubleMatches(sum, expected), "sum {d} vs '{s}'", .{ sum, expected });
        return;
    }
    if (spanIs(op, "AGG_AVG")) {
        const q = c.corvid_query_new(docs());
        var avg: f64 = 0;
        var has: i32 = -1;
        expectOk(c.corvid_query_avg(q, a[0].ptr, a[0].len, &avg, &has));
        if (spanIs(expected, "none")) {
            check(has == 0, "avg has={d}, want '{s}'", .{ has, expected });
        } else {
            check(has != 0, "avg has={d}, want '{s}'", .{ has, expected });
            check(doubleMatches(avg, expected), "avg {d} vs '{s}'", .{ avg, expected });
        }
        return;
    }
    if (spanIs(op, "AGG_MIN") or spanIs(op, "AGG_MAX")) {
        const q = c.corvid_query_new(docs());
        var out: ?*c.corvid_value = null;
        const st = if (op[5] == 'I')
            c.corvid_query_min(q, a[0].ptr, a[0].len, &out)
        else
            c.corvid_query_max(q, a[0].ptr, a[0].len, &out);
        expectOk(st);
        if (spanIs(expected, "absent")) {
            check(out == null, "expected absence", .{});
        } else {
            check(out != null, "expected a value", .{});
            checkValue(out, expected);
            c.corvid_value_free(out);
        }
        return;
    }
    if (spanIs(op, "AGG_GCOUNT") or spanIs(op, "AGG_GSUM") or spanIs(op, "AGG_GAVG")) {
        const q = c.corvid_query_new(docs());
        var it: ?*c.corvid_groupiter = null;
        if (op[5] == 'C') {
            it = c.corvid_query_group_count(q, a[0].ptr, a[0].len);
        } else if (op[5] == 'S') {
            it = c.corvid_query_group_sum(q, a[0].ptr, a[0].len, a[1].ptr, a[1].len);
        } else {
            it = c.corvid_query_group_avg(q, a[0].ptr, a[0].len, a[1].ptr, a[1].len);
        }
        check(it != null, "group aggregate failed (query consumed)", .{});
        // §7 inert rule exercised once with a NULL handle.
        check(c.corvid_groupiter_next(null, null, null, null) == 0,
            "NULL-handle groupiter_next must answer 0", .{});
        check(expected.len >= 3 and expected[0] == 'g' and expected[1] == '(' and
            expected[expected.len - 1] == ')',
            "group expectation must be g(...)", .{});
        const body = expected[2 .. expected.len - 1];
        var pairs: [32]Span = undefined;
        const np = if (body.len == 0) 0 else splitTop(body, &pairs);
        for (0..np) |i| {
            var key: [*c]const u8 = null;
            var key_len: usize = 0;
            var val: f64 = 0;
            check(c.corvid_groupiter_next(it, &key, &key_len, &val) == 1,
                "group {d} of {d} missing", .{ i + 1, np });
            var eq: ?usize = null;
            for (pairs[i], 0..) |ch, ci| {
                if (ch == '=') eq = ci;
            }
            const e = eq orelse fail("group pair needs key=val", .{});
            check(key_len == e and std.mem.eql(u8, key[0..key_len], pairs[i][0..e]),
                "group key '{s}', want '{s}'", .{ key[0..key_len], pairs[i][0..e] });
            const vtok = pairs[i][e + 1 ..];
            check(doubleMatches(val, vtok),
                "group '{s}' value {d} vs '{s}'", .{ key[0..key_len], val, vtok });
        }
        {
            var k: [*c]const u8 = null;
            var kl: usize = 0;
            var v: f64 = 0;
            check(c.corvid_groupiter_next(it, &k, &kl, &v) == 0,
                "group cursor not exhausted after {d} pairs", .{np});
        }
        c.corvid_groupiter_free(it);
        return;
    }

    // ---- graph ----
    if (spanIs(op, "LINK")) {
        expectOk(c.corvid_link(docs(), a[0].ptr, a[0].len, a[1].ptr, a[1].len, a[2].ptr, a[2].len));
        return;
    }
    if (spanIs(op, "LINK_W")) {
        expectOk(c.corvid_link_weighted(docs(), a[0].ptr, a[0].len, a[1].ptr, a[1].len, a[2].ptr, a[2].len, parseDouble(a[3])));
        return;
    }
    if (spanIs(op, "UNLINK")) {
        var removed: i32 = -1;
        expectOk(c.corvid_unlink(docs(), a[0].ptr, a[0].len, a[1].ptr, a[1].len, a[2].ptr, a[2].len, &removed));
        const want: []const u8 = if (removed != 0) "removed:1" else "removed:0";
        check(spanIs(expected, want), "unlink removed={d}, want '{s}'", .{ removed, expected });
        return;
    }
    if (spanIs(op, "NEIGHBORS") or spanIs(op, "IN_NEIGHBORS")) {
        const cur = if (op[0] == 'N')
            c.corvid_neighbors(docs(), a[0].ptr, a[0].len, a[1].ptr, a[1].len)
        else
            c.corvid_in_neighbors(docs(), a[0].ptr, a[0].len, a[1].ptr, a[1].len);
        check(cur != null, "neighbors failed", .{});
        var w = RowWalk{};
        while (true) {
            var item: [*c]const u8 = null;
            var ilen: usize = 0;
            if (c.corvid_strs_next(cur, &item, &ilen) != 1) break;
            check(w.n < MAX_ROWS, "neighbors overflow", .{});
            check(ilen < w.keys[0].len, "neighbor key too long", .{});
            @memcpy(w.keys[w.n][0..ilen], item[0..ilen]);
            w.key_lens[w.n] = ilen;
            w.n += 1;
        }
        c.corvid_strs_free(cur);
        checkKeys(&w, expected);
        return;
    }
    if (spanIs(op, "NEIGHBORS_W")) {
        const h = c.corvid_neighbors_weighted(docs(), a[0].ptr, a[0].len, a[1].ptr, a[1].len);
        check(h != null, "neighbors_weighted failed", .{});
        check(expected.len >= 3 and expected[0] == 'g' and expected[1] == '(' and
            expected[expected.len - 1] == ')',
            "weighted expectation must be g(...)", .{});
        const body = expected[2 .. expected.len - 1];
        var pairs: [32]Span = undefined;
        const np = if (body.len == 0) 0 else splitTop(body, &pairs);
        var i: usize = 0;
        while (true) {
            var hit: c.corvid_geohit = .{ .key = null, .key_len = 0, .distance_km = 0 };
            var doc: ?*const c.corvid_value = @ptrFromInt(1);
            if (c.corvid_geohits_next(h, &hit, &doc) != 1) break;
            check(doc == null, "weighted hits carry no document (§4.12)", .{});
            check(i < np, "more weighted hits ({d}) than expected ({d})", .{ i + 1, np });
            var eq: ?usize = null;
            for (pairs[i], 0..) |ch, ci| {
                if (ch == '=') eq = ci;
            }
            const e = eq orelse fail("weighted pair needs key=val", .{});
            check(hit.key_len == e and std.mem.eql(u8, hit.key[0..hit.key_len], pairs[i][0..e]),
                "weighted key '{s}', want '{s}'", .{ hit.key[0..hit.key_len], pairs[i][0..e] });
            const vtok = pairs[i][e + 1 ..];
            check(doubleMatches(hit.distance_km, vtok),
                "weight of '{s}' {d} vs '{s}'", .{ hit.key[0..hit.key_len], hit.distance_km, vtok });
            i += 1;
        }
        check(i == np, "weighted hits {d}, expected {d}", .{ i, np });
        c.corvid_geohits_free(h);
        return;
    }
    if (spanIs(op, "TRAVERSE")) {
        const cur = c.corvid_traverse(docs(), a[0].ptr, a[0].len, a[1].ptr, a[1].len, @intCast(parseI64(a[2])));
        check(cur != null, "traverse failed", .{});
        var w = RowWalk{};
        while (true) {
            var item: [*c]const u8 = null;
            var ilen: usize = 0;
            if (c.corvid_strs_next(cur, &item, &ilen) != 1) break;
            check(w.n < MAX_ROWS, "traverse overflow", .{});
            check(ilen < w.keys[0].len, "traverse key too long", .{});
            @memcpy(w.keys[w.n][0..ilen], item[0..ilen]);
            w.key_lens[w.n] = ilen;
            w.n += 1;
        }
        c.corvid_strs_free(cur);
        checkKeys(&w, expected);
        return;
    }

    // ---- geo ----
    if (spanIs(op, "GINSERT") or spanIs(op, "GINSERT_M")) {
        const map = mustVal(c.corvid_value_map_new());
        const loc: *c.corvid_value = if (op.len > 7) blk: {
            // GINSERT_M: {lat, lon} map form
            const l = mustVal(c.corvid_value_map_new());
            expectOk(c.corvid_value_map_put(l, "lat", 3, c.corvid_value_float(parseDouble(a[1]))));
            expectOk(c.corvid_value_map_put(l, "lon", 3, c.corvid_value_float(parseDouble(a[2]))));
            break :blk l;
        } else blk: {
            const l = mustVal(c.corvid_value_array_new());
            expectOk(c.corvid_value_array_push(l, c.corvid_value_float(parseDouble(a[1]))));
            expectOk(c.corvid_value_array_push(l, c.corvid_value_float(parseDouble(a[2]))));
            break :blk l;
        };
        expectOk(c.corvid_value_map_put(map, "loc", 3, loc));
        const st = c.corvid_insert(docs(), a[0].ptr, a[0].len, map);
        c.corvid_value_free(map);
        expectOk(st);
        return;
    }
    if (spanIs(op, "RADIUS") or spanIs(op, "NEAREST") or spanIs(op, "BBOX")) {
        const h: ?*c.corvid_geohits = if (op[0] == 'R')
            c.corvid_geo_within_radius(docs(), a[0].ptr, a[0].len, parseDouble(a[1]), parseDouble(a[2]), parseDouble(a[3]))
        else if (op[0] == 'N')
            c.corvid_geo_nearest(docs(), a[0].ptr, a[0].len, parseDouble(a[1]), parseDouble(a[2]), @intCast(parseI64(a[3])))
        else
            c.corvid_geo_within_bbox(docs(), a[0].ptr, a[0].len, parseDouble(a[1]), parseDouble(a[2]), parseDouble(a[3]), parseDouble(a[4]));
        check(h != null, "geo query failed", .{});
        var w = RowWalk{};
        var dists: [MAX_ROWS]f64 = undefined;
        var nd: usize = 0;
        while (true) {
            var hit: c.corvid_geohit = .{ .key = null, .key_len = 0, .distance_km = 0 };
            var doc: ?*const c.corvid_value = null;
            if (c.corvid_geohits_next(h, &hit, &doc) != 1) break;
            check(doc != null, "geo hits carry their document", .{});
            check(w.n < MAX_ROWS, "geo overflow", .{});
            check(hit.key_len < w.keys[0].len, "geo key too long", .{});
            @memcpy(w.keys[w.n][0..hit.key_len], hit.key[0..hit.key_len]);
            w.key_lens[w.n] = hit.key_len;
            w.n += 1;
            if (nd < MAX_ROWS) {
                dists[nd] = hit.distance_km;
                nd += 1;
            }
        }
        c.corvid_geohits_free(h);
        checkKeys(&w, keyPart(expected));
        const sp = suffixPart(expected);
        if (sp.len != 0) {
            check(sp[0] == '|', "geo suffix must start with |", .{});
            const body = sp[1..];
            var toks: [32]Span = undefined;
            const nt = if (body.len != 0) splitTop(body, &toks) else 0;
            check(nd == nt, "distance count {d}, expected {d}", .{ nd, nt });
            for (0..nt) |i| {
                check(doubleMatches(dists[i], toks[i]),
                    "hit {d} distance {d} vs '{s}'", .{ i, dists[i], toks[i] });
            }
        }
        return;
    }
    if (spanIs(op, "BBOX_ERR")) {
        const h = c.corvid_geo_within_bbox(docs(), a[0].ptr, a[0].len, parseDouble(a[1]), parseDouble(a[2]), parseDouble(a[3]), parseDouble(a[4]));
        check(h == null, "bbox unexpectedly succeeded", .{});
        expectErr(c.CORVID_ERR, errToken(expected));
        return;
    }

    // ---- schema & indexes ----
    if (spanIs(op, "SET_SCHEMA")) {
        var defs: [16]c.corvid_field_def = undefined;
        var flds: [16]Span = undefined;
        const n = splitTop(args, &flds);
        for (0..n) |i| {
            // field specs split on '#' (no nesting inside a spec)
            var part: [4]Span = undefined;
            var np: usize = 0;
            const fld = flds[i];
            var seg_start: usize = 0;
            var fp: usize = 0;
            while (fp <= fld.len and np < 4) : (fp += 1) {
                if (fp == fld.len or fld[fp] == '#') {
                    part[np] = fld[seg_start..fp];
                    np += 1;
                    seg_start = fp + 1;
                }
            }
            check(np == 4, "field spec needs name#type#required#unique", .{});
            defs[i] = .{
                .name = part[0].ptr,
                .name_len = part[0].len,
                .type = parseFieldType(part[1]),
                .required = @intFromBool(spanIs(part[2], "1")),
                .unique = @intFromBool(spanIs(part[3], "1")),
            };
        }
        expectOk(c.corvid_set_schema(docs(), &defs, n));
        return;
    }
    if (spanIs(op, "SCHEMA")) {
        const tn = [_][]const u8{ "any", "bool", "int", "float", "text", "bytes", "array", "map", "vector" };
        var it: ?*c.corvid_schemaiter = null;
        expectOk(c.corvid_schema(docs(), &it));
        check(it != null, "a schema must be declared first", .{});
        var gotb: [512]u8 = undefined;
        var g = Buf{ .data = &gotb };
        while (true) {
            var f: c.corvid_field_def = .{ .name = null, .name_len = 0, .type = c.CORVID_FIELD_ANY, .required = 0, .unique = 0 };
            if (c.corvid_schemaiter_next(it, &f) != 1) break;
            if (g.len != 0) g.append(",", .{});
            g.append("{s}/{s}/{d}/{d}", .{
                @as([*]const u8, @ptrCast(f.name))[0..f.name_len],
                tn[@as(usize, @intCast(f.type)) % 9],
                f.required,
                f.unique,
            });
        }
        c.corvid_schemaiter_free(it);
        check(spanIs(expected, g.slice()), "schema {s}, want '{s}'", .{ g.slice(), expected });
        return;
    }
    if (spanIs(op, "SCHEMA9")) {
        const names = [9][]const u8{ "f_any", "f_bool", "f_int", "f_float", "f_text", "f_bytes", "f_vector", "f_array", "f_map" };
        const types = [9]c.corvid_field_type{
            c.CORVID_FIELD_ANY,    c.CORVID_FIELD_BOOL,  c.CORVID_FIELD_INT,
            c.CORVID_FIELD_FLOAT,  c.CORVID_FIELD_TEXT,  c.CORVID_FIELD_BYTES,
            c.CORVID_FIELD_VECTOR, c.CORVID_FIELD_ARRAY, c.CORVID_FIELD_MAP,
        };
        var defs: [9]c.corvid_field_def = undefined;
        for (0..9) |i| {
            defs[i] = .{
                .name = names[i].ptr,
                .name_len = names[i].len,
                .type = types[i],
                .required = @intFromBool(i == 1),
                .unique = @intFromBool(i == 8),
            };
        }
        expectOk(c.corvid_set_schema(docs(), &defs, 9));
        var it: ?*c.corvid_schemaiter = null;
        expectOk(c.corvid_schema(docs(), &it));
        check(it != null, "the 9-field schema must be declared", .{});
        var gotb: [64]u8 = undefined;
        var g = Buf{ .data = &gotb };
        var i: usize = 0;
        while (true) {
            var f: c.corvid_field_def = .{ .name = null, .name_len = 0, .type = c.CORVID_FIELD_ANY, .required = 0, .unique = 0 };
            if (c.corvid_schemaiter_next(it, &f) != 1) break;
            check(i < 9 and f.type == types[i] and f.name_len == names[i].len and
                std.mem.eql(u8, @as([*]const u8, @ptrCast(f.name))[0..f.name_len], names[i]),
                "field {d} did not round-trip", .{i});
            if (i != 0) g.append(",", .{});
            g.append("{d}", .{@as(u32, @intCast(f.type))});
            i += 1;
        }
        c.corvid_schemaiter_free(it);
        check(i == 9, "expected exactly 9 fields, saw {d}", .{i});
        check(spanIs(expected, g.slice()), "schema9 {s}, want '{s}'", .{ g.slice(), expected });
        return;
    }
    if (spanIs(op, "SCHEMA_ERR")) {
        const v = lit(a[1]);
        const st = c.corvid_insert(docs(), a[0].ptr, a[0].len, v);
        c.corvid_value_free(v);
        expectErr(st, errToken(expected));
        return;
    }
    if (spanIs(op, "IDX_SCALAR")) {
        expectOk(c.corvid_create_scalar_index(docs(), a[0].ptr, a[0].len));
        return;
    }
    if (spanIs(op, "IDX_COMPOUND")) {
        var flds: [8]Span = undefined;
        const n = splitTop(args, &flds);
        var names: [8][*c]const u8 = undefined;
        var lens: [8]usize = undefined;
        for (0..n) |i| {
            names[i] = flds[i].ptr;
            lens[i] = flds[i].len;
        }
        expectOk(c.corvid_create_compound_index(docs(), &names, &lens, n));
        return;
    }
    if (spanIs(op, "IDX_TEXT")) {
        expectOk(c.corvid_create_text_index(docs(), a[0].ptr, a[0].len));
        return;
    }
    if (spanIs(op, "IDX_TEXT_DISK")) {
        expectOk(c.corvid_create_text_index_ondisk(docs(), a[0].ptr, a[0].len));
        return;
    }
    if (spanIs(op, "IDX_GEO")) {
        expectOk(c.corvid_create_geo_index(docs(), a[0].ptr, a[0].len));
        return;
    }
    if (spanIs(op, "IDX_VEC")) {
        expectOk(c.corvid_create_vector_index(docs(), a[0].ptr, a[0].len, parseMetric(a[1])));
        return;
    }
    if (spanIs(op, "IDX_VEC_Q")) {
        expectOk(c.corvid_create_vector_index_quantized(docs(), a[0].ptr, a[0].len, parseMetric(a[1]), parseQuant(a[2])));
        return;
    }
    if (spanIs(op, "IDX_VEC_DISK")) {
        expectOk(c.corvid_create_vector_index_ondisk(docs(), a[0].ptr, a[0].len, parseMetric(a[1])));
        return;
    }
    if (spanIs(op, "IDX_VEC_DISK_Q")) {
        expectOk(c.corvid_create_vector_index_ondisk_quantized(docs(), a[0].ptr, a[0].len, parseMetric(a[1]), parseQuant(a[2])));
        return;
    }
    if (spanIs(op, "IDX_PQ") or spanIs(op, "IDX_PQ_DISK") or spanIs(op, "IDX_PQ_ERR")) {
        const st = if (spanIs(op, "IDX_PQ_DISK"))
            c.corvid_create_vector_index_ondisk_pq(docs(), a[0].ptr, a[0].len, parseMetric(a[1]), @intCast(parseI64(a[2])), @intCast(parseI64(a[3])))
        else
            c.corvid_create_vector_index_pq(docs(), a[0].ptr, a[0].len, parseMetric(a[1]), @intCast(parseI64(a[2])), @intCast(parseI64(a[3])));
        if (spanIs(op, "IDX_PQ_ERR")) {
            check(st == c.CORVID_ERR, "pq create unexpectedly succeeded", .{});
            expectErr(st, errToken(expected));
        } else {
            expectOk(st);
        }
        return;
    }

    // ---- admin & persistence ----
    if (spanIs(op, "FILEDB")) {
        openFile(scn.db_path);
        return;
    }
    if (spanIs(op, "FILEDB2")) {
        openFile(scn.db2_path);
        return;
    }
    if (spanIs(op, "DUMP")) {
        const p = scn.dump_path;
        expectOk(c.corvid_dump_to_path(scn.db, p.ptr, p.len));
        return;
    }
    if (spanIs(op, "LOAD")) {
        const p = scn.dump_path;
        expectOk(c.corvid_load_from_path(scn.db, p.ptr, p.len));
        return;
    }
    if (spanIs(op, "LOAD_RENAMES")) {
        // count=1: only the first slot is read; the second satisfies
        // the non-optional element type translate-c produced.
        const olds = [2][*c]const u8{ a[0].ptr, a[0].ptr };
        const news = [2][*c]const u8{ a[1].ptr, a[1].ptr };
        const olens = [2]usize{ a[0].len, 0 };
        const nlens = [2]usize{ a[1].len, 0 };
        const p = scn.dump_path;
        const st = c.corvid_load_from_path_with_renames(scn.db, p.ptr, p.len, &olds, &news, &olens, &nlens, 1);
        if (expected.len > 4 and std.mem.startsWith(u8, expected, "err:")) {
            expectErr(st, errToken(expected));
        } else {
            expectOk(st);
        }
        return;
    }
    if (spanIs(op, "COLLECTIONS")) {
        const cur = c.corvid_collections(scn.db);
        check(cur != null, "corvid_collections failed", .{});
        var w = RowWalk{};
        while (true) {
            var item: [*c]const u8 = null;
            var ilen: usize = 0;
            if (c.corvid_strs_next(cur, &item, &ilen) != 1) break;
            check(w.n < MAX_ROWS, "collections overflow", .{});
            check(ilen < w.keys[0].len, "collection name too long", .{});
            @memcpy(w.keys[w.n][0..ilen], item[0..ilen]);
            w.key_lens[w.n] = ilen;
            w.n += 1;
        }
        c.corvid_strs_free(cur);
        checkKeys(&w, expected);
        return;
    }
    if (spanIs(op, "BACKUP")) {
        const p = scn.backup_path;
        expectOk(c.corvid_backup(scn.db, p.ptr, p.len));
        return;
    }
    if (spanIs(op, "BACKUP_DUP")) {
        const p = scn.backup_path;
        expectErr(c.corvid_backup(scn.db, p.ptr, p.len), c.CORVID_E_BACKUP_TARGET_EXISTS);
        return;
    }
    if (spanIs(op, "COMPACT_BUSY")) {
        expectErr(c.corvid_compact(scn.db, null), c.CORVID_E_BUSY);
        return;
    }
    if (spanIs(op, "COMPACT")) {
        closeColl(); // quiesce: the derived-handle gate (§4.13)
        var moved: c_int = -1;
        expectOk(c.corvid_compact(scn.db, &moved));
        check(moved == 0 or moved == 1, "moved_out must be boolean", .{});
        _ = docs(); // re-acquire for subsequent lines
        return;
    }
    if (spanIs(op, "REOPEN")) {
        const path = scn.db_path;
        closeDb();
        scn.db = c.corvid_open(path.ptr, path.len);
        check(scn.db != null, "reopen of {s} failed", .{path});
        _ = docs();
        return;
    }

    fail("unknown OP '{s}'", .{op});
}

// ------------------------------------------------------------------
// Fixture-file driver
// ------------------------------------------------------------------

// values.txt runs against no db; every other file starts in-memory
// (admin/persist switch to file dbs via their OPs).
fn startsWithDb(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return !std.mem.eql(u8, base, "values.txt");
}

fn runScenario(alloc: std.mem.Allocator, path: []const u8) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io(), path, alloc, .limited(1 << 30)) catch |e| {
        fail("cannot open fixture {s} ({s})", .{ path, @errorName(e) });
    };
    defer alloc.free(data);

    g_file = path;
    g_line = 0;
    scn.db = null;
    scn.coll = null;
    scn.last_auto_id = 0;
    // Scratch paths are per-scenario (keyed on the fixture basename) so
    // file-db scenarios sharing one workdir never touch each other's
    // files.
    {
        const base = std.fs.path.basename(path);
        const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
        const wd = scn.workdir;
        scn.db_path = std.fmt.bufPrint(&scn.db_path_buf, "{s}/{s}.redb", .{ wd, stem }) catch
            fail("db path too long", .{});
        scn.db2_path = std.fmt.bufPrint(&scn.db2_path_buf, "{s}/{s}-2.redb", .{ wd, stem }) catch
            fail("db2 path too long", .{});
        scn.dump_path = std.fmt.bufPrint(&scn.dump_path_buf, "{s}/{s}.dump", .{ wd, stem }) catch
            fail("dump path too long", .{});
        scn.backup_path = std.fmt.bufPrint(&scn.backup_path_buf, "{s}/{s}.backup.redb", .{ wd, stem }) catch
            fail("backup path too long", .{});
    }
    if (startsWithDb(path)) openMemory();

    // `lines` is counted in an INDEPENDENT pre-scan (the same rule the
    // Rust driver applies), so a dispatch loop that skips a counted
    // line — a stray `continue`, a swallowed branch — diverges from
    // `executed` and the check below reports it, instead of the two
    // fields silently reading one counter. The scan is non-destructive:
    // the dispatch pass re-slices the same buffer.
    var lines: usize = 0;
    {
        var rest: Span = data;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const line_end = nl orelse rest.len;
            var first: usize = 0;
            while (first < line_end and (rest[first] == ' ' or rest[first] == '\r')) first += 1;
            if (first < line_end and rest[first] != '#') lines += 1;
            rest = if (nl) |n| rest[n + 1 ..] else rest[rest.len..];
        }
    }

    var executed: usize = 0;
    var rest: Span = data;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        var line = rest[0 .. nl orelse rest.len];
        rest = if (nl) |n| rest[n + 1 ..] else rest[rest.len..];

        while (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0 or line[0] == '#') continue;
        g_line += 1;

        // OP \t ARGS \t EXPECTED (sliced, not NUL-split — the buffer
        // stays immutable, exactly like the pre-scan's view of it)
        const tab1 = std.mem.indexOfScalar(u8, line, '\t');
        const tab2 = if (tab1) |t1| std.mem.indexOfScalarPos(u8, line, t1 + 1, '\t') else null;
        var op: Span = undefined;
        var fargs: Span = undefined;
        var fexpected: Span = undefined;
        if (tab1 == null) {
            op = line;
            fargs = line[0..0];
            fexpected = line[0..0];
        } else if (tab2 == null) {
            op = line[0..tab1.?];
            fargs = line[tab1.? + 1 ..];
            fexpected = line[0..0];
        } else {
            op = line[0..tab1.?];
            fargs = line[tab1.? + 1 .. tab2.?];
            fexpected = line[tab2.? + 1 ..];
        }
        g_op = op;
        runLine(op, fargs, fexpected);
        executed += 1;
    }
    closeDb();
    if (executed != lines)
        fail("dispatched {d} of {d} counted executable lines", .{ executed, lines });
    stdoutf("SMOKE {s} lines={d} executed={d}\n", .{ path, lines, executed });
}

pub fn main(init: std.process.Init) u8 {
    g_io = init.io;
    const alloc = init.arena.allocator();

    var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return 2;
    defer args_it.deinit();
    var argv = std.ArrayList([]const u8).empty;
    while (args_it.next()) |arg| argv.append(alloc, arg) catch return 2;

    if (argv.items.len < 3) {
        std.debug.print("usage: golden <workdir> <fixture.txt> [fixture.txt ...]\n", .{});
        return 2;
    }
    const workdir = argv.items[1];

    // The harness owns its workdir: idempotent re-runs must not see stale
    // .redb/.dump files from an earlier scenario.
    std.Io.Dir.cwd().deleteTree(io(), workdir) catch {};
    std.Io.Dir.cwd().createDirPath(io(), workdir) catch |e| {
        std.debug.print("golden: cannot create workdir {s} ({s})\n", .{ workdir, @errorName(e) });
        return 2;
    };
    const wd_len = @min(workdir.len, scn.workdir_buf.len);
    @memcpy(scn.workdir_buf[0..wd_len], workdir[0..wd_len]);
    scn.workdir = scn.workdir_buf[0..wd_len];

    if (c.corvid_ffi_version() != 1) {
        std.debug.print("FAIL wrong FFI_VERSION {d}\n", .{c.corvid_ffi_version()});
        return 1;
    }
    for (argv.items[2..]) |fixture| runScenario(alloc, fixture);
    return 0;
}
