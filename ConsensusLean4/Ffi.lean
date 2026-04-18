import ConsensusLean4.Funs
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
