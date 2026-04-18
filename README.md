# consensus-lean4

Lean 4 formalization of the [Lean Consensus](https://github.com/leanEthereum/leanSpec) (3SF-mini) protocol, automatically generated from a Rust implementation using [Aeneas](https://github.com/AeneasVerif/aeneas).

## What's included

The generated Lean code covers the core consensus algorithms:

- **State transition** — `process_slots`, `process_block_header`, `process_attestations`, `try_finalize`
- **Fork choice** — `compute_lmd_ghost_head`, `compute_block_weights` (LMD GHOST)
- **Justified slots** — `is_slot_justified`, `set_justified`, `extend_to_slot`, `shift_window`
- **3SF-mini justifiability** — `slot_is_justifiable_after` (delta ≤ 5, perfect squares, pronic numbers)

## Layout

```
ConsensusLean4.lean                  -- root index, re-exports the three modules below
ConsensusLean4/
├── Types.lean                       -- `H256`, `Checkpoint`, `Block`, …
├── Funs.lean                        -- all function bodies (~3000 LOC, axiom-free)
├── FunsExternal_Template.lean       -- auto-generated signatures for external functions
└── FunsExternal.lean                -- active implementation file (edit this)
```

`Funs.lean` imports `ConsensusLean4.FunsExternal`, so `FunsExternal.lean` is the
single swap point for anyone wanting to replace the `axiom` stubs with real Lean
implementations. `FunsExternal_Template.lean` is refreshed on every Aeneas run and
serves as the canonical signature reference — diff it against `FunsExternal.lean`
to catch upstream signature drift.

The extracted code is wrapped in `noncomputable section` because the five standard
library functions used by the Rust source (`Vec::clear`, `Vec::is_empty`,
`Ordering::eq`, `Result::branch`, `Result::from_residual`) are left as `axiom`s.
Dropping the `noncomputable section` marker (via Aeneas's `-all-computable` flag) is
only safe once `FunsExternal.lean` provides executable implementations for every
axiom.

## Build

Requires [Lean 4](https://leanprover.github.io/lean4/doc/setup.html) and [elan](https://github.com/leanprover/elan).

```bash
lake build
```

The Aeneas runtime library (and its Mathlib dependency) is fetched automatically via
`lakefile.lean`.

## Source

Generated from the [ethlambda](https://github.com/lambdaclass/ethlambda) Rust codebase
using the [Charon](https://github.com/AeneasVerif/charon) + [Aeneas](https://github.com/AeneasVerif/aeneas)
pipeline:

```
Rust (ethlambda consensus crates)
  → Charon (MIR → LLBC)
    → Aeneas (LLBC → Lean 4)
```

The Rust source was adapted into an Aeneas-compatible subset: `HashMap` replaced with
`Vec<(K,V)>`, iterator chains replaced with explicit loops, proc-macro derives removed,
and `hash_tree_root` stubbed as a placeholder.

### Regeneration command

```bash
aeneas \
  -backend lean \
  -split-files \
  -subdir ConsensusLean4 \
  -dest <repo-root> \
  ethlambda_verification.llbc
```

`-split-files` isolates external axioms into `FunsExternal_Template.lean`;
`-subdir ConsensusLean4` emits the import paths under the `ConsensusLean4.*`
namespace. Regenerating overwrites `Types.lean`, `Funs.lean`, and
`FunsExternal_Template.lean` but leaves `FunsExternal.lean` untouched. Add
`-all-computable` once `FunsExternal.lean` has real implementations for every
axiom.

## License

MIT
