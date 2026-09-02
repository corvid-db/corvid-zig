//! corvid — idiomatic Zig bindings for the corvid embedded database.
//!
//! Wraps the typed C ABI (`corvid.h`, 124 symbols at engine v0.3.0) that
//! ships in every corvid release archive. The raw ABI stays available as
//! `corvid.c` (the @cImport of the fetched header) for golden-suite-style
//! driving; everything below is the idiomatic layer:
//!
//!   - handles become structs with `deinit()` (`Db`, `Collection`, `Query`,
//!     `Pred`, cursors) — `defer x.deinit()` is the ownership model;
//!   - `CORVID_ERR` + the thread-local last error become Zig error unions
//!     (`Error`), one error per `corvid_err` code plus `Unexpected`;
//!   - consumed-by-call arguments (`pred` trees, query builders) are moved
//!     and rendered inert — the double-use/double-free UB class of the C
//!     ABI is a no-op here, never undefined;
//!   - borrowed views (`ValueView`, row/key/str slices) are DISTINCT types
//!     from owned handles: calling `deinit` on a borrow is a compile error
//!     in Zig, where in C it is undefined behavior (spec §4.4);
//!   - the C fn-pointer callbacks (`update`, `scan`) take Zig closures —
//!     a context pointer plus a Zig function; an `error` returned from an
//!     `update` callback aborts the read-modify-write cleanly through the
//!     ABI's abort channel (§1.6), and a panic never unwinds through C
//!     frames (Zig panics abort), so callback panic-safety is structural.
//!
//! Strings crossing the ABI are `[]const u8` slices (engine strings are
//! UTF-8, keys/bytes arbitrary — spec §1.5); vectors are `[]const f32`.
//!
//! Threading: synchronous, one thread per `Db` at a time, exactly the ABI
//! contract (FFI.md §6). The last-error slot is thread-local.

const std = @import("std");

/// The raw C ABI — `@cImport` of the header fetched into `deps/`.
/// Exposed because the golden-suite harness (test/golden.zig) drives the
/// ABI exactly the way the engine's own C harness does; application code
/// should stick to the types below.
pub const c = @cImport({
    @cInclude("corvid.h");
});

// --------------------------------------------------------------------------
// Errors — one per corvid_err code (FFI.md §1.3), plus Unexpected
// --------------------------------------------------------------------------

/// The mapped error set: every `CORVID_E_*` code (19 of them, spec §1.3
/// frozen) becomes exactly one Zig error, plus `Unexpected` for codes this
/// build does not know (forward compatibility: the ABI only appends).
pub const Error = error{
    Database,
    Transaction,
    Table,
    Storage,
    Commit,
    SetDurability,
    Compaction,
    Decode,
    CorruptIndex,
    ReservedCollection,
    InvalidName,
    InvalidArgument,
    IncompatibleFormat,
    EmptyIndexTraining,
    SchemaViolation,
    InvalidDump,
    BackupTargetExists,
    Io,
    Busy,
    Unexpected,
};

/// The `corvid_err` codes as a Zig enum (values are the ABI's, spec §1.3).
pub const ErrCode = enum(c.corvid_err) {
    ok = c.CORVID_E_OK,
    database = c.CORVID_E_DATABASE,
    transaction = c.CORVID_E_TRANSACTION,
    table = c.CORVID_E_TABLE,
    storage = c.CORVID_E_STORAGE,
    commit = c.CORVID_E_COMMIT,
    set_durability = c.CORVID_E_SET_DURABILITY,
    compaction = c.CORVID_E_COMPACTION,
    decode = c.CORVID_E_DECODE,
    corrupt_index = c.CORVID_E_CORRUPT_INDEX,
    reserved_collection = c.CORVID_E_RESERVED_COLLECTION,
    invalid_name = c.CORVID_E_INVALID_NAME,
    argument = c.CORVID_E_ARGUMENT,
    incompatible_format = c.CORVID_E_INCOMPATIBLE_FORMAT,
    empty_index_training = c.CORVID_E_EMPTY_INDEX_TRAINING,
    schema_violation = c.CORVID_E_SCHEMA_VIOLATION,
    invalid_dump = c.CORVID_E_INVALID_DUMP,
    backup_target_exists = c.CORVID_E_BACKUP_TARGET_EXISTS,
    io = c.CORVID_E_IO,
    busy = c.CORVID_E_BUSY,
    _,
};

/// The thread-local last-error code (`CORVID_E_OK` when nothing failed on
/// this thread; successful calls never clear it — spec §3).
pub fn lastErrorCode() ErrCode {
    return @enumFromInt(c.corvid_last_error_code());
}

/// The thread-local last-error message, borrowed until the next failing
/// corvid call on this thread (empty slice when nothing is recorded).
pub fn lastErrorMessage() []const u8 {
    var len: usize = 0;
    const p = c.corvid_last_error_message(&len);
    if (p == null) return "";
    return @as([*]const u8, @ptrCast(p))[0..len];
}

/// Map the recorded last error to the Zig error set. Must be called only
/// right after a failing call (the slot is sticky, spec §3).
fn mapError() Error {
    return switch (lastErrorCode()) {
        .database => error.Database,
        .transaction => error.Transaction,
        .table => error.Table,
        .storage => error.Storage,
        .commit => error.Commit,
        .set_durability => error.SetDurability,
        .compaction => error.Compaction,
        .decode => error.Decode,
        .corrupt_index => error.CorruptIndex,
        .reserved_collection => error.ReservedCollection,
        .invalid_name => error.InvalidName,
        .argument => error.InvalidArgument,
        .incompatible_format => error.IncompatibleFormat,
        .empty_index_training => error.EmptyIndexTraining,
        .schema_violation => error.SchemaViolation,
        .invalid_dump => error.InvalidDump,
        .backup_target_exists => error.BackupTargetExists,
        .io => error.Io,
        .busy => error.Busy,
        else => error.Unexpected, // .ok (failed call, no code?) or newer
    };
}

/// CORVID_OK passes; CORVID_ERR maps the recorded code (spec §1.3).
fn check(st: c.corvid_status) Error!void {
    if (st != c.CORVID_OK) return mapError();
}

// --------------------------------------------------------------------------
// ABI enums — Zig-flavored, values frozen per FFI.md §1.4/§8
// --------------------------------------------------------------------------

/// The distance metric (spec §1.4).
pub const Metric = enum(c.corvid_metric) {
    cosine = c.CORVID_METRIC_COSINE,
    dot = c.CORVID_METRIC_DOT,
    l2 = c.CORVID_METRIC_L2,
};

/// The stored-vector quantization mode (spec §1.4).
pub const Quant = enum(c.corvid_quant) {
    none = c.CORVID_QUANT_NONE,
    binary = c.CORVID_QUANT_BINARY,
    scalar = c.CORVID_QUANT_SCALAR,
};

/// The comparison operator (spec §1.4).
pub const Cmp = enum(c.corvid_cmp) {
    eq = c.CORVID_CMP_EQ,
    ne = c.CORVID_CMP_NE,
    lt = c.CORVID_CMP_LT,
    le = c.CORVID_CMP_LE,
    gt = c.CORVID_CMP_GT,
    ge = c.CORVID_CMP_GE,
};

/// The declared type of a schema field (spec §1.4).
pub const FieldType = enum(c.corvid_field_type) {
    any = c.CORVID_FIELD_ANY,
    boolean = c.CORVID_FIELD_BOOL,
    int = c.CORVID_FIELD_INT,
    float = c.CORVID_FIELD_FLOAT,
    text = c.CORVID_FIELD_TEXT,
    bytes = c.CORVID_FIELD_BYTES,
    vector = c.CORVID_FIELD_VECTOR,
    array = c.CORVID_FIELD_ARRAY,
    map = c.CORVID_FIELD_MAP,
    _,
};

// --------------------------------------------------------------------------
// Values — Value (owned) and ValueView (borrowed)
// --------------------------------------------------------------------------

/// The value discriminant (spec §1.4): tags 0..=8.
pub const ValueKind = enum(c.corvid_value_type_t) {
    null_value = c.CORVID_TYPE_NULL,
    boolean = c.CORVID_TYPE_BOOL,
    int = c.CORVID_TYPE_INT,
    float = c.CORVID_TYPE_FLOAT,
    text = c.CORVID_TYPE_TEXT,
    bytes = c.CORVID_TYPE_BYTES,
    array = c.CORVID_TYPE_ARRAY,
    map = c.CORVID_TYPE_MAP,
    vector = c.CORVID_TYPE_VECTOR,
    _,
};

/// An OWNED `corvid_value*` — what every constructor returns. Free it with
/// `deinit` (usually `defer`). Pushing it into a `Value` array/map or
/// handing it to a consuming call MOVES it: the handle goes stale inside
/// this wrapper (`h` is nulled) so a stale `deinit` is a harmless no-op,
/// not the C ABI's double free.
pub const Value = struct {
    h: ?*c.corvid_value = null,

    /// `Value::Null` (spec §4.3).
    pub fn nullValue() Value {
        return .{ .h = c.corvid_value_null() };
    }
    /// `Value::Bool` (spec §4.3).
    pub fn boolean(v: bool) Value {
        return .{ .h = c.corvid_value_bool(@intFromBool(v)) };
    }
    /// `Value::Int` (spec §4.3).
    pub fn int(v: i64) Value {
        return .{ .h = c.corvid_value_int(v) };
    }
    /// `Value::Float` (spec §4.3) — NaN/±inf/-0.0 cross bit-exact.
    pub fn float(v: f64) Value {
        return .{ .h = c.corvid_value_float(v) };
    }
    /// `Value::Text` (spec §4.3): bytes CLONED; `s` must be valid UTF-8
    /// (spec §1.5) — invalid UTF-8 is `error.InvalidArgument`.
    pub fn text(s: []const u8) Error!Value {
        const h = c.corvid_value_text(s.ptr, s.len) orelse return mapError();
        return .{ .h = h };
    }
    /// `Value::Bytes` (spec §4.3): arbitrary bytes, CLONED.
    pub fn bytes(b: []const u8) Value {
        return .{ .h = c.corvid_value_bytes(b.ptr, b.len).? };
    }
    /// `Value::Vector` (spec §4.3): floats CLONED; dim 0 is legal (pass
    /// any non-empty zero-length slice, e.g. `&.{}`).
    pub fn vector(v: []const f32) Value {
        return .{ .h = c.corvid_value_vector(if (v.len == 0) &[_]f32{} else v.ptr, v.len).? };
    }
    /// `Value::Array(vec![])` — the array builder root (spec §4.3).
    pub fn array() Value {
        return .{ .h = c.corvid_value_array_new() };
    }
    /// `Value::Map(BTreeMap::new())` — the map builder root (spec §4.3).
    pub fn map() Value {
        return .{ .h = c.corvid_value_map_new() };
    }

    /// Free the owned value (spec §4.4). No-op after the value was moved
    /// into a parent or consumed by a call.
    pub fn deinit(self: Value) void {
        if (self.h) |h| c.corvid_value_free(h);
    }

    /// True once the value was moved/consumed (debug aid).
    pub fn consumed(self: Value) bool {
        return self.h == null;
    }

    /// A borrowed read-side view of this owned value.
    pub fn view(self: Value) ValueView {
        return .{ .h = self.h.? };
    }

    /// Deep copy returning a new OWNED value (spec §4.4) — the sanctioned
    /// way to keep data seen through a borrow beyond the parent's life.
    pub fn clone(self: Value) Error!Value {
        const h = c.corvid_value_clone(self.h) orelse return mapError();
        return .{ .h = h };
    }

    /// Insert `v` under `key`, CONSUMING `v` (spec §4.3/§8: consumption is
    /// unconditional — a failed put has still dropped it). This value must
    /// be a map (built by `Value.map` or cloned from one). Invalidates
    /// every view previously borrowed from this map (spec §5 rule 6).
    pub fn put(self: *Value, key: []const u8, v: *Value) Error!void {
        defer v.h = null; // moved into the map (or dropped), whatever happens
        try check(c.corvid_value_map_put(self.h, key.ptr, key.len, v.h));
    }

    /// Append `v`, CONSUMING it (spec §4.3/§8). This value must be an
    /// array. Invalidates previously borrowed children (spec §5 rule 6).
    pub fn push(self: *Value, v: *Value) Error!void {
        defer v.h = null;
        try check(c.corvid_value_array_push(self.h, v.h));
    }

    // Read-side conveniences (delegate to the view).
    pub fn kind(self: Value) ValueKind {
        return self.view().kind();
    }
    pub fn len(self: Value) usize {
        return self.view().len();
    }
    pub fn asBool(self: Value) ?bool {
        return self.view().asBool();
    }
    pub fn asInt(self: Value) ?i64 {
        return self.view().asInt();
    }
    pub fn asFloat(self: Value) ?f64 {
        return self.view().asFloat();
    }
    pub fn textRef(self: Value) ?[]const u8 {
        return self.view().textRef();
    }
    pub fn bytesRef(self: Value) ?[]const u8 {
        return self.view().bytesRef();
    }
    pub fn vectorRef(self: Value) ?[]const f32 {
        return self.view().vectorRef();
    }
    pub fn arrayGet(self: Value, index: usize) ?ValueView {
        return self.view().arrayGet(index);
    }
    pub fn mapGet(self: Value, key: []const u8) ?ValueView {
        return self.view().mapGet(key);
    }
    /// The map's keys in ascending byte order, as an owned cursor
    /// (spec §4.4; empty for a non-map — check `kind()` first).
    pub fn mapKeys(self: Value) Error!Strs {
        return self.view().mapKeys();
    }
};

/// A BORROWED value handle — an interior view into a parent's storage
/// (from `arrayGet`/`mapGet`/row documents), valid until the parent's next
/// mutation or free (spec §5 rule 6). There is deliberately NO `deinit`:
/// in C, freeing a borrowed child is undefined behavior; in Zig it is a
/// compile error. Keep data past the parent with `Value.clone`.
pub const ValueView = struct {
    h: *const c.corvid_value,

    /// The value's discriminant (spec §4.4).
    pub fn kind(self: ValueView) ValueKind {
        return @enumFromInt(c.corvid_value_type(self.h));
    }
    /// The value's length: array items / map entries / vector dims / text
    /// or bytes length; 0 for null/bool/int/float (spec §4.4).
    pub fn len(self: ValueView) usize {
        return c.corvid_value_len(self.h);
    }
    /// `Value::as_bool` (wrong type → null, not an error — spec §4.4).
    pub fn asBool(self: ValueView) ?bool {
        var ok: c_int = 0;
        const v = c.corvid_value_as_bool(self.h, &ok);
        return if (ok != 0) v != 0 else null;
    }
    /// `Value::as_int` (wrong type → null — spec §4.4).
    pub fn asInt(self: ValueView) ?i64 {
        var ok: c_int = 0;
        const v = c.corvid_value_as_int(self.h, &ok);
        return if (ok != 0) v else null;
    }
    /// `Value::as_float` (wrong type → null — spec §4.4).
    pub fn asFloat(self: ValueView) ?f64 {
        var ok: c_int = 0;
        const v = c.corvid_value_as_float(self.h, &ok);
        return if (ok != 0) v else null;
    }
    /// Zero-copy BORROWED view of the text — valid until the parent value
    /// is freed or mutated (spec §4.4); null on a different type.
    pub fn textRef(self: ValueView) ?[]const u8 {
        var len_out: usize = 0;
        const p = c.corvid_value_text_ref(self.h, &len_out);
        if (p == null) return null;
        return @as([*]const u8, @ptrCast(p))[0..len_out];
    }
    /// Zero-copy BORROWED view of the bytes (spec §4.4); null on a
    /// different type.
    pub fn bytesRef(self: ValueView) ?[]const u8 {
        var len_out: usize = 0;
        const p = c.corvid_value_bytes_ref(self.h, &len_out);
        if (p == null) return null;
        return @as([*]const u8, @ptrCast(p))[0..len_out];
    }
    /// Zero-copy BORROWED view of the vector (spec §4.4); null on a
    /// different type.
    pub fn vectorRef(self: ValueView) ?[]const f32 {
        var dim: usize = 0;
        const p = c.corvid_value_vector_ref(self.h, &dim);
        if (p == null) return null;
        return p[0..dim];
    }
    /// BORROWED child at `index` (null when not an array or out of range —
    /// spec §4.4). Valid until the parent's next mutation or free.
    pub fn arrayGet(self: ValueView, index: usize) ?ValueView {
        const h = c.corvid_value_array_get(self.h, index) orelse return null;
        return .{ .h = h };
    }
    /// BORROWED child under `key` (null when not a map or key absent —
    /// spec §4.4, counterpart of `Value::get`).
    pub fn mapGet(self: ValueView, key: []const u8) ?ValueView {
        const h = c.corvid_value_map_get(self.h, key.ptr, key.len) orelse return null;
        return .{ .h = h };
    }
    /// The map's keys as an OWNED string cursor in ascending key-byte
    /// order (spec §4.4, `corvid_value_map_keys` at v0.3.0). A non-map
    /// answers an EMPTY cursor — inert, not an error.
    pub fn mapKeys(self: ValueView) Error!Strs {
        const h = c.corvid_value_map_keys(self.h) orelse return mapError();
        return .{ .h = h };
    }
};

// --------------------------------------------------------------------------
// Cursors — Rows, Strs, GeoHits, GroupIter, SchemaIter
// --------------------------------------------------------------------------

/// One result row: `key` and `doc` are BORROWED from the cursor — valid
/// only until the next `Rows.next` or `Rows.deinit` (spec §4.6). `score`
/// is the fused RRF score (0.0 for pure filter/order/page rows; the BM25
/// phrase scale for `phraseSearch` rows).
pub const Row = struct {
    key: []const u8,
    doc: ValueView,
    score: f32,
};

/// The error union used by wrapper calls that allocate (the ABI mapping
/// plus the allocator's own failure mode).
pub const AllocError = Error || std.mem.Allocator.Error;

/// An OWNED rows cursor (spec §4.6) — iterate with `next() ?Row`.
pub const Rows = struct {
    h: ?*c.corvid_rows = null,

    pub fn deinit(self: *Rows) void {
        if (self.h) |h| c.corvid_rows_free(h);
        self.h = null;
    }

    /// Advance; null at exhaustion (spec §4.6). The returned row's borrows
    /// die at the NEXT call to `next`/`deinit`.
    pub fn next(self: *Rows) ?Row {
        var key: [*c]const u8 = null;
        var key_len: usize = 0;
        var doc: ?*const c.corvid_value = null;
        var score: f32 = 0.0;
        if (c.corvid_rows_next(self.h, &key, &key_len, &doc, &score) != 1) return null;
        return .{
            .key = key[0..key_len],
            .doc = .{ .h = doc.? },
            .score = score,
        };
    }
};

/// An OWNED string cursor (spec §4.12) — `next() ?[]const u8`, borrowed
/// until the next call or `deinit`.
pub const Strs = struct {
    h: ?*c.corvid_strs = null,

    pub fn deinit(self: *Strs) void {
        if (self.h) |h| c.corvid_strs_free(h);
        self.h = null;
    }

    pub fn next(self: *Strs) ?[]const u8 {
        var s: [*c]const u8 = null;
        var len: usize = 0;
        if (c.corvid_strs_next(self.h, &s, &len) != 1) return null;
        return @as([*]const u8, @ptrCast(s))[0..len];
    }
};

/// One geo/weighted hit (spec §4.12): `doc` is null for
/// `neighborsWeighted` cursors; `distance_km` is the haversine kilometres
/// (geo), the 0.0 bbox sentinel, or the edge weight (weighted neighbors).
pub const GeoHit = struct {
    key: []const u8,
    distance_km: f64,
    doc: ?ValueView,
};

/// An OWNED geo-hits cursor (spec §4.12).
pub const GeoHits = struct {
    h: ?*c.corvid_geohits = null,

    pub fn deinit(self: *GeoHits) void {
        if (self.h) |h| c.corvid_geohits_free(h);
        self.h = null;
    }

    pub fn next(self: *GeoHits) ?GeoHit {
        var hit: c.corvid_geohit = .{ .key = null, .key_len = 0, .distance_km = 0 };
        var doc: ?*const c.corvid_value = null;
        if (c.corvid_geohits_next(self.h, &hit, &doc) != 1) return null;
        return .{
            .key = @as([*]const u8, @ptrCast(hit.key))[0..hit.key_len],
            .distance_km = hit.distance_km,
            .doc = if (doc) |d| .{ .h = d } else null,
        };
    }
};

/// One `(group key, value)` pair (spec §4.7); `key` borrowed until the
/// next `next`/`deinit`.
pub const GroupEntry = struct {
    key: []const u8,
    value: f64,
};

/// An OWNED group-aggregate cursor (spec §4.7), ascending group-key order.
pub const GroupIter = struct {
    h: ?*c.corvid_groupiter = null,

    pub fn deinit(self: *GroupIter) void {
        if (self.h) |h| c.corvid_groupiter_free(h);
        self.h = null;
    }

    pub fn next(self: *GroupIter) ?GroupEntry {
        var key: [*c]const u8 = null;
        var key_len: usize = 0;
        var value: f64 = 0;
        if (c.corvid_groupiter_next(self.h, &key, &key_len, &value) != 1) return null;
        return .{
            .key = @as([*]const u8, @ptrCast(key))[0..key_len],
            .value = value,
        };
    }
};

/// One declared schema field (spec §1.2), as `schemaiter` hands it out;
/// `name` borrowed until the next `next`/`deinit`.
pub const Field = struct {
    name: []const u8,
    type: FieldType,
    required: bool,
    unique: bool,
};

/// The INPUT shape of `Collection.setSchema` (spec §4.10).
pub const FieldDef = struct {
    name: []const u8,
    type: FieldType,
    required: bool = false,
    unique: bool = false,
};

/// An OWNED schema cursor (spec §4.10), declaration order.
pub const SchemaIter = struct {
    h: ?*c.corvid_schemaiter = null,

    pub fn deinit(self: *SchemaIter) void {
        if (self.h) |h| c.corvid_schemaiter_free(h);
        self.h = null;
    }

    pub fn next(self: *SchemaIter) ?Field {
        var f: c.corvid_field_def = .{ .name = null, .name_len = 0, .type = c.CORVID_FIELD_ANY, .required = 0, .unique = 0 };
        if (c.corvid_schemaiter_next(self.h, &f) != 1) return null;
        return .{
            .name = @as([*]const u8, @ptrCast(f.name))[0..f.name_len],
            .type = @enumFromInt(f.type),
            .required = f.required != 0,
            .unique = f.unique != 0,
        };
    }
};

// --------------------------------------------------------------------------
// Db
// --------------------------------------------------------------------------

/// A database handle (spec §4.1). One thread at a time per handle; derived
/// handles keep the engine alive after `deinit` (spec §2).
pub const Db = struct {
    h: ?*c.corvid_db = null,

    /// Open (creating if absent) a file-backed database (spec §4.1);
    /// `path` borrowed UTF-8.
    pub fn open(path: []const u8) Error!Db {
        const h = c.corvid_open(path.ptr, path.len) orelse return mapError();
        return .{ .h = h };
    }

    /// A purely in-memory database (spec §4.1).
    pub fn openMemory() Error!Db {
        const h = c.corvid_open_memory() orelse return mapError();
        return .{ .h = h };
    }

    /// Release this reference (spec §4.1/§2). Inert after a prior
    /// `deinit` (the handle is nulled), like every wrapper here — the
    /// C ABI's double-close/double-free UB class cannot happen.
    pub fn deinit(self: *Db) void {
        if (self.h) |h| _ = c.corvid_close(h);
        self.h = null;
    }

    /// Handle to a named collection (spec §4.2); created lazily on first
    /// write. Reserved/invalid names fail at WRITE time (spec §4.8).
    pub fn collection(self: Db, name: []const u8) Error!Collection {
        const h = c.corvid_collection(self.h, name.ptr, name.len) orelse return mapError();
        return .{ .h = h };
    }

    /// User collection names, in name order (spec §4.12).
    pub fn collections(self: Db) Error!Strs {
        const h = c.corvid_collections(self.h) orelse return mapError();
        return .{ .h = h };
    }

    /// Write a logical dump of the whole database to `path` (spec §4.13).
    pub fn dumpToPath(self: Db, path: []const u8) Error!void {
        try check(c.corvid_dump_to_path(self.h, path.ptr, path.len));
    }

    /// Replay a dump into this database (spec §4.13; merges per the
    /// engine contract).
    pub fn loadFromPath(self: Db, path: []const u8) Error!void {
        try check(c.corvid_load_from_path(self.h, path.ptr, path.len));
    }

    /// Replay a dump with a collection-RENAME map `old -> new` (spec
    /// §4.13): every collection occurrence lands under the target name.
    pub fn loadFromPathWithRenames(self: Db, path: []const u8, renames: []const [2][]const u8) Error!void {
        var olds = std.ArrayList([*c]const u8).empty;
        var news = std.ArrayList([*c]const u8).empty;
        var old_lens = std.ArrayList(usize).empty;
        var new_lens = std.ArrayList(usize).empty;
        defer olds.deinit(std.heap.c_allocator);
        defer news.deinit(std.heap.c_allocator);
        defer old_lens.deinit(std.heap.c_allocator);
        defer new_lens.deinit(std.heap.c_allocator);
        const a = std.heap.c_allocator;
        try olds.ensureTotalCapacity(a, renames.len);
        try news.ensureTotalCapacity(a, renames.len);
        try old_lens.ensureTotalCapacity(a, renames.len);
        try new_lens.ensureTotalCapacity(a, renames.len);
        for (renames) |pair| {
            olds.appendAssumeCapacity(pair[0].ptr);
            old_lens.appendAssumeCapacity(pair[0].len);
            news.appendAssumeCapacity(pair[1].ptr);
            new_lens.appendAssumeCapacity(pair[1].len);
        }
        try check(c.corvid_load_from_path_with_renames(
            self.h,
            path.ptr,
            path.len,
            olds.items.ptr,
            news.items.ptr,
            old_lens.items.ptr,
            new_lens.items.ptr,
            renames.len,
        ));
    }

    /// Consistent point-in-time PHYSICAL backup to a FRESH file (spec
    /// §4.13); an existing target fails with `error.BackupTargetExists`.
    pub fn backup(self: Db, path: []const u8) Error!void {
        try check(c.corvid_backup(self.h, path.ptr, path.len));
    }

    /// Reclaim file space after heavy deletes (spec §4.13) — requires
    /// quiescence (every derived handle freed) or fails `error.Busy`.
    /// `moved_out` reports whether any data moved.
    pub fn compact(self: Db, moved_out: ?*bool) Error!void {
        var moved: c_int = -1;
        try check(c.corvid_compact(self.h, &moved));
        if (moved_out) |m| m.* = moved != 0;
    }
};

/// The ABI version this binding targets: 1 (spec §4.1/§8). Bindings
/// verify before anything else.
pub fn ffiVersion() u32 {
    return c.corvid_ffi_version();
}

// --------------------------------------------------------------------------
// Predicates
// --------------------------------------------------------------------------

/// A predicate tree (spec §4.5). Consuming calls (`Collection.deleteWhere`,
/// `Query.filter`, and the `andOp`/`orOp`/`notOp` combinators) MOVE the
/// tree; a moved `Pred` answers `consumed()` and its `deinit` is a no-op —
/// the C ABI's consumed-then-freed UB class cannot happen here.
pub const Pred = struct {
    h: ?*c.corvid_pred = null,

    /// `field(path).exists()` (spec §4.5). The empty path matches nothing.
    pub fn exists(path: []const u8) Error!Pred {
        const h = c.corvid_pred_exists(path.ptr, path.len) orelse return mapError();
        return .{ .h = h };
    }

    /// `field(path).eq/ne/lt/le/gt/ge(v)` (spec §4.5). `v` is borrowed for
    /// the call and CLONED into the tree — the caller keeps ownership.
    pub fn compare(path: []const u8, op: Cmp, v: Value) Error!Pred {
        const h = c.corvid_pred_compare(path.ptr, path.len, @intFromEnum(op), v.h) orelse return mapError();
        return .{ .h = h };
    }

    /// `field(path).is_in([...])` (spec §4.5); each value CLONED. An empty
    /// membership matches nothing.
    pub fn isIn(path: []const u8, values: []const Value) Error!Pred {
        const a = std.heap.c_allocator;
        var ptrs = std.ArrayList(?*const c.corvid_value).empty;
        defer ptrs.deinit(a);
        try ptrs.ensureTotalCapacity(a, values.len);
        for (values) |v| ptrs.appendAssumeCapacity(v.h);
        const h = c.corvid_pred_in(path.ptr, path.len, ptrs.items.ptr, values.len) orelse return mapError();
        return .{ .h = h };
    }

    /// `field(path).between(lo, hi)` (spec §4.5) — inclusive; both bounds
    /// borrowed and CLONED.
    pub fn between(path: []const u8, lo: Value, hi: Value) Error!Pred {
        const h = c.corvid_pred_between(path.ptr, path.len, lo.h, hi.h) orelse return mapError();
        return .{ .h = h };
    }

    /// `field(path).starts_with(prefix)` (spec §4.5).
    pub fn startsWith(path: []const u8, prefix: []const u8) Error!Pred {
        const h = c.corvid_pred_starts_with(path.ptr, path.len, prefix.ptr, prefix.len) orelse return mapError();
        return .{ .h = h };
    }

    /// `field(path).contains(s)` (spec §4.5).
    pub fn contains(path: []const u8, substr: []const u8) Error!Pred {
        const h = c.corvid_pred_contains(path.ptr, path.len, substr.ptr, substr.len) orelse return mapError();
        return .{ .h = h };
    }

    /// `field(path).within_km(lat, lon, r)` (spec §4.5) — inclusive
    /// haversine; a negative radius matches nothing (as the engine).
    pub fn geoWithin(path: []const u8, lat: f64, lon: f64, radius_km: f64) Error!Pred {
        const h = c.corvid_pred_geo_within(path.ptr, path.len, lat, lon, radius_km) orelse return mapError();
        return .{ .h = h };
    }

    /// Conjunction — CONSUMES both (spec §4.5/§5 rule 4). Pass pointers
    /// (`Pred.andOp(&a, &b)`); the operands are moved (rendered inert), so
    /// a later `deinit` on either is a safe no-op.
    pub fn andOp(a: *Pred, b: *Pred) Error!Pred {
        defer a.h = null;
        defer b.h = null;
        const h = c.corvid_pred_and(a.h, b.h) orelse return mapError();
        return .{ .h = h };
    }

    /// Disjunction — CONSUMES both (spec §4.5); operands are moved.
    pub fn orOp(a: *Pred, b: *Pred) Error!Pred {
        defer a.h = null;
        defer b.h = null;
        const h = c.corvid_pred_or(a.h, b.h) orelse return mapError();
        return .{ .h = h };
    }

    /// Negation — CONSUMES `a` (spec §4.5); the operand is moved.
    pub fn notOp(a: *Pred) Error!Pred {
        defer a.h = null;
        const h = c.corvid_pred_not(a.h) orelse return mapError();
        return .{ .h = h };
    }

    /// Free a never-consumed root (spec §4.5). No-op when consumed.
    pub fn deinit(self: *Pred) void {
        if (self.h) |h| c.corvid_pred_free(h);
        self.h = null;
    }

    /// True once consumed by a combinator / filter / deleteWhere.
    pub fn consumed(self: Pred) bool {
        return self.h == null;
    }
};

// --------------------------------------------------------------------------
// Query builder — method chaining, run() consumes
// --------------------------------------------------------------------------

/// A query builder (spec §4.6). Fluent: setters return `*Query` for
/// chaining; `run()` (or any aggregate) CONSUMES the builder — afterwards
/// `deinit` is a safe no-op, matching the ABI's one-of-the-two rule.
pub const Query = struct {
    h: ?*c.corvid_query = null,

    fn from(h: *c.corvid_query) Query {
        return .{ .h = h };
    }

    /// Add a filter — CONSUMES `pred` (spec §4.6; it is moved — later
    /// use/deinit of the pred is a safe no-op). Multiple calls AND.
    pub fn filter(self: *Query, pred: *Pred) Error!*Query {
        defer pred.h = null;
        try check(c.corvid_query_filter(self.h, pred.h));
        return self;
    }

    /// Add a vector-search source (spec §4.6); the query vector is CLONED.
    pub fn vector(self: *Query, field: []const u8, q: []const f32, k: usize, metric: Metric) Error!*Query {
        try check(c.corvid_query_vector(self.h, field.ptr, field.len, if (q.len == 0) &[_]f32{} else q.ptr, q.len, k, @intFromEnum(metric)));
        return self;
    }

    /// Add a BM25 text-search source (spec §4.6); `s` CLONED.
    pub fn text(self: *Query, field: []const u8, s: []const u8, k: usize) Error!*Query {
        try check(c.corvid_query_text(self.h, field.ptr, field.len, s.ptr, s.len, k));
        return self;
    }

    /// Set the Reciprocal Rank Fusion constant (spec §4.6; engine default
    /// 60). Validated at execution (audit C6).
    pub fn fuseRrf(self: *Query, k: f32) Error!*Query {
        try check(c.corvid_query_fuse_rrf(self.h, k));
        return self;
    }

    /// Diversify with Maximal Marginal Relevance (spec §4.6); anchors on
    /// the first vector source. Validated at execution.
    pub fn rerankMmr(self: *Query, lambda: f32) Error!*Query {
        try check(c.corvid_query_rerank_mmr(self.h, lambda));
        return self;
    }

    /// Allow approximate (ANN, over-fetch-then-filter) execution (spec
    /// §4.6) — a knob for filtered single-vector-source queries.
    pub fn approx(self: *Query) Error!*Query {
        try check(c.corvid_query_approx(self.h));
        return self;
    }

    /// Cap the result at `n` rows (spec §4.6).
    pub fn limit(self: *Query, n: usize) Error!*Query {
        try check(c.corvid_query_limit(self.h, n));
        return self;
    }

    /// Skip the first `n` rows (spec §4.6) — after ordering, before limit.
    pub fn offset(self: *Query, n: usize) Error!*Query {
        try check(c.corvid_query_offset(self.h, n));
        return self;
    }

    /// Order by a scalar field instead of rank (spec §4.6; ascending).
    pub fn orderBy(self: *Query, field: []const u8) Error!*Query {
        try check(c.corvid_query_order_by(self.h, field.ptr, field.len, 0));
        return self;
    }

    /// Order by a scalar field, descending (spec §4.6).
    pub fn orderByDesc(self: *Query, field: []const u8) Error!*Query {
        try check(c.corvid_query_order_by(self.h, field.ptr, field.len, 1));
        return self;
    }

    /// Project result documents to these top-level fields (spec §4.6);
    /// an empty list projects maps to the empty map (engine-faithful).
    pub fn select(self: *Query, fields: []const []const u8) Error!*Query {
        const a = std.heap.c_allocator;
        var ptrs = std.ArrayList([*c]const u8).empty;
        var lens = std.ArrayList(usize).empty;
        defer ptrs.deinit(a);
        defer lens.deinit(a);
        try ptrs.ensureTotalCapacity(a, fields.len);
        try lens.ensureTotalCapacity(a, fields.len);
        for (fields) |f| {
            ptrs.appendAssumeCapacity(f.ptr);
            lens.appendAssumeCapacity(f.len);
        }
        try check(c.corvid_query_select(self.h, ptrs.items.ptr, lens.items.ptr, fields.len));
        return self;
    }

    /// Execute — CONSUMES the builder (spec §4.6). Returns a cursor even
    /// for an empty result; failure is the error union, never an empty
    /// cursor. Ranking parameters are validated HERE (audit C6).
    pub fn run(self: *Query) Error!Rows {
        const h = c.corvid_query_run(self.h) orelse {
            self.h = null; // consumed either way (spec §8)
            return mapError();
        };
        self.h = null;
        return .{ .h = h };
    }

    // ---- aggregates: each consumes the builder (spec §4.7) -----------

    /// Count matching documents (O(1) unfiltered; spec §4.7).
    pub fn count(self: *Query) Error!usize {
        defer self.h = null;
        var n: usize = 0;
        try check(c.corvid_query_count(self.h, &n));
        return n;
    }

    /// Distinct values at `field` by canonical group key (spec §4.7).
    pub fn countDistinct(self: *Query, field: []const u8) Error!usize {
        defer self.h = null;
        var n: usize = 0;
        try check(c.corvid_query_count_distinct(self.h, field.ptr, field.len, &n));
        return n;
    }

    /// Sum the numeric values at `field` (0.0 when all skipped; spec
    /// §4.7).
    pub fn sum(self: *Query, field: []const u8) Error!f64 {
        defer self.h = null;
        var v: f64 = 0;
        try check(c.corvid_query_sum(self.h, field.ptr, field.len, &v));
        return v;
    }

    /// Mean of the numeric values at `field` (null when none; spec §4.7).
    pub fn avg(self: *Query, field: []const u8) Error!?f64 {
        defer self.h = null;
        var v: f64 = 0;
        var has: c_int = 0;
        try check(c.corvid_query_avg(self.h, field.ptr, field.len, &v, &has));
        return if (has != 0) v else null;
    }

    /// Minimum comparable value at `field` (null when none; spec §4.7).
    pub fn min(self: *Query, field: []const u8) Error!?Value {
        defer self.h = null;
        var out: ?*c.corvid_value = null;
        try check(c.corvid_query_min(self.h, field.ptr, field.len, &out));
        return if (out) |o| .{ .h = o } else null;
    }

    /// Maximum comparable value at `field` (null when none; spec §4.7).
    pub fn max(self: *Query, field: []const u8) Error!?Value {
        defer self.h = null;
        var out: ?*c.corvid_value = null;
        try check(c.corvid_query_max(self.h, field.ptr, field.len, &out));
        return if (out) |o| .{ .h = o } else null;
    }

    /// Count grouped by the value at `field` (spec §4.7).
    pub fn groupCount(self: *Query, field: []const u8) Error!GroupIter {
        defer self.h = null;
        const h = c.corvid_query_group_count(self.h, field.ptr, field.len) orelse return mapError();
        return .{ .h = h };
    }

    /// Sum `value_field` grouped by `group_field` (spec §4.7).
    pub fn groupSum(self: *Query, group_field: []const u8, value_field: []const u8) Error!GroupIter {
        defer self.h = null;
        const h = c.corvid_query_group_sum(self.h, group_field.ptr, group_field.len, value_field.ptr, value_field.len) orelse return mapError();
        return .{ .h = h };
    }

    /// Mean of `value_field` grouped by `group_field` (spec §4.7).
    pub fn groupAvg(self: *Query, group_field: []const u8, value_field: []const u8) Error!GroupIter {
        defer self.h = null;
        const h = c.corvid_query_group_avg(self.h, group_field.ptr, group_field.len, value_field.ptr, value_field.len) orelse return mapError();
        return .{ .h = h };
    }

    /// Free a builder abandoned without executing (spec §4.6). No-op
    /// after `run`/an aggregate consumed it.
    pub fn deinit(self: *Query) void {
        if (self.h) |h| c.corvid_query_free(h);
        self.h = null;
    }

    /// True once run()/an aggregate consumed the builder.
    pub fn consumed(self: Query) bool {
        return self.h == null;
    }
};

// --------------------------------------------------------------------------
// Collection
// --------------------------------------------------------------------------

/// The `update` callback (spec §4.6/§1.6): receives the current document
/// (null when the key is absent) and returns the replacement (owned — it
/// is consumed), null to delete, or ANY Zig error to abort the
/// read-modify-write (nothing is written; the error propagates out of
/// `Collection.update`).
///
/// Reentrancy (spec §1.6): no corvid calls on the same db from inside.
pub fn UpdateFn(comptime Ctx: type) type {
    return *const fn (ctx: Ctx, current: ?ValueView) anyerror!?Value;
}

/// The `scan` sink (spec §4.9/§1.6): return true to continue, false to
/// stop (stopping is not an error). `key`/`doc` are borrowed for the
/// call's duration only. No reentrant corvid calls (spec §1.6).
pub fn ScanFn(comptime Ctx: type) type {
    return *const fn (ctx: Ctx, key: []const u8, doc: ValueView) bool;
}

/// The thread-local slot carrying an `update` callback's Zig error across
/// the C trampoline (§1.6's abort channel returns a status code only).
threadlocal var update_error: ?anyerror = null;

/// A collection handle (spec §4.2). Holds an engine reference: freeing it
/// (or `Db.deinit` before it) follows the ABI's derived-handle rules.
pub const Collection = struct {
    h: ?*c.corvid_coll = null,

    /// Free the collection handle (spec §4.2). Inert after a prior
    /// `deinit` (the handle is nulled), matching `Db`/`Query`/`Pred` —
    /// double-`deinit` is a safe no-op, not the C ABI's double free.
    pub fn deinit(self: *Collection) void {
        if (self.h) |h| c.corvid_collection_free(h);
        self.h = null;
    }

    /// The collection's name (spec §4.2), borrowed from the handle.
    pub fn name(self: Collection) []const u8 {
        var len_out: usize = 0;
        const p = c.corvid_collection_name(self.h, &len_out) orelse return "";
        return @as([*]const u8, @ptrCast(p))[0..len_out];
    }

    /// Insert or overwrite the document at `key` (spec §4.8). `doc` is
    /// borrowed-read — the engine clones it; the caller keeps ownership.
    pub fn insert(self: Collection, key: []const u8, doc: Value) Error!void {
        try check(c.corvid_insert(self.h, key.ptr, key.len, doc.h));
    }

    /// Single-transaction bulk load (spec §4.8); each value borrowed-read
    /// and CLONED. The whole batch rolls back on a violation.
    pub fn putMany(self: Collection, items: []const Kv) Error!void {
        const a = std.heap.c_allocator;
        var kvs = std.ArrayList(c.corvid_kv).empty;
        defer kvs.deinit(a);
        try kvs.ensureTotalCapacity(a, items.len);
        for (items) |it| kvs.appendAssumeCapacity(.{ .key = it.key.ptr, .key_len = it.key.len, .val = it.val.h });
        try check(c.corvid_put_many(self.h, kvs.items.ptr, items.len));
    }

    /// Insert under a fresh zero-padded 20-digit key (spec §4.8) — the
    /// key bytes are returned as an ALLOCATED slice; free it with
    /// `allocator.free` (the binding copies out of `corvid_free`'s
    /// domain). A failed insert does not burn an id.
    pub fn insertAuto(self: Collection, allocator: std.mem.Allocator, doc: Value) AllocError![]u8 {
        var key_len: usize = 0;
        const key = c.corvid_insert_auto(self.h, doc.h, &key_len) orelse return mapError();
        defer c.corvid_free(key);
        const out = try allocator.alloc(u8, key_len);
        @memcpy(out, key[0..key_len]);
        return out;
    }

    /// Read-modify-write via callback (spec §4.8/§1.6). The callback may
    /// return any Zig error to abort — nothing is written and the error
    /// propagates verbatim to the caller (the callback contract rides the
    /// ABI's §1.6 abort channel, which reports "aborted"; the wrapper
    /// re-attaches the callback's own richer error). Engine-side failures
    /// surface as the `Error` set. Not linearizable against concurrent
    /// writers (as the engine's `update`).
    pub fn update(self: Collection, key: []const u8, ctx: anytype, comptime f: UpdateFn(@TypeOf(ctx))) anyerror!void {
        const Trampoline = struct {
            fn call(cc: ?*anyopaque, current: ?*const c.corvid_value, out: [*c]?*c.corvid_value) callconv(.c) c.corvid_status {
                out[0] = null;
                const args: *@TypeOf(ctx) = @ptrCast(@alignCast(cc.?));
                const cur: ?ValueView = if (current) |cv| .{ .h = cv } else null;
                if (f(args.*, cur)) |res_opt| {
                    if (res_opt) |res| {
                        out[0] = res.h; // OWNED handle, consumed by the call
                    }
                    return c.CORVID_OK; // out left null = delete
                } else |err| {
                    update_error = err;
                    return c.CORVID_ERR; // §1.6 abort: out must be null
                }
            }
        };
        update_error = null;
        var ctx_mut = ctx;
        const st = c.corvid_update(self.h, key.ptr, key.len, Trampoline.call, @ptrCast(&ctx_mut));
        if (st != c.CORVID_OK) {
            // Prefer the callback's own error when the abort was ours.
            if (update_error) |err| {
                update_error = null;
                return err;
            }
            return mapError();
        }
    }

    /// Merge `patch`'s top-level fields into the map at `key` (spec
    /// §4.8); a non-map on either side replaces with `patch`.
    pub fn patch(self: Collection, key: []const u8, patch_value: Value) Error!void {
        try check(c.corvid_patch(self.h, key.ptr, key.len, patch_value.h));
    }

    /// Atomic conditional write (spec §4.8). Nullability is semantic:
    /// `expected == null` means "must be absent"; `replacement == null`
    /// means "delete if it matches". Returns whether it applied (a failed
    /// compare is NOT an error). Both values are borrowed-read; the
    /// replacement is cloned by the engine.
    pub fn compareAndSet(self: Collection, key: []const u8, expected: ?Value, replacement: ?Value) Error!bool {
        var applied: i32 = 0;
        try check(c.corvid_compare_and_set(self.h, key.ptr, key.len, if (expected) |e| e.h else null, if (replacement) |r| r.h else null, &applied));
        return applied != 0;
    }

    /// Delete the document at `key` (spec §4.8); cascades the key's graph
    /// edges in the same transaction. Returns whether a document was
    /// removed.
    pub fn delete(self: Collection, key: []const u8) Error!bool {
        var existed: i32 = 0;
        try check(c.corvid_delete(self.h, key.ptr, key.len, &existed));
        return existed != 0;
    }

    /// Delete every document matching `pred` — CONSUMES `pred` (spec
    /// §4.8) — returning how many were removed.
    pub fn deleteWhere(self: Collection, pred: *Pred) Error!usize {
        defer pred.h = null;
        var removed: usize = 0;
        try check(c.corvid_delete_where(self.h, pred.h, &removed));
        return removed;
    }

    /// Delete each of `keys` (spec §4.8), cascading edges as `delete`;
    /// returns how many existed.
    pub fn deleteBatch(self: Collection, keys: []const []const u8) Error!usize {
        const a = std.heap.c_allocator;
        var ptrs = std.ArrayList([*c]const u8).empty;
        var lens = std.ArrayList(usize).empty;
        defer ptrs.deinit(a);
        defer lens.deinit(a);
        try ptrs.ensureTotalCapacity(a, keys.len);
        try lens.ensureTotalCapacity(a, keys.len);
        for (keys) |k| {
            ptrs.appendAssumeCapacity(k.ptr);
            lens.appendAssumeCapacity(k.len);
        }
        var removed: usize = 0;
        try check(c.corvid_delete_batch(self.h, ptrs.items.ptr, lens.items.ptr, keys.len, &removed));
        return removed;
    }

    /// Insert with expiry `expires_at` (caller's epoch; spec §4.8).
    pub fn insertWithTtl(self: Collection, key: []const u8, doc: Value, expires_at: i64) Error!void {
        try check(c.corvid_insert_with_ttl(self.h, key.ptr, key.len, doc.h, expires_at));
    }

    /// Set (or replace) `key`'s expiry without rewriting the document
    /// (spec §4.8).
    pub fn setTtl(self: Collection, key: []const u8, expires_at: i64) Error!void {
        try check(c.corvid_set_ttl(self.h, key.ptr, key.len, expires_at));
    }

    /// `key`'s expiry, if one is set (spec §4.8); unset is null, not an
    /// error. A plain write clears a previously set expiry.
    pub fn getTtl(self: Collection, key: []const u8) Error!?i64 {
        var exp: i64 = 0;
        var has: i32 = 0;
        try check(c.corvid_get_ttl(self.h, key.ptr, key.len, &exp, &has));
        return if (has != 0) exp else null;
    }

    /// Delete every record whose expiry is `<= now` (INCLUSIVE; spec
    /// §4.8); returns the purged count.
    pub fn purgeExpired(self: Collection, now: i64) Error!usize {
        var purged: usize = 0;
        try check(c.corvid_purge_expired(self.h, now, &purged));
        return purged;
    }

    /// Fetch the document at `key` (spec §4.9): an OWNED value, or null
    /// when absent (absence is a success).
    pub fn get(self: Collection, key: []const u8) Error!?Value {
        var out: ?*c.corvid_value = null;
        try check(c.corvid_get(self.h, key.ptr, key.len, &out));
        return if (out) |o| .{ .h = o } else null;
    }

    /// Stream every `(key, document)` to `f` in key order (spec §4.9),
    /// constant memory. Return false from the sink to stop early —
    /// stopping is not an error.
    pub fn scan(self: Collection, ctx: anytype, comptime f: ScanFn(@TypeOf(ctx))) Error!void {
        const Closure = struct {
            fn tramp(cc: ?*anyopaque, key: [*c]const u8, key_len: usize, doc: ?*const c.corvid_value) callconv(.c) c_int {
                const args: *@TypeOf(ctx) = @ptrCast(@alignCast(cc.?));
                return if (f(args.*, @as([*]const u8, @ptrCast(key))[0..key_len], .{ .h = doc.? })) 1 else 0;
            }
        };
        var ctx_mut = ctx;
        try check(c.corvid_scan(self.h, Closure.tramp, @ptrCast(&ctx_mut)));
    }

    /// Keyset pagination (spec §4.9, the v0.3.2 erratum wording): up to
    /// `limit` documents in key order strictly after `after`. `null` is
    /// the ONLY start form — it begins at the very first key, the legal
    /// empty key `""` included; a non-null `after` of ANY length —
    /// including 0 — is the exclusive continuation cursor (strictly
    /// after those bytes). Returns the page's rows plus the resume cursor
    /// (null at the end). The resume cursor, when non-null, is
    /// ALLOCATED — free it with `allocator.free`. NON-NULL means not-end
    /// even when the slice is EMPTY: a page boundary landing on the
    /// empty key yields a zero-length cursor that, fed back, continues
    /// the walk past it (never restarts; a fresh start must pass null).
    pub fn page(self: Collection, allocator: std.mem.Allocator, after: ?[]const u8, limit: usize) AllocError!Page {
        var rows_out: ?*c.corvid_rows = null;
        var next_after: [*c]u8 = null;
        var next_len: usize = 0;
        try check(c.corvid_page(self.h, if (after) |a| a.ptr else null, if (after) |a| a.len else 0, limit, &rows_out, &next_after, &next_len));
        var next_cursor: ?[]u8 = null;
        if (next_after != null) {
            // corvid.cpp:1091's shape: non-NULL is not-end — copy the
            // cursor out (possibly zero bytes) and free the ABI buffer
            // on this path unconditionally.
            next_cursor = try allocator.alloc(u8, next_len);
            @memcpy(next_cursor.?, next_after[0..next_len]);
            c.corvid_free(next_after);
        }
        return .{ .rows = .{ .h = rows_out }, .next_after = next_cursor, .allocator = allocator };
    }

    /// The document count (spec §4.9) — O(1) maintained counter.
    pub fn len(self: Collection) Error!usize {
        var n: usize = 0;
        try check(c.corvid_len(self.h, &n));
        return n;
    }

    // ---- graph (spec §4.11) -------------------------------------------

    /// Add a directed edge `from --relation--> to` (spec §4.11),
    /// idempotent; overwrites a prior weighted edge's weight with 1.0.
    pub fn link(self: Collection, from: []const u8, relation: []const u8, to: []const u8) Error!void {
        try check(c.corvid_link(self.h, from.ptr, from.len, relation.ptr, relation.len, to.ptr, to.len));
    }

    /// Add a directed edge carrying `weight` (spec §4.11); readable back
    /// through `neighborsWeighted`.
    pub fn linkWeighted(self: Collection, from: []const u8, relation: []const u8, to: []const u8, weight: f64) Error!void {
        try check(c.corvid_link_weighted(self.h, from.ptr, from.len, relation.ptr, relation.len, to.ptr, to.len, weight));
    }

    /// Remove the edge (and its reverse) atomically (spec §4.11);
    /// returns whether the FORWARD edge existed.
    pub fn unlink(self: Collection, from: []const u8, relation: []const u8, to: []const u8) Error!bool {
        var removed: i32 = 0;
        try check(c.corvid_unlink(self.h, from.ptr, from.len, relation.ptr, relation.len, to.ptr, to.len, &removed));
        return removed != 0;
    }

    /// Targets of every `from --relation--> ?` edge, key order (spec
    /// §4.11).
    pub fn neighbors(self: Collection, from: []const u8, relation: []const u8) Error!Strs {
        const h = c.corvid_neighbors(self.h, from.ptr, from.len, relation.ptr, relation.len) orelse return mapError();
        return .{ .h = h };
    }

    /// Sources of every `? --relation--> to` edge, key order (spec §4.11).
    pub fn inNeighbors(self: Collection, to: []const u8, relation: []const u8) Error!Strs {
        const h = c.corvid_in_neighbors(self.h, to.ptr, to.len, relation.ptr, relation.len) orelse return mapError();
        return .{ .h = h };
    }

    /// `(target, weight)` for every `from --relation--> ?` edge, key
    /// order (spec §4.11); the weight rides `GeoHit.distance_km` and
    /// `doc` is null on these cursors.
    pub fn neighborsWeighted(self: Collection, from: []const u8, relation: []const u8) Error!GeoHits {
        const h = c.corvid_neighbors_weighted(self.h, from.ptr, from.len, relation.ptr, relation.len) orelse return mapError();
        return .{ .h = h };
    }

    /// BFS over `relation` up to `hops` from `start`, excluding `start`
    /// (spec §4.11); cycles terminate.
    pub fn traverse(self: Collection, start: []const u8, relation: []const u8, hops: usize) Error!Strs {
        const h = c.corvid_traverse(self.h, start.ptr, start.len, relation.ptr, relation.len, hops) orelse return mapError();
        return .{ .h = h };
    }

    // ---- geo (spec §4.12) ----------------------------------------------

    /// Documents whose `field` point lies within `radius_km` (INCLUSIVE)
    /// of `(lat, lon)`, nearest first, ties by key (spec §4.12).
    pub fn geoWithinRadius(self: Collection, field: []const u8, lat: f64, lon: f64, radius_km: f64) Error!GeoHits {
        const h = c.corvid_geo_within_radius(self.h, field.ptr, field.len, lat, lon, radius_km) orelse return mapError();
        return .{ .h = h };
    }

    /// Documents inside `[min_lat, max_lat] × [min_lon, max_lon]`, key
    /// order (spec §4.12); `min_lon > max_lon` wraps the antimeridian;
    /// `distance_km` is the 0.0 sentinel.
    pub fn geoWithinBbox(self: Collection, field: []const u8, min_lat: f64, min_lon: f64, max_lat: f64, max_lon: f64) Error!GeoHits {
        const h = c.corvid_geo_within_bbox(self.h, field.ptr, field.len, min_lat, min_lon, max_lat, max_lon) orelse return mapError();
        return .{ .h = h };
    }

    /// The true `k` nearest documents by `field` point, nearest first
    /// (spec §4.12).
    pub fn geoNearest(self: Collection, field: []const u8, lat: f64, lon: f64, k: usize) Error!GeoHits {
        const h = c.corvid_geo_nearest(self.h, field.ptr, field.len, lat, lon, k) orelse return mapError();
        return .{ .h = h };
    }

    // ---- indexes + schema (spec §4.10) ---------------------------------

    /// Scalar secondary index on `field` (spec §4.10); persists on disk.
    pub fn createScalarIndex(self: Collection, field: []const u8) Error!void {
        try check(c.corvid_create_scalar_index(self.h, field.ptr, field.len));
    }

    /// Compound index over an ordered field list (spec §4.10).
    pub fn createCompoundIndex(self: Collection, fields: []const []const u8) Error!void {
        const a = std.heap.c_allocator;
        var ptrs = std.ArrayList([*c]const u8).empty;
        var lens = std.ArrayList(usize).empty;
        defer ptrs.deinit(a);
        defer lens.deinit(a);
        try ptrs.ensureTotalCapacity(a, fields.len);
        try lens.ensureTotalCapacity(a, fields.len);
        for (fields) |f| {
            ptrs.appendAssumeCapacity(f.ptr);
            lens.appendAssumeCapacity(f.len);
        }
        try check(c.corvid_create_compound_index(self.h, ptrs.items.ptr, lens.items.ptr, fields.len));
    }

    /// In-memory inverted text index on `field` (spec §4.10).
    pub fn createTextIndex(self: Collection, field: []const u8) Error!void {
        try check(c.corvid_create_text_index(self.h, field.ptr, field.len));
    }

    /// On-disk inverted text index on `field` (spec §4.10); existing
    /// documents backfill synchronously.
    pub fn createTextIndexOndisk(self: Collection, field: []const u8) Error!void {
        try check(c.corvid_create_text_index_ondisk(self.h, field.ptr, field.len));
    }

    /// Spatial index on `field` (spec §4.10) — serves radius/bbox windows.
    pub fn createGeoIndex(self: Collection, field: []const u8) Error!void {
        try check(c.corvid_create_geo_index(self.h, field.ptr, field.len));
    }

    /// Full-precision in-memory HNSW index on `field` (spec §4.10).
    pub fn createVectorIndex(self: Collection, field: []const u8, metric: Metric) Error!void {
        try check(c.corvid_create_vector_index(self.h, field.ptr, field.len, @intFromEnum(metric)));
    }

    /// In-memory HNSW storing quantized vectors (spec §4.10) — binary
    /// ≈32x / scalar ≈4x smaller at some recall cost.
    pub fn createVectorIndexQuantized(self: Collection, field: []const u8, metric: Metric, quant: Quant) Error!void {
        try check(c.corvid_create_vector_index_quantized(self.h, field.ptr, field.len, @intFromEnum(metric), @intFromEnum(quant)));
    }

    /// On-disk HNSW on `field` (spec §4.10) — the graph lives in the
    /// database file; existing documents backfill synchronously.
    pub fn createVectorIndexOndisk(self: Collection, field: []const u8, metric: Metric) Error!void {
        try check(c.corvid_create_vector_index_ondisk(self.h, field.ptr, field.len, @intFromEnum(metric)));
    }

    /// On-disk HNSW storing quantized vectors (spec §4.10).
    pub fn createVectorIndexOndiskQuantized(self: Collection, field: []const u8, metric: Metric, quant: Quant) Error!void {
        try check(c.corvid_create_vector_index_ondisk_quantized(self.h, field.ptr, field.len, @intFromEnum(metric), @intFromEnum(quant)));
    }

    /// In-memory HNSW storing product-quantized vectors (spec §4.10):
    /// `m` subspaces × `k` centroids trained from existing vectors;
    /// `dim % m == 0` required; every training-domain failure is the
    /// engine's `error.EmptyIndexTraining`.
    pub fn createVectorIndexPq(self: Collection, field: []const u8, metric: Metric, m: usize, k: usize) Error!void {
        try check(c.corvid_create_vector_index_pq(self.h, field.ptr, field.len, @intFromEnum(metric), m, k));
    }

    /// On-disk HNSW storing product-quantized vectors (spec §4.10).
    pub fn createVectorIndexOndiskPq(self: Collection, field: []const u8, metric: Metric, m: usize, k: usize) Error!void {
        try check(c.corvid_create_vector_index_ondisk_pq(self.h, field.ptr, field.len, @intFromEnum(metric), m, k));
    }

    /// Declare (or replace) the collection's schema (spec §4.10) —
    /// enforced on subsequent writes only; an empty list declares an
    /// empty schema, replacing any previous one.
    pub fn setSchema(self: Collection, fields: []const FieldDef) Error!void {
        const a = std.heap.c_allocator;
        var defs = std.ArrayList(c.corvid_field_def).empty;
        defer defs.deinit(a);
        try defs.ensureTotalCapacity(a, fields.len);
        for (fields) |f| defs.appendAssumeCapacity(.{
            .name = f.name.ptr,
            .name_len = f.name.len,
            .type = @intFromEnum(f.type),
            .required = @intFromBool(f.required),
            .unique = @intFromBool(f.unique),
        });
        try check(c.corvid_set_schema(self.h, defs.items.ptr, fields.len));
    }

    /// The declared schema (spec §4.10); null when none is declared.
    pub fn schema(self: Collection) Error!?SchemaIter {
        var out: ?*c.corvid_schemaiter = null;
        try check(c.corvid_schema(self.h, &out));
        return if (out) |o| .{ .h = o } else null;
    }

    // ---- query + phrase (spec §4.6) -------------------------------------

    /// Begin a query over this collection (spec §4.6) — the fluent
    /// builder; `run()`/aggregates consume it.
    pub fn query(self: Collection) Error!Query {
        const h = c.corvid_query_new(self.h) orelse return mapError();
        return Query.from(h);
    }

    /// DIRECT positional text search (spec §4.6's erratum; engine
    /// `Collection::phrase_search`): documents whose `field` TEXT contains
    /// `phrase` as a consecutive, in-order run of analyzed tokens, most
    /// relevant first, ties by key, up to `k` rows (k == 0 yields an
    /// EMPTY cursor — inert, not an error). The rows' `score` carries the
    /// hit's BM25 phrase sum (its own scale, NOT the builder's fused RRF).
    pub fn phraseSearch(self: Collection, field: []const u8, phrase: []const u8, k: usize) Error!Rows {
        const h = c.corvid_phrase_search(self.h, field.ptr, field.len, phrase.ptr, phrase.len, k) orelse return mapError();
        return .{ .h = h };
    }
};

/// One `(key, value)` pair for `Collection.putMany` (spec §1.2): both
/// borrowed for the call; the value is CLONED.
pub const Kv = struct {
    key: []const u8,
    val: Value,
};

/// The result of `Collection.page` (spec §4.9): the page's rows plus the
/// resume cursor (null at the end of the collection).
pub const Page = struct {
    rows: Rows,
    next_after: ?[]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Page) void {
        self.rows.deinit();
        if (self.next_after) |n| self.allocator.free(n);
        self.next_after = null;
    }
};

// --------------------------------------------------------------------------
// Tests — the wrapper's own unit checks (the golden suite in test/ proves
// the artifacts; these pin the mapping's ergonomic promises)
// --------------------------------------------------------------------------

const testing = std.testing;

test "ffi version is 1" {
    try testing.expectEqual(@as(u32, 1), ffiVersion());
}

test "value build/read round trip" {
    var doc = Value.map();
    defer doc.deinit();
    var title = try Value.text("ada");
    try doc.put("name", &title);
    var v = Value.vector(&.{ 1.0, 0.5, -0.25 });
    try doc.put("v", &v);
    try testing.expectEqual(ValueKind.map, doc.kind());
    try testing.expectEqual(@as(usize, 2), doc.len());
    const name = doc.mapGet("name").?;
    try testing.expectEqualStrings("ada", name.textRef().?);
    const vec = doc.mapGet("v").?.vectorRef().?;
    try testing.expectEqualSlices(f32, &.{ 1.0, 0.5, -0.25 }, vec);
    try testing.expect(doc.mapGet("missing") == null);
}

test "moved values are inert, not double-freed" {
    var inner = Value.int(7);
    var arr = Value.array();
    defer arr.deinit();
    try arr.push(&inner); // moves inner
    try testing.expect(inner.consumed());
    inner.deinit(); // must be a safe no-op (the C ABI's double-free UB)
    try testing.expectEqual(@as(usize, 1), arr.len());
    try testing.expectEqual(@as(i64, 7), arr.arrayGet(0).?.asInt().?);
}

test "map keys ascend in byte order" {
    var m = Value.map();
    defer m.deinit();
    var z = Value.int(1);
    try m.put("z", &z);
    var cjk = Value.int(2);
    try m.put("\xe9\x94\xae", &cjk); // 键
    var a = Value.int(3);
    try m.put("A1~B2", &a);
    var ks = try m.mapKeys();
    defer ks.deinit();
    try testing.expectEqualStrings("A1~B2", ks.next().?);
    try testing.expectEqualStrings("z", ks.next().?);
    try testing.expectEqualStrings("\xe9\x94\xae", ks.next().?);
    try testing.expect(ks.next() == null);
}

test "error mapping: invalid text (lone surrogate byte)" {
    // 0xED starts a 3-byte UTF-8 sequence; truncation makes it invalid.
    try testing.expectError(error.InvalidArgument, Value.text(&[_]u8{0xED, 0xA0}));
    try testing.expectEqual(ErrCode.argument, lastErrorCode());
    try testing.expect(lastErrorMessage().len > 0);
}

test "open, insert, get, delete in memory" {
    var db = try Db.openMemory();
    defer db.deinit();
    var docs = try db.collection("docs");
    defer docs.deinit();
    var doc = Value.map();
    defer doc.deinit();
    var n = Value.int(41);
    try doc.put("n", &n);
    try docs.insert("k1", doc);
    try testing.expectEqual(@as(usize, 1), try docs.len());
    const got = (try docs.get("k1")).?;
    defer {
        var g = got;
        g.deinit();
    }
    try testing.expectEqual(@as(i64, 41), got.mapGet("n").?.asInt().?);
    try testing.expect(try docs.get("missing") == null);
    try testing.expect(try docs.delete("k1"));
    try testing.expect(!try docs.delete("k1"));
}

test "db and collection deinit are inert, not double-free" {
    var db = try Db.openMemory();
    var docs = try db.collection("docs");
    docs.deinit();
    docs.deinit(); // must be a safe no-op (the C ABI's double-free UB)
    db.deinit();
    db.deinit(); // ditto for the db handle
}

test "pred move + query fluent chain" {
    var db = try Db.openMemory();
    defer db.deinit();
    var docs = try db.collection("docs");
    defer docs.deinit();
    var a = Value.map();
    defer a.deinit();
    var kind = try Value.text("doc");
    try a.put("kind", &kind);
    var score = Value.int(5);
    try a.put("score", &score);
    try docs.insert("a", a);
    var b = Value.map();
    defer b.deinit();
    var kind2 = try Value.text("meta");
    try b.put("kind", &kind2);
    try docs.insert("b", b);

    var q = try docs.query();
    var kind_doc = try Value.text("doc");
    defer kind_doc.deinit(); // compare CLONES it; ours is still ours
    var only_docs = try Pred.compare("kind", .eq, kind_doc);
    defer only_docs.deinit(); // safe no-op after the move below
    _ = try q.filter(&only_docs); // moves the pred
    try testing.expect(only_docs.consumed());
    try testing.expectEqual(@as(usize, 1), try q.count());
    try testing.expect(q.consumed());

    var q2 = try docs.query();
    defer q2.deinit(); // no-op after count() below
    var kind_doc2 = try Value.text("doc");
    defer kind_doc2.deinit(); // compare CLONES it; ours is still ours
    var p2 = try Pred.compare("kind", .eq, kind_doc2);
    defer p2.deinit();
    const n = try (try q2.filter(&p2)).count();
    try testing.expectEqual(@as(usize, 1), n);
}

test "scan with closure context stops early" {
    var db = try Db.openMemory();
    defer db.deinit();
    var docs = try db.collection("docs");
    defer docs.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var d = Value.map();
        defer d.deinit();
        var n = Value.int(@intCast(i));
        try d.put("n", &n);
        var keybuf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
        try docs.insert(key, d);
    }
    var seen: usize = 0;
    try docs.scan(&seen, struct {
        fn sink(ctx: *usize, key: []const u8, doc: ValueView) bool {
            _ = key;
            _ = doc;
            ctx.* += 1;
            return ctx.* < 3; // stop after the third
        }
    }.sink);
    try testing.expectEqual(@as(usize, 3), seen);
}

test "update callback can abort with a Zig error" {
    var db = try Db.openMemory();
    defer db.deinit();
    var docs = try db.collection("docs");
    defer docs.deinit();
    var d = Value.map();
    defer d.deinit();
    var n = Value.int(1);
    try d.put("n", &n);
    try docs.insert("k", d);

    try testing.expectError(error.OutOfMemory, docs.update("k", @as(void, {}), struct {
        fn bump(_: void, current: ?ValueView) anyerror!?Value {
            _ = current;
            return error.OutOfMemory; // aborts the RMW
        }
    }.bump));
    // The store is untouched by the abort.
    const got = (try docs.get("k")).?;
    defer {
        var g = got;
        g.deinit();
    }
    try testing.expectEqual(@as(i64, 1), got.mapGet("n").?.asInt().?);

    try docs.update("k", @as(i64, 10), struct {
        fn bump(delta: i64, current: ?ValueView) anyerror!?Value {
            const cur = current orelse return error.Unexpected;
            const old = cur.mapGet("n").?.asInt().?;
            var m = Value.map();
            var v = Value.int(old + delta);
            try m.put("n", &v);
            return m;
        }
    }.bump);
    const got2 = (try docs.get("k")).?;
    defer {
        var g = got2;
        g.deinit();
    }
    try testing.expectEqual(@as(i64, 11), got2.mapGet("n").?.asInt().?);
}

test "phrase search: order, stop-word collapse, k==0 inert" {
    var db = try Db.openMemory();
    defer db.deinit();
    var notes = try db.collection("notes");
    defer notes.deinit();
    const bodies = [_][]const u8{
        "corvid is an embedded the database engine",
        "corvid is a graph database",
        "the engine stores documents",
    };
    for (bodies, 0..) |body, i| {
        var d = Value.map();
        defer d.deinit();
        var b = try Value.text(body);
        try d.put("body", &b);
        var keybuf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "n{d}", .{i});
        try notes.insert(key, d);
    }
    // "embedded the database": the stop word collapses out of adjacency,
    // matching "embedded database" in n0.
    var rows = try notes.phraseSearch("body", "embedded the database", 10);
    defer rows.deinit();
    const row = rows.next().?;
    try testing.expectEqualStrings("n0", row.key);
    // Word-order matters: reversed matches nothing.
    var none = try notes.phraseSearch("body", "database embedded", 10);
    defer none.deinit();
    try testing.expect(none.next() == null);
    // k == 0 is an EMPTY cursor, not an error.
    var k0 = try notes.phraseSearch("body", "database", 0);
    defer k0.deinit();
    try testing.expect(k0.next() == null);
}

test "page: zero-length resume cursor at the empty key is not-end" {
    // The empty key is legal ("key as everywhere — non-NULL, any
    // length"), so a page boundary can land on it: corvid_page then
    // hands back a NON-NULL zero-length cursor (§4.9: non-NULL means
    // not-end). The wrapper must surface that as an allocated EMPTY
    // slice (not null) and free the ABI buffer either way, and the
    // walk must continue: at this pin (v0.3.2, engine d4124ae — the
    // §4.9 erratum) the zero-length cursor IS the exclusive
    // continuation of b"", so the follow-up page resumes strictly
    // after the empty key instead of re-walking from the top.
    var db = try Db.openMemory();
    defer db.deinit();
    var docs = try db.collection("docs");
    defer docs.deinit();
    var first = Value.int(0);
    defer first.deinit();
    try docs.insert("", first); // the legal empty key, sorts first
    var i: usize = 1;
    while (i <= 3) : (i += 1) {
        var d = Value.int(@intCast(i));
        defer d.deinit();
        var keybuf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
        try docs.insert(key, d);
    }
    try testing.expectEqual(@as(usize, 4), try docs.len());

    // Page 1: the boundary lands exactly on the empty key.
    var p1 = try docs.page(testing.allocator, null, 1);
    defer p1.deinit();
    try testing.expect(p1.next_after != null); // not-end, not a null cursor
    try testing.expectEqual(@as(usize, 0), p1.next_after.?.len);

    // The walk continues EXCLUSIVELY past the boundary — k1..k3 only,
    // no restart (the empty key must NOT reappear) — and terminates on
    // the short page.
    var p2 = try docs.page(testing.allocator, p1.next_after, 5);
    defer p2.deinit();
    var seen: usize = 0;
    var first_key: []const u8 = "";
    var fkbuf: [16]u8 = undefined;
    while (p2.rows.next()) |row| {
        if (seen == 0) {
            @memcpy(fkbuf[0..row.key.len], row.key);
            first_key = fkbuf[0..row.key.len];
        }
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expectEqualStrings("k1", first_key); // resumed past b""
    try testing.expect(p2.next_after == null); // short page = the end
}

test "page resume cursor walks the whole collection" {
    var db = try Db.openMemory();
    defer db.deinit();
    var docs = try db.collection("docs");
    defer docs.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var d = Value.int(@intCast(i));
        defer d.deinit();
        var keybuf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "k{d}", .{i});
        try docs.insert(key, d);
    }
    var total: usize = 0;
    var after: ?[]u8 = null;
    defer if (after) |a| testing.allocator.free(a);
    var guard: usize = 0;
    while (guard < 10) : (guard += 1) {
        var p = try docs.page(testing.allocator, after, 2);
        defer p.deinit();
        while (p.rows.next() != null) total += 1;
        if (p.next_after) |na| {
            if (after) |old| testing.allocator.free(old);
            after = testing.allocator.dupe(u8, na) catch null;
        } else break;
    }
    try testing.expectEqual(@as(usize, 5), total);
}
