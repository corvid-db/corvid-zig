# corvid-zig — the binding's plan

corvid-zig is the **Zig binding** for the `corvid` embedded database. Like
its sibling `corvid-c`, it exists to prove, continuously and outside the
engine repo, that corvid's **published FFI artifacts** — the platform
cdylib, `corvid.h`, and the golden fixtures shipped in each release
archive — drive a real consumer to the same verdicts the engine's own
suite produces; on top of that proof it carries the idiomatic Zig API.

Engine repo: `corvid-db/corvid` (read-only upstream; never a submodule,
never vendored). Canonical docs: the corvid docs site's FFI section (the
`docs/FFI.md` contract — 124 symbols at v0.3.0, frozen enums, §8 idiom
gate).

## The architecture ruling: idiomatic Zig over the typed C ABI,
release artifacts only

**Deliberately the corvid-c / corvid-go pattern, not the
corvid-node/corvid-python one**: this binding wraps the **published
cdylib** fetched from the pinned GitHub release, through a single
`@cImport("corvid.h")`. Why:

- The C ABI is the engine's *locked*, stability-governed surface (FFI.md
  §8): enum values frozen, symbols append-only, breaks are loud version
  bumps. Binding to it binds to the contract, not to Rust crate
  internals that are `#[non_exhaustive]` and pre-1.0.
- Zig consumers expect a system/shared library, not a Rust toolchain.
  `zig build` after `./fetch.sh` is the whole story: no cargo, no
  vendored binaries.
- Consuming the release artifacts keeps this repo an independent
  verifier: if a published dylib/header/fixture set disagrees with the
  spec, the golden suite here catches it (that is exactly how corvid-c
  found the v0.2.0 install-name defect, its finding F1).

### The idiom mapping (ABI → Zig), all locked

| ABI shape | Zig shape |
| --- | --- |
| opaque handles (`corvid_db*`, …) | wrapper structs with `deinit()` — `Db`, `Collection`, `Query`, `Pred`, `Rows`, `Strs`, `GeoHits`, `GroupIter`, `SchemaIter`, `Value` — every `deinit` nulls its handle, so a second `deinit` is inert (never the ABI's double free) |
| `CORVID_ERR` + thread-local last error | Zig error unions: `Error` (one error per `corvid_err` code, plus `Unexpected`), mapped by reading `corvid_last_error_code` on failure; `lastErrorCode()`/`lastErrorMessage()` stay public |
| frozen enums (`corvid_metric`, …) | Zig enums with the ABI's exact values (`Metric`, `Quant`, `Cmp`, `FieldType`, `ValueKind`, `ErrCode`) |
| consumed-by-call args (`pred` trees, query builders) | MOVE semantics: consuming calls take the wrapper by pointer and null its handle — a moved wrapper's `deinit()` is a safe no-op. The C ABI's consumed-then-freed UB class cannot happen |
| borrowed views (`_ref` buffers, `rows_next` docs, `map_get` children) | `ValueView` — a type DISTINCT from owned `Value` with read-only methods and **no `deinit`**: freeing a borrow is a compile error here, where in C it is UB (spec §4.4) |
| `corvid_update_fn` / `corvid_scan_fn` C fn pointers | Zig closures: a context value + comptime-known Zig function, bridged by a `callconv(.c)` trampoline. An `update` callback returning ANY Zig error aborts the RMW through the ABI's §1.6 abort channel (a thread-local slot re-attaches the original error to the caller); a `scan` callback returns false to stop |
| strings/bytes/vectors | `[]const u8` / `[]const f32` slices (ptr+len everywhere — the ABI's binary-safe shape maps 1:1) |
| query builder | fluent `Query`: setters return `*Query`; `run()`/aggregates consume |

**Panic safety, considered:** a panic inside a user callback never
unwinds through C frames — Zig panics abort the process by default — so
the ABI's "a misbehaving callback" contract stays structural, not
hopeful. Wrapper-level misuse that would be UB in C (double free of a
consumed handle, freeing a borrow) is either a compile error (`ValueView`
has no destructor) or a benign no-op (moved or already-`deinit`'ed
wrappers are inert — `Db`/`Collection` included); the
remaining sharp edges are the borrowed-slice lifetimes, which carry the
spec's §5 rule 6 wording on every method that returns one.

The raw ABI remains importable as `corvid.c` (the `@cImport`), because
the golden harness drives it exactly as the engine's own C harness does —
application code should stick to the wrapper types.

## The locked rule: golden port BEFORE ergonomic sugar

Inherited from the bindings program's master plan and non-negotiable:

> **A binding opens with the golden-suite port.** The engine's golden
> fixtures (267 executable lines across 8 files at v0.3.0 — the 256 the
> suite shipped with, plus the v0.3.0 `VMAP_KEYS`/`GET_KEYS`/`PHRASE`
> lines) are the contract; a binding that wraps the ABI before it can
> replay the contract is building on unverified ground. No ergonomic
> sugar ships until the port is green against a tagged release's
> published artifacts.

corvid-zig's first substantive deliverable is `test/golden.zig` — the
engine harness (`c/smoke.c`), ported statement-for-statement — driven
against the DOWNLOADED libcorvid. The fixtures are vendored in `golden/`
(fetch byte-compares them against the release's copies), and the harness
keeps the engine's discipline: every counted line must dispatch
(`executed == lines`, counted in an independent pre-scan), first failure
names file:line + OP + expected-vs-got, every handle freed on its
creation path.

## Binding rules (from the master plan)

- **Pin EXACT engine tags.** One engine version at a time; today `v0.3.0`.
  The pin lives in exactly one variable per fetch script
  (`CORVID_VERSION` / `$CorvidVersion`) and is stamped into
  `deps/version.txt`; build.zig never guesses.
- **Artifacts come from the tag's GitHub release**, not from a local
  build of the engine: `https://github.com/corvid-db/corvid/releases/download/<tag>/…`,
  verified against the release's `checksums.txt` (sha256) before
  anything is extracted or used, then normalized into `deps/current/`
  (stable name, so build.zig stays platform-independent).
- **No vendored binaries in git.** `deps/` is gitignored; every consumer
  runs `fetch.sh`/`fetch.ps1` to populate it deterministically. The
  golden FIXTURES are vendored (they are the reviewable contract), and
  fetch refuses to proceed if the release's copies differ.
- **No network at build time.** `zig build` consumes `deps/current`
  only.
- **Published-artifact defects are findings, not patches.** Divergence is
  reported upstream (`corvid-db/corvid`), never worked around locally.

## Toolchain policy

Per the bindings program (`scripts/bindings/README.md`, engine repo):
modern minimums, CI tests current + previous, no EOL lines.

- **Zig floor: 0.16.0 (the current stable line).** Zig is pre-1.0 and
  each minor breaks std; 0.16 moved the entire `std.fs` file API under
  `std.Io` with an explicit `Io` context, so one source tree honestly
  covering 0.15 AND 0.16 would need a compat shim across every file
  touchpoint — not "cheap", and every floor we ship is a compat promise
  with zero users to protect. The floor therefore rides the current
  stable line and moves with it (one PR per bump, golden CI as the
  gate); when Zig stabilizes its std surface, the previous-minor leg is
  added to the matrix.
- **CI: Zig 0.16.x on ubuntu / macos / windows** (`mlugg/setup-zig`),
  actions current-major (`actions/checkout@v7` era).
- **No EOL toolchains anywhere.**

## Phase Z1 (this bootstrap) — scope

1. **Plan doc** (this file) — the ruling, written first.
2. **Repo scaffold** — README (role, usage, requirements), MIT LICENSE
   (matching corvid's copyright line), `.gitignore` (`deps/`,
   `.zig-cache/`, `zig-out/`).
3. **Fetch + verify** — `fetch.sh` (bash) / `fetch.ps1` (PowerShell):
   pinned release, sha256 against `checksums.txt`, vendored-fixture
   byte-check, normalize into `deps/current/`, stamp `deps/version.txt`.
4. **Build system** — `build.zig`: the `corvid` module over
   `deps/current` (include path, `-lcorvid` + rpath on macOS/Linux, the
   MSVC import lib / its mingw twin on Windows), the golden suite, the
   examples tour, `test`/`examples`/`run-<name>` steps.
5. **The wrapper** — `src/corvid.zig`, the idiom mapping above, with
   unit tests pinning its ergonomic promises (error mapping, move
   semantics, borrow typing, phrase order/CJK/k=0, page resume).
6. **The golden port** — `test/golden.zig`, 267/267 executable lines,
   including the v0.3.0 `VMAP_KEYS`/`GET_KEYS` (map-key iteration) and
   `PHRASE`/`PHRASE_K0` (direct positional search) lines.
7. **Examples tour** — six runnable programs (quickstart, hybrid,
   vector_index, text_search, graph, geo), each a `zig build run-<name>`
   and a CI step; text_search demonstrates the new `phraseSearch` API
   (order sensitivity, stop-word collapse, CJK bigrams, inert k=0).
8. **Surface manifest** — `docs/SURFACE.tsv` (327 engine constructs at
   the pin: 180 mapped to the Zig API with golden-line proofs, 147 N/A
   with the ABI's §9 reasons), gated by `scripts/surface-gate.sh`.
9. **CI** — `.github/workflows/ci.yml`: the three-OS matrix (fetch +
   verify, `zig build test`, examples), a sanitizer leg where Zig
   supports it cleanly, and the surface gate.

## Findings against published artifacts

(none yet — the v0.3.0 artifacts verify and the suite is 267/267 green on
them.)

## Verdict protocol

The port keeps the engine harness's output contract: one
`SMOKE <file> lines=<n> executed=<n>` line per fixture on stdout, exit 0
only when every expectation of every executable line passed and the
dispatch count matches the pre-scan count. Divergence from the
engine-side suite's pass/fail verdicts is a defect here; divergence of
the *artifacts* from the engine repo is a finding for the engine repo.
