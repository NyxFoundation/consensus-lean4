# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & toolchain

- `lake build` — compiles the `ConsensusLean4` library (default target). First build downloads the Aeneas + Mathlib dependencies and takes a long time.
- Toolchain is pinned in `lean-toolchain` (`leanprover/lean4:v4.28.0-rc1`) and is managed by `elan`.
- `Aeneas` is fetched by Lake from the commit hash pinned in `lakefile.lean`. Bumping that commit can break generated code — regenerate (see below) after updating.
- There are no tests, no linter, and no run target. `lake build` is the sole CI-equivalent check.

## Architecture

This repo is **not hand-written Lean** — it is the Lean 4 output of the Charon + Aeneas pipeline applied to the Rust `ethlambda_verification` crate (Lean Consensus / 3SF-mini). Three of the four source files in `ConsensusLean4/` are overwritten on every Aeneas run; treat them as build artefacts.

```
ConsensusLean4.lean              entry point; re-exports Types, FunsExternal, Funs
ConsensusLean4/Types.lean        (generated) structs, enums, type aliases
ConsensusLean4/Funs.lean         (generated) ~3000 LOC of function bodies in noncomputable section
ConsensusLean4/FunsExternal_Template.lean  (generated) canonical signatures for external axioms
ConsensusLean4/FunsExternal.lean           EDITABLE — the only place humans swap axioms for real defs
```

`Funs.lean` imports `ConsensusLean4.FunsExternal`, which is the single swap point for the five external axioms (`Vec::clear`, `Vec::is_empty`, `Ordering::eq`, `Result::branch`, `Result::from_residual`). `FunsExternal_Template.lean` is refreshed on every Aeneas run — diff it against `FunsExternal.lean` after regeneration to catch upstream signature drift.

`Funs.lean` is wrapped in `noncomputable section` because those five stdlib shims are still axioms. Only drop the `noncomputable` marker (by passing `-all-computable` to Aeneas) **after** `FunsExternal.lean` contains a real executable Lean definition for every axiom.

## Working in this repo

- **Do not hand-edit** `Types.lean`, `Funs.lean`, or `FunsExternal_Template.lean`. Any change there will be lost the next time Aeneas runs. Fix issues upstream in the Rust source or inside `FunsExternal.lean`.
- All human work (axiom implementations, helper lemmas, proofs about the extracted functions) belongs in `FunsExternal.lean` or in a new file you add and import from `ConsensusLean4.lean`.
- The generated code uses `Aeneas.Std` types (`Std.U8`, `Std.U64`, `Std.Usize`, `alloc.vec.Vec`, the `Result` monad for panic-tracking) — not Lean core types. When writing definitions that interoperate with `Funs.lean`, match these types exactly.
- Regeneration command (requires an Aeneas-ready LLBC of `ethlambda_verification`):

  ```bash
  aeneas -backend lean -split-files -subdir ConsensusLean4 -dest <repo-root> ethlambda_verification.llbc
  ```

  `-split-files` is load-bearing: it separates external axioms into the `_Template` file so `FunsExternal.lean` is not clobbered.

## Domain scope (what the generated code covers)

- State transition: `process_slots`, `process_block_header`, `process_attestations`, `try_finalize`
- Fork choice (LMD GHOST): `compute_lmd_ghost_head`, `compute_block_weights`
- Justified slots: `is_slot_justified`, `set_justified`, `extend_to_slot`, `shift_window`
- 3SF-mini justifiability predicate: `slot_is_justifiable_after` (delta ≤ 5, perfect squares, pronic numbers)
