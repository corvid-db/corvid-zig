# corvid-zig

Idiomatic Zig bindings for [corvid](https://github.com/corvid-db/corvid) —
an embedded database with a typed C ABI — over the **published release
artifacts**: `fetch.sh` / `fetch.ps1` download the pinned release,
sha256-verify it against the release's `checksums.txt`, and `zig build`
consumes the fetched `corvid.h` + platform cdylib offline. No Rust
toolchain, no vendored binaries.

**Documentation:** the [corvid docs site](https://corvid-db.github.io/docs/)
is canonical — this binding has its own
[corvid-zig page](https://corvid-db.github.io/docs/bindings/corvid-zig/), and
the [C ABI section](https://corvid-db.github.io/docs/ffi/) documents every
symbol the binding wraps (handles, ownership, errors, threading).

The binding has two layers:

- **`src/corvid.zig`** — the idiomatic API: `Db` / `Collection` / `Query` /
  `Pred` / `Value` wrapper structs with `deinit()`, `CORVID_ERR` mapped to
  a Zig error set (`corvid.Error`), consumed-by-call arguments moved and
  rendered inert, borrowed views typed `ValueView` (freeing a borrow is a
  *compile error* here — UB in C), the C fn-pointer callbacks (`update`,
  `scan`) wrapped as Zig closures whose errors ride the ABI's abort
  channel, and `[]const u8` / `[]const f32` slices everywhere.
- **`corvid.c`** — the raw `@cImport` of `corvid.h`, exposed because the
  golden harness drives the ABI exactly the way the engine's own C
  harness does.

## What's inside

| Path | What it is |
| --- | --- |
| `fetch.sh` / `fetch.ps1` | Download the pinned release archive for the host platform, verify it against the release's `checksums.txt` (sha256), byte-check the vendored fixtures, extract into gitignored `deps/current/` |
| `build.zig` | Offline-first build consuming `deps/current/`; the `corvid` module, the golden-suite port, and the examples tour (`zig build test` / `zig build examples` / `zig build run-<name>`) |
| `src/corvid.zig` | The idiomatic wrapper + its unit tests (error mapping, move semantics, borrow typing, phrase search semantics, page resume) |
| `test/golden.zig` | The golden-suite port — the engine's own harness (`c/smoke.c`) ported statement-for-statement; replays the 267-line fixture suite against the downloaded libcorvid |
| `golden/*.txt` | The engine's golden fixtures, vendored from the pinned release (fetch byte-compares them against the release's copies) |
| `examples/{quickstart,hybrid,vector_index,text_search,graph,geo}.zig` | The examples tour — one runnable program per concept; `text_search` demonstrates the v0.3.0 positional `phraseSearch` API (order sensitivity, stop-word collapse, CJK bigrams, inert k=0) |
| `docs/PLAN.md` | The binding's plan: the architecture ruling, binding rules, toolchain policy |
| `docs/SURFACE.tsv` | Every construct of the engine's public surface resolved: the Zig API exposing it + the golden line that proves it, or `N/A` + reason (FFI.md §9) |

## Quick start

Requirements: Zig **0.16.0** (the current stable line; see
[docs/PLAN.md](docs/PLAN.md) for the toolchain policy), and `curl` +
`shasum`/`sha256sum` (macOS/Linux) or PowerShell 5+ (Windows).

```sh
./fetch.sh                     # download + verify corvid v0.4.0 into deps/current/
zig build test                 # wrapper unit tests + the golden suite (267/267)
zig build run-quickstart       # open → insert → kNN → print
zig build examples             # build the whole six-program tour
```

Windows (PowerShell): `./fetch.ps1`, then the same `zig build` steps. For
a binary you run by hand from `zig-out/bin`, put `deps/current` on `PATH`
so the loader finds `corvid.dll` (the build's own run steps do this for
you).

A taste of the API (`examples/quickstart.zig`):

```zig
const corvid = @import("corvid");

var db = try corvid.Db.openMemory();
defer db.deinit();
var docs = try db.collection("docs");
defer docs.deinit();

var doc = corvid.Value.map();
defer doc.deinit();
var title = try corvid.Value.text("ada");
try doc.put("title", &title);          // moves title into the map
var v = corvid.Value.vector(&.{ 1.0, 0.0 });
try doc.put("v", &v);
try docs.insert("p1", doc);            // insert CLONES the value

var q = try docs.query();
defer q.deinit();                      // no-op after run()
var rows = try q.vector("v", &.{ 1.0, 0.0 }, 3, .cosine).run();
defer rows.deinit();
while (rows.next()) |row| {            // row.key / row.score / row.doc
    const t = row.doc.mapGet("title").?.textRef().?;
    // borrowed until the next next()/deinit — clone it to keep it
}
```

The positional phrase search (new in the engine's v0.3.0):

```zig
var rows = try notes.phraseSearch("body", "embedded the database", 10);
defer rows.deinit();
// stop words collapse out of adjacency: matches "embedded database".
// Row order is BM25 relevance; k == 0 is an empty cursor, not an error.
```

## The golden suite (the correctness floor)

`zig build test` replays the engine's entire golden fixture suite — 267
executable lines across 8 files, including the v0.3.0 additions
(`VMAP_KEYS`/`GET_KEYS` map-key iteration, `PHRASE`/`PHRASE_K0` direct
positional search) — against the **downloaded** libcorvid, with the same
discipline as the engine harness: every counted line must dispatch, first
failure names file:line + OP + expected-vs-got, every handle freed on its
creation path (the CI sanitizer leg builds the harness with ASan and
expects zero reports). Output protocol, one line per fixture:

```
SMOKE golden/queries.txt lines=46 executed=46
```

If the published artifacts ever disagree with the vendored fixtures or
the header, this fails where the engine's own suite stayed green — that
divergence is a finding for the engine repo, never patched around here.

## Surface manifest (docs/SURFACE.tsv)

Every construct of the engine's public surface (the radar-enforced list
the engine publishes as `scripts/bindings/surface.tsv` at each release
tag — 327 rows at this pin) is resolved in `docs/SURFACE.tsv`: the Zig
API exposing it plus the golden fixture line that proves it, or `N/A` +
reason where the v1 ABI deliberately does not expose it (FFI.md §9).
`scripts/surface-gate.sh` fails CI when a line is unresolved, a cell is
empty, or the N/A count drifts from the committed baseline — so an
engine pin bump that changes the surface lands in this gate, not in a
user's bug report.

## Versioning

The engine pin lives in one variable in the fetch scripts
(`CORVID_VERSION=v0.4.0`). Artifacts are always taken from that exact
tag's GitHub release and sha256-verified; `deps/` is never committed.
Bumps are one-variable changes, gated by the golden suite.

## Installing (package manager)

Not published yet — consume via git for now. A `zig package` /
registry story is deliberately deferred until the wrapper surface has
ridden at least one engine bump cycle.

## License

MIT — see [LICENSE](LICENSE).
