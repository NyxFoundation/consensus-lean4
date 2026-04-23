import ConsensusLean4.Funs
import ConsensusLean4.FastPath
open Aeneas Aeneas.Std ethlambda_verification

@[inline] private def u64OfUInt64 (n : UInt64) : Std.U64 :=
  { bv := BitVec.ofNat 64 n.toNat }

@[inline] private def usizeOfNat (n : Nat) : Std.Usize :=
  { bv := BitVec.ofNat System.Platform.numBits n }

/-- C wrapper: 0 = ok false, 1 = ok true, 2 = fail (panic), 3 = div. -/
@[export csf_slot_is_justifiable_after]
def slotIsJustifiableAfterC (slot finalized : UInt64) : UInt8 :=
  match state_transition.slot_is_justifiable_after
          (u64OfUInt64 slot) (u64OfUInt64 finalized) with
  | Result.ok false => 0
  | Result.ok true  => 1
  | Result.fail _   => 2
  | Result.div      => 3

/-- Benchmark: run `slot_is_justifiable_after` N times in a Lean-internal loop
    (no FFI crossing per iteration). Returns the number of true results. -/
@[export csf_bench_sija_loop]
def benchSijaLoop (n : UInt64) : UInt64 := Id.run do
  let mut count : UInt64 := 0
  for i in [0:n.toNat] do
    match state_transition.slot_is_justifiable_after
            (u64OfUInt64 i.toUInt64) (u64OfUInt64 0) with
    | Result.ok true => count := count + 1
    | _ => ()
  return count

/-- Benchmark: build an Aeneas Vec<U64> of size N via `Vec.push`.
    `Vec.push` uses `List.concat` internally, so this is expected O(N²). -/
@[export csf_bench_vec_build]
def benchVecBuild (n : UInt64) : UInt64 := Id.run do
  let mut v : alloc.vec.Vec Std.U64 := alloc.vec.Vec.new Std.U64
  for i in [0:n.toNat] do
    match alloc.vec.Vec.push v (u64OfUInt64 i.toUInt64) with
    | Result.ok v' => v := v'
    | _ => ()
  return v.length.toUInt64

/-- Benchmark: build Vec<U64> of size N, then linear-scan all elements via
    `Vec.index_usize`. Each index is O(i), so total scan is O(N²). -/
@[export csf_bench_vec_scan]
def benchVecScan (n : UInt64) : UInt64 := Id.run do
  let mut v : alloc.vec.Vec Std.U64 := alloc.vec.Vec.new Std.U64
  for i in [0:n.toNat] do
    match alloc.vec.Vec.push v (u64OfUInt64 i.toUInt64) with
    | Result.ok v' => v := v'
    | _ => ()
  let mut sum : UInt64 := 0
  for i in [0:n.toNat] do
    match alloc.vec.Vec.index_usize v (usizeOfNat i) with
    | Result.ok x => sum := sum + x.bv.toNat.toUInt64
    | _ => ()
  return sum

/-! ## End-to-end pipeline benchmarks

Drive the actual consensus state-transition pipeline through FFI. Each measured
wrapper has a 1:1 `build_only_*` twin so the Rust harness can subtract setup
cost (which is itself O(V²) due to `Vec.push` allocation) from the total. -/

private def H_FINALIZED : types.H256 := Array.repeat 32#usize 170#u8
private def H_TARGET    : types.H256 := Array.repeat 32#usize 187#u8

private def mkValidator (i : Nat) : types.Validator :=
  { pubkey := Array.repeat 52#usize 0#u8
    index  := { bv := BitVec.ofNat 64 i } }

private def mkValidators (v : Nat) : Result (alloc.vec.Vec types.Validator) :=
  (List.range v).foldlM
    (fun acc i => alloc.vec.Vec.push acc (mkValidator i))
    (alloc.vec.Vec.new types.Validator)

private def mkAggBitsFalse (v : Nat) : Result (alloc.vec.Vec Bool) :=
  (List.range v).foldlM
    (fun acc _ => alloc.vec.Vec.push acc false)
    (alloc.vec.Vec.new Bool)

private def mkAttestation (v : Nat) : Result types.AggregatedAttestation := do
  let bits ← mkAggBitsFalse v
  let src : types.Checkpoint := { root := H_FINALIZED, slot := 0#u64 }
  let tgt : types.Checkpoint := { root := H_TARGET,    slot := 1#u64 }
  return { aggregation_bits := bits
           data := { slot := 1#u64, head := tgt, target := tgt, source := src } }

private def mkAttestations (a v : Nat) : Result (alloc.vec.Vec types.AggregatedAttestation) := do
  let one ← mkAttestation v
  (List.range a).foldlM
    (fun acc _ => alloc.vec.Vec.push acc one)
    (alloc.vec.Vec.new types.AggregatedAttestation)

private def mkHistorical : Result (alloc.vec.Vec types.H256) := do
  let v0 ← alloc.vec.Vec.push (alloc.vec.Vec.new types.H256) H_FINALIZED
  alloc.vec.Vec.push v0 H_TARGET

private def genesisHeader : types.BlockHeader :=
  { slot           := 0#u64
    proposer_index := 0#u64
    parent_root    := types.H256.ZERO
    state_root     := types.H256.ZERO
    body_root      := types.H256.ZERO }

private def mkGenesisState (v : Nat) : Result types.State := do
  let validators ← mkValidators v
  let historical ← mkHistorical
  let finalized : types.Checkpoint := { root := H_FINALIZED, slot := 0#u64 }
  return { config                    := { genesis_time := 0#u64 }
           slot                      := 0#u64
           latest_block_header       := genesisHeader
           latest_justified          := finalized
           latest_finalized          := finalized
           historical_block_hashes   := historical
           justified_slots           := alloc.vec.Vec.new Bool
           validators                := validators
           justifications_roots      := alloc.vec.Vec.new types.H256
           justifications_validators := alloc.vec.Vec.new Bool }

private def mkBlockAt (v : Nat) (atSlot : UInt64) (a : Nat) : Result types.Block := do
  let atts ← mkAttestations a v
  return { slot           := u64OfUInt64 atSlot
           proposer_index := u64OfUInt64 (atSlot % v.toUInt64)
           parent_root    := types.H256.ZERO
           state_root     := types.H256.ZERO
           body           := { attestations := atts } }

/-- Pack a pipeline result into a UInt8 sentinel.
    0 = ok+ok, 1 = ok+domain-error, 2 = panic, 3 = divergence, 4 = bad input.
    Note the inner `core.result.Result` uses capitalized `.Ok`/`.Err`. -/
@[inline] private def packPipeline
    (r : Result ((core.result.Result Unit state_transition.Error) × types.State))
    : UInt8 :=
  match r with
  | Result.ok (core.result.Result.Ok _,  _) => 0
  | Result.ok (core.result.Result.Err _, _) => 1
  | Result.fail _ => 2
  | Result.div    => 3

@[inline] private def packBuild {α : Type} (r : Result α) : UInt8 :=
  match r with
  | Result.ok _   => 0
  | Result.fail _ => 2
  | Result.div    => 3

/-! ### Measured wrappers (drive the pipeline). -/

@[export csf_state_transition_e2e]
def stateTransitionE2eC (v a : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok state =>
  match mkBlockAt v.toNat 1 a.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok block =>
  return packPipeline (state_transition.state_transition state block)

@[export csf_process_slots]
def processSlotsC (v target : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok state =>
  return packPipeline (state_transition.process_slots state (u64OfUInt64 target))

@[export csf_process_block_header]
def processBlockHeaderC (v : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok state =>
  match mkBlockAt v.toNat 1 0 with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok block =>
  let state' := { state with slot := 1#u64 }
  return packPipeline (state_transition.process_block_header state' block)

@[export csf_process_attestations]
def processAttestationsC (v a : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok state =>
  match mkAttestations a.toNat v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok atts =>
  return packPipeline (state_transition.process_attestations state atts)

/-! ### Fast-path wrappers (Array-backed hand-rolled implementation). -/

@[export csf_process_attestations_fast]
def processAttestationsFastC (v a : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok state =>
  match mkAttestations a.toNat v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok atts =>
  return packPipeline (ConsensusLean4.FastPath.processAttestationsFast state atts)

@[export csf_process_block]
def processBlockC (v a : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok state =>
  match mkBlockAt v.toNat 1 a.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok block =>
  let state' := { state with slot := 1#u64 }
  return packPipeline (state_transition.process_block state' block)

/-! ### Build-only twins (mirror the construction work; skip the pipeline call). -/

@[export csf_build_only_state_transition]
def buildOnlyStateTransitionC (v a : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok _ =>
  return packBuild (mkBlockAt v.toNat 1 a.toNat)

@[export csf_build_only_process_slots]
def buildOnlyProcessSlotsC (v _target : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  return packBuild (mkGenesisState v.toNat)

@[export csf_build_only_process_block_header]
def buildOnlyProcessBlockHeaderC (v : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok state =>
  match mkBlockAt v.toNat 1 0 with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok _ =>
  let _state' := { state with slot := 1#u64 }
  return 0

@[export csf_build_only_process_attestations]
def buildOnlyProcessAttestationsC (v a : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok _ =>
  return packBuild (mkAttestations a.toNat v.toNat)

@[export csf_build_only_process_block]
def buildOnlyProcessBlockC (v a : UInt64) : UInt8 := Id.run do
  if v == 0 then return 4
  match mkGenesisState v.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok state =>
  match mkBlockAt v.toNat 1 a.toNat with
  | Result.fail _ => return 2 | Result.div => return 3
  | Result.ok _ =>
  let _state' := { state with slot := 1#u64 }
  return 0
