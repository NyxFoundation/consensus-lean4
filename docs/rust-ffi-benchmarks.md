---
title: Rust → Lean 4 FFI Benchmarks
last_updated: 2026-04-18
tags:
  - ffi
  - benchmark
  - aeneas
  - performance
---

# Rust → Lean 4 FFI Benchmarks

Measurements for calling the Aeneas-generated Lean 4 consensus code from Rust via `rust-ffi/`.

## Setup

- Lean toolchain: `leanprover/lean4:v4.28.0-rc1`
- Rust: cargo release profile (`cargo run --release`)
- Host: Linux 6.18.12+kali-amd64, x86_64

The entry point exported from `ConsensusLean4/Ffi.lean` is `state_transition.slot_is_justifiable_after`. Three additional `@[export]` wrappers expose internal scaling benchmarks (`csf_bench_sija_loop`, `csf_bench_vec_build`, `csf_bench_vec_scan`).

Run: `cd rust-ffi && cargo run --release`.

## FFI boundary cost

| Metric | Value |
|---|---|
| Lean runtime init (one-time) | ~43 ms |
| Single FFI call `slot_is_justifiable_after(u64, u64) → u8` | 320 ns – 5.9 µs |
| Sustained throughput (1M call batch, Rust loop) | **~92,000 calls/s** (10.9 µs/call) |

Per-call cost is dominated by Lean heap allocations for the `Std.U64` (`BitVec`) and `Result Bool` values, not by the C ABI crossing itself.

## Scaling: Vec-free vs Vec-heavy functions

### `slot_is_justifiable_after` in a Lean-internal loop — **linear O(N)**

No `alloc.vec.Vec` touched. Pure U64 arithmetic + `isqrt`.

| N | total | per-call |
|---:|---:|---:|
| 1,000 | 7.7 ms | 7.7 µs |
| 10,000 | 76.9 ms | 7.7 µs |
| 100,000 | 923 ms | 9.2 µs |
| 1,000,000 | 10.7 s | 10.7 µs |

10× N → ~10× time. Per-call cost stable.

### `Vec.push × N` (build Vec\<U64\>) — **O(N²)**

`alloc.vec.Vec` is `{List α // len ≤ Usize.max}`. `Vec.push` uses `List.concat`, which is O(N).

| N | total | N²-norm (ns / N²) |
|---:|---:|---:|
| 100 | 91 µs | 9.1 |
| 1,000 | 7.2 ms | 7.2 |
| 5,000 | 189 ms | 7.6 |
| 10,000 | 726 ms | 7.3 |
| 20,000 | 2.97 s | 7.4 |

Stable N²-norm ≈ 7.5 ns confirms quadratic scaling.

### `Vec.index_usize × N` (build + linear scan) — **O(N²)**

Same pattern. N²-norm ≈ 8 ns.

| N | total |
|---:|---:|
| 100 | 83 µs |
| 1,000 | 7.9 ms |
| 10,000 | 794 ms |
| 20,000 | 3.20 s |

## Function categories by validator-count (V) dependence

### V-independent (O(1) or O(log)) — safe at any V

| Function | Signature | Complexity |
|---|---|---|
| `isqrt` | `U64 → Result U64` | O(log n) |
| `slot_is_justifiable_after` | `(U64, U64) → Result Bool` | O(log) |
| `current_proposer` | `(slot, num_validators : U64) → Result (Option U64)` | O(1) |
| `is_proposer` | `(validator_index, slot, num_validators : U64) → Result Bool` | O(1) |

### Scales with V directly through Vec operations — **hits O(N²)**

| Function | Observed complexity in extracted Lean |
|---|---|
| `count_votes(votes : Vec Bool)` | O(V²) |
| `find_or_create_votes(justifications, root, V)` | O(J·V²) |
| `process_single_attestation(state, att, V, ...)` | O(V²+) |
| `process_attestations(state, attestations)` | O(A·V²+) |
| `serialize_justifications(state, justifications, V)` | O(J·V²) |
| `remove_justification(justifications, root)` | O(J²) |

### State-mediated V dependence

| Function | Path | Complexity |
|---|---|---|
| `process_block_header` | reads `state.validators` length | O(V)+ |
| `process_block` | → `process_block_header` + `process_attestations` | O(A·V²+) |
| `process_slots` | indirect via validator processing | same |
| `state_transition` (entry) | full pipeline | **O(A·V²+)** |
| `checkpoint_exists` | `historical_block_hashes` index | O(V) per call |
| `is_valid_vote` | `justified_slots` index | O(V) |

### Fork choice — scales with blocks B × attestations A

| Function | Complexity |
|---|---|
| `get_weight(weights, root)` | O(W²) linear scan |
| `compute_block_weights(start_slot, blocks, attestations)` | O(B²·A²) |
| `compute_lmd_ghost_head(start_root, blocks, attestations, min_score)` | worst case O(B²·A²) |

## Extrapolated wall-clock by validator count

Using the measured N²-norm of ~7.5 ns:

| Function type | V = 1,000 | V = 10,000 | V = 100,000 | V = 1,000,000 |
|---|---:|---:|---:|---:|
| V-independent | µs | µs | µs | µs |
| O(V) state read | µs | ~75 µs | ~750 µs | ~7.5 ms |
| O(V²) single function | 7.5 ms | 750 ms | 75 s | ~2 hours |
| O(A·V²) full pipeline | seconds | minutes | hours | infeasible |

## Root cause and mitigations

The quadratic blow-up is not an FFI artifact. It comes from Aeneas's Vec translation:

```lean
def Vec (α : Type u) := { l : List α // l.length ≤ Usize.max }
```

With a `List`-backed representation, `push` is `List.concat` (O(N)) and `index_usize` is `List.get?` (O(i)). Every Rust `O(N)` loop becomes `O(N²)` in extracted Lean.

Options for executable-speed workloads:

1. **Upstream: switch Aeneas `Vec` to an `Array`-backed representation.** Affects every Aeneas-generated project.
2. **Per-project: override hot functions in `FunsExternal.lean` with efficient Lean implementations and link via `@[extern]`.** Keeps Aeneas output as-is for verification, swaps implementations at runtime.
3. **Treat Lean output as a reference implementation only.** Proofs are unaffected by runtime cost; use the Rust original for execution.
