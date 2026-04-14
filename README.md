# consensus-lean4

Lean 4 formalization of the [Lean Consensus](https://github.com/leanEthereum/leanSpec) (3SF-mini) protocol, automatically generated from a Rust implementation using [Aeneas](https://github.com/AeneasVerif/aeneas).

## What's included

The generated Lean code covers the core consensus algorithms:

- **State transition** — `process_slots`, `process_block_header`, `process_attestations`, `try_finalize`
- **Fork choice** — `compute_lmd_ghost_head`, `compute_block_weights` (LMD GHOST)
- **Justified slots** — `is_slot_justified`, `set_justified`, `extend_to_slot`, `shift_window`
- **3SF-mini justifiability** — `slot_is_justifiable_after` (delta ≤ 5, perfect squares, pronic numbers)

## Build

Requires [Lean 4](https://leanprover.github.io/lean4/doc/setup.html) and [elan](https://github.com/leanprover/elan).

```bash
lake build
```

The Aeneas runtime library is fetched automatically via `lakefile.lean`.

## Source

Generated from the [ethlambda](https://github.com/lambdaclass/ethlambda) Rust codebase using the [Charon](https://github.com/AeneasVerif/charon) + [Aeneas](https://github.com/AeneasVerif/aeneas) pipeline:

```
Rust (ethlambda consensus crates)
  → Charon (MIR → LLBC)
    → Aeneas (LLBC → Lean 4)
```

The Rust source was adapted into an Aeneas-compatible subset: `HashMap` replaced with `Vec<(K,V)>`, iterator chains replaced with explicit loops, proc-macro derives removed, and `hash_tree_root` stubbed as a placeholder.

## License

MIT
