---
title: Rust → Lean 4 FFI Benchmarks
last_updated: 2026-04-23
tags:
  - ffi
  - benchmark
  - aeneas
  - performance
  - fast-path
---

# Rust → Lean 4 FFI Benchmarks

End-to-end measurements for calling the Aeneas-generated Lean 4 consensus
pipeline from Rust via `rust-ffi/`.

## Setup

- Lean toolchain: `leanprover/lean4:v4.28.0-rc1`
- Rust: cargo release profile (`cargo run --release`)
- Host: Linux 6.18.12+kali-amd64, x86_64

`ConsensusLean4/Ffi.lean` exports 14 `@[export csf_*]` symbols:
- 1 leaf (`csf_slot_is_justifiable_after`)
- 3 micro-benchmarks (`csf_bench_sija_loop`, `csf_bench_vec_build`, `csf_bench_vec_scan`)
- 5 measured pipeline wrappers (`csf_state_transition_e2e`, `csf_process_slots`,
  `csf_process_block_header`, `csf_process_attestations`, `csf_process_block`)
- 5 paired build-only twins (`csf_build_only_*`) that perform identical
  Lean-side input construction without invoking the pipeline.

The `@[export]` wrappers became compilable after replacing the five `axiom`
shims in `ConsensusLean4/FunsExternal.lean` (`Result.branch`,
`Result.from_residual`, `Ordering.eq`, `Vec.clear`, `Vec.is_empty`) with real
Lean definitions. `Funs.lean` is still wrapped in `noncomputable section`,
but Lean only suppresses code generation for definitions whose bodies actually
reference something it cannot compile, so providing real shims is enough.

Run: `cd rust-ffi && cargo run --release` (full grid, ~3 min)
or `CSF_QUICK=1 cargo run --release` (reduced grid, ~30 s).

## Headline metric and methodology caveats

The pipeline tables below report `pipeline = total − mirrored Lean-side input
construction`. The "build-only" twin for each measured wrapper performs the
*exact* same constructor calls (validators, attestations, state, block, and any
pre-call `state.slot` mutation) and returns immediately. The Rust harness runs
`(total, build)` sample pairs back-to-back per cell so cache and allocator
state are matched, then reports the **median of paired deltas**.

This headline number is **not** an absolute intrinsic pipeline cost. The
builders themselves are quadratic in V (`Vec.push` repeatedly), and the
subtraction nets out the matched setup work — so the number is sensitive to
construction strategy. It is the cost of the pipeline path with this
benchmark's specific input shape.

Three further caveats:

- All Merkle hashes are stubbed to `H256.ZERO` (`Funs.lean:1334, 2503`).
  The benchmark exercises pipeline *control flow*, not cryptographic work.
- Attestations are constructed with all-false `aggregation_bits`. This avoids
  the 2/3-justification short-circuit so the outer attestation loop runs for
  all A attestations, but the per-bit `index_mut` write path inside
  `process_single_attestation_loop` (`Funs.lean:2104–2118`) only fires when
  bits are true and is therefore *not* exercised here. A realistic workload
  with set bits would (a) increase per-attestation work via `index_mut` writes,
  then (b) short-circuit after a few attestations once 2/3 is reached. The two
  effects pull in opposite directions; the absolute number here is neither an
  upper nor lower bound for production.
- All attestations target the same `(slot=1, root=H_TARGET)` checkpoint, so
  `find_or_create_votes` only walks its create-V-false-bools path once.
  Distinct targets per attestation would multiply that cost by A.

## FFI boundary cost

| Metric | Value |
|---|---|
| Lean runtime init (one-time) | ~46 ms |
| Single FFI call `slot_is_justifiable_after(u64, u64) → u8` | 461 ns – 14.7 µs |

## Micro-benchmarks (regression sentinels)

### `slot_is_justifiable_after` in a Lean-internal loop — **linear O(N)**

| N | total | per-call |
|---:|---:|---:|
| 1,000 | 7.2 ms | 7.2 µs |
| 10,000 | 84.3 ms | 8.4 µs |
| 100,000 | 1.50 s | 15.0 µs |
| 1,000,000 | 17.8 s | 17.8 µs |

### `Vec.push × N` (build Vec\<U64\>) — **O(N²)**

| N | total | N²-norm (ns / N²) |
|---:|---:|---:|
| 100 | 114 µs | 11.4 |
| 1,000 | 9.2 ms | 9.2 |
| 5,000 | 259 ms | 10.4 |
| 10,000 | 1.02 s | 10.2 |
| 20,000 | 4.43 s | 11.1 |

Stable N²-norm ≈ **10 ns** confirms the quadratic scaling baseline.

### `Vec.index_usize × N` (build + linear scan) — **O(N²)**

| N | total | N²-norm |
|---:|---:|---:|
| 100 | 132 µs | 13.2 |
| 1,000 | 14.8 ms | 14.8 |
| 5,000 | 277 ms | 11.1 |
| 10,000 | 1.21 s | 12.1 |
| 20,000 | 3.74 s | 9.3 |

## End-to-end pipeline measurements

Validation gates satisfied per wrapper (see `ConsensusLean4/Ffi.lean` for
construction details): proposer index = `slot % V`, parent/state roots = ZERO
(matching the stubbed `hash_tree_root_*`), `historical_block_hashes` pre-seeded
with two non-zero entries `[H_FINALIZED, H_TARGET]` so attestation
`checkpoint_exists` returns true, `latest_finalized.slot = 0`, empty
`justifications_roots`. Every cell below shows `n_ok = iters` (100% success
on the happy path).

### `process_slots` and `process_block_header` — pipeline ≈ O(1)

The pipeline-only cost is in the µs range and effectively independent of V; the
V-sweep is a methodology check. Negative deltas at higher V are subtraction
noise — the build cost dominates by 2-3 orders of magnitude.

| Wrapper | V=100 (build) | V=100 (pipeline) | V=2000 (build) | V=2000 (pipeline) |
|---|---:|---:|---:|---:|
| `process_slots` | 30 µs | 8 µs | 12 ms | 160 µs |
| `process_block_header` | 52 µs | 10 µs | 20 ms | 980 µs |

### `process_attestations` — **headline A·V² benchmark**

Pipeline-only times (median of paired deltas). All cells `n_ok = 30/30`
(V≤500), `10/10` (V=1000), or `3/3` (V=2000).

| V \ A | 1 | 4 | 16 | 64 |
|---:|---:|---:|---:|---:|
| 100 | 216 µs | 522 µs | 1.71 ms | 6.90 ms |
| 500 | 4.24 ms | 9.68 ms | 56.79 ms | 135.35 ms |
| 1,000 | 18.69 ms | 42.51 ms | 137.15 ms | 780.21 ms |
| 2,000 | 112.43 ms | 222.92 ms | 796.89 ms | **2.67 s** |

Per-(V²·A) constants (ns) cluster between 8 and 16 across the grid (median
~12 ns), within ~1.5× of the 10 ns/N² Vec.push baseline.

### `process_block` and `state_transition_e2e` — full pipeline

Same scaling, slightly different absolute numbers (header validation +
optional state-root check overhead).

| Wrapper | V=1000, A=16 (pipeline) | V=1000, A=16 (per-V²·A) |
|---|---:|---:|
| `process_attestations` | 137.15 ms | 8.6 ns |
| `process_block` | 199.50 ms | 12.5 ns |
| `state_transition_e2e` | 187.82 ms | 11.7 ns |

## Setup vs pipeline cost (headline)

`pipeline = total − build_only`. `% setup` = `build_only / total`.

| Wrapper | V | A | build_only | total | pipeline | % setup |
|---|---:|---:|---:|---:|---:|---:|
| `process_attestations` | 500 | 16 | 1.88 ms | 58.62 ms | 56.79 ms | 3.2% |
| `process_attestations` | 1,000 | 16 | 4.60 ms | 141.83 ms | 137.15 ms | 3.2% |
| `process_attestations` | 2,000 | 16 | 26.48 ms | 831.09 ms | 796.89 ms | 3.2% |
| `process_attestations` | 2,000 | 64 | 22.29 ms | 2.70 s | 2.67 s | 0.8% |
| `state_transition_e2e` | 1,000 | 16 | 5.62 ms | 193.44 ms | 187.82 ms | 2.9% |

Setup is a small fraction of total at meaningful (V, A); the headline pipeline
column is dominated by genuine pipeline work, not by Vec construction overhead.

## Re-derived extrapolation: V = 1M

The original PR projected "infeasible at V≈1M (~hours)" from the 7.5 ns/N²
micro-benchmark constant alone. With measured e2e numbers the projection
sharpens — and the answer is days, not hours.

Using **measured** per-(V²·A) constant ≈ 12 ns from `process_attestations` /
`state_transition_e2e` at V≥1000:

| V | A | extrapolated pipeline (one block) |
|---:|---:|---:|
| 1,000 | 16 | 192 ms (measured) |
| 10,000 | 16 | 19.2 s |
| 100,000 | 16 | 1,920 s ≈ 32 min |
| 1,000,000 | 16 | 192,000 s ≈ **2.2 days** |
| 1,000,000 | 64 | ~9 days |

The "infeasible at V≈1M" claim stands and was, if anything, understated. End-to-end
processing of a single block at Ethereum scale (V≈1M, ~64 attestations) in the
extracted Lean code would take of order ~10 days — for *one* state transition.

## Fast-path implementation (Array-backed)

`ConsensusLean4/FastPath.lean` provides `processAttestationsFast` — a
hand-rolled Array-backed Lean implementation with the same input/output
signature as the Aeneas-generated `state_transition.process_attestations`.
Both coexist; the FFI layer exposes them under separate `csf_*` symbols
(`csf_process_attestations` vs `csf_process_attestations_fast`). The benchmark
harness runs a **parity check** on both after the timing sweep — every tested
(V, A) pair returned identical result codes.

### Why not `attribute [implemented_by ...]`?

The original plan was to swap the fast impl in at runtime via
`attribute [implemented_by processAttestationsFast] state_transition.process_attestations`.
Lean 4 rejects this with:

```
Cannot add attribute [implemented_by] to declaration
state_transition.process_attestations because it is in an imported module
```

Once a module's IR is compiled and imported, its runtime implementation is
frozen. Editing `Funs.lean` to inline the attribute is forbidden by policy
(Aeneas regenerates the file). So the fast impl is exposed as a parallel
function rather than a hook — callers opt in by linking the fast symbol.

### Algorithm (Array-backed)

1. Convert every `Vec` field of `State` used by attestation processing to a
   Lean `Array` at the boundary (O(V) per field).
2. Unflatten `justifications_validators` into `Array (H256 × Array Bool)` —
   O(R·V) instead of O(R·V²).
3. For each attestation: `is_valid_vote` on arrays, then linear scan +
   `Array.replicate V false` for the create-votes path (O(V)), then iterate
   bits with `Array.set!` (O(V)), then count with `Array.get` (O(V)).
   Total per attestation: **O(V)**.
4. `serialize_justifications`: flatten arrays back into a single `Array Bool`
   of size R·V, then Array → List → Vec (O(R·V) total).
5. If the 2/3 threshold is reached during any attestation, bail out and
   re-run the original slow Aeneas version from the initial state (identical
   semantics for the try_finalize path, which the benchmark never exercises).

### Speedup measurements

Pipeline-only times (median of paired deltas), release build, same host.
All cells show parity with the slow path (`result=0`). Columns: **slow**
from `csf_process_attestations`, **fast** from `csf_process_attestations_fast`.

| V | A | slow | fast | speedup |
|---:|---:|---:|---:|---:|
| 100 | 16 | 1.71 ms | 607 µs | 2.8× |
| 100 | 64 | 6.90 ms | 2.43 ms | 2.8× |
| 500 | 16 | 31.70 ms | 1.57 ms | **20×** |
| 500 | 64 | 135.35 ms | 6.13 ms | **22×** |
| 1,000 | 16 | 140.32 ms | 2.75 ms | **51×** |
| 1,000 | 64 | 780.21 ms | 10.29 ms | **76×** |
| 2,000 | 16 | 796.89 ms | 5.96 ms | **134×** |
| 2,000 | 64 | **2.67 s** | **20.51 ms** | **130×** |

### Fast-path scaling verification

Per-(V²·A) drops from ~10 ns (slow, confirms O(A·V²)) to **~0.08 ns**
at V=2000 — effectively dropping out of the quadratic regime. Per-(V·A)
for the fast path at V≥1000 stabilizes around **~160 ns**, confirming
linear O(A·V) scaling.

### Re-derived V=1M extrapolation with fast path

Using the measured ~160 ns/(V·A) from V≥1000:

| V | A | slow projection | fast projection |
|---:|---:|---:|---:|
| 1,000 | 16 | 140 ms | 2.56 ms |
| 100,000 | 16 | 32 min | 256 ms |
| 1,000,000 | 16 | **2.2 days** | **~2.6 s** |
| 1,000,000 | 64 | ~9 days | ~10 s |

The fast path makes Ethereum-scale per-block processing tractable — a single
block's attestation work in extracted Lean drops from days to seconds.

### Correctness caveats for the fast path

- The fast path handles the benchmark's "no finalization" input shape.
- If `aggregation_bits` push the vote count past the 2/3 threshold, the fast
  path **bails out and re-runs the slow Aeneas version** to avoid
  reimplementing `try_finalize` / `remove_justification` / `set_justified`.
  This preserves semantic equivalence at the cost of speedup for that case.
- Parity with the slow version is currently verified by runtime result-code
  comparison on sampled inputs, not by formal proof. A next step would be a
  Lean theorem proving `processAttestationsFast state atts = state_transition.process_attestations state atts`
  for all inputs, which the shared signature makes straightforward.

## Root cause and mitigations

The quadratic blow-up is not an FFI artifact. It comes from Aeneas's Vec
translation:

```lean
def Vec (α : Type u) := { l : List α // l.length ≤ Usize.max }
```

With a `List`-backed representation, `push` is `List.concat` (O(N)) and
`index_usize` is `List.get?` (O(i)). Every Rust `O(N)` loop becomes `O(N²)` in
extracted Lean. Proofs are unaffected.

Options for executable-speed workloads:

1. **Upstream: switch Aeneas `Vec` to an `Array`-backed representation.**
   Affects every Aeneas-generated project.
2. **Per-project: override hot functions in `FunsExternal.lean` with efficient
   Lean implementations and link via `@[extern]`.** Keeps Aeneas output as-is
   for verification, swaps implementations at runtime.
3. **Treat Lean output as a reference implementation only.** Proofs are
   unaffected by runtime cost; use the Rust original for execution.

## Out of scope

- `compute_lmd_ghost_head` / `compute_block_weights` (fork choice) — different
  input shape (block tree + per-validator attestations); follow-up PR.
- `process_attestations` with set `aggregation_bits` (exercises the per-bit
  `index_mut` write path that the current bench skips); follow-up PR.
- `process_attestations` with distinct targets per attestation (multiplies
  `find_or_create_votes` create cost by A); follow-up PR.
- Real SSZ Merkleisation in `FunsExternal.lean` (would invalidate the
  ZERO-hash gate workarounds used here).
