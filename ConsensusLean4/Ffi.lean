-- FFI shim for the Rust consensus client.
-- Provides byte-level decoders/encoders for the two entry-point calling
-- conventions and exposes them through `@[export]` so Rust can invoke them
-- via the Lean runtime's ByteArray C API.
import ConsensusLean4.Types
import ConsensusLean4.FunsExternal
import ConsensusLean4.Funs

open Aeneas Aeneas.Std Result
open ethlambda_verification

namespace ConsensusLean4.Ffi

/-! ## Decoder monad

A decoder is a function from a read cursor into either `(value, newCursor)` or
`none` on underrun / malformed input. We hand-roll the Monad instance rather
than going through `StateM`/`Option` to keep the code compiling to efficient
native loops. -/

structure Cursor where
  data : ByteArray
  pos  : Nat

abbrev D (α : Type) := Cursor → Option (α × Cursor)

@[inline] def D.pure {α} (x : α) : D α := fun c => some (x, c)

@[inline] def D.bind {α β} (m : D α) (f : α → D β) : D β := fun c =>
  match m c with
  | none => none
  | some (x, c') => f x c'

instance : Monad D where
  pure := D.pure
  bind := D.bind

@[inline] def D.fail {α} : D α := fun _ => none

/-! ## Primitive readers -/

@[inline] def readU8 : D UInt8 := fun c =>
  if h : c.pos < c.data.size then
    some (c.data.get c.pos h, { c with pos := c.pos + 1 })
  else
    none

@[inline] def readBool : D Bool := do
  let b ← readU8
  D.pure (b != 0)

@[inline] def readU32LE : D UInt32 := do
  let b0 ← readU8
  let b1 ← readU8
  let b2 ← readU8
  let b3 ← readU8
  D.pure (b0.toUInt32
        ||| (b1.toUInt32 <<< 8)
        ||| (b2.toUInt32 <<< 16)
        ||| (b3.toUInt32 <<< 24))

@[inline] def readU64LE : D UInt64 := do
  let b0 ← readU8
  let b1 ← readU8
  let b2 ← readU8
  let b3 ← readU8
  let b4 ← readU8
  let b5 ← readU8
  let b6 ← readU8
  let b7 ← readU8
  D.pure (b0.toUInt64
        ||| (b1.toUInt64 <<<  8)
        ||| (b2.toUInt64 <<< 16)
        ||| (b3.toUInt64 <<< 24)
        ||| (b4.toUInt64 <<< 32)
        ||| (b5.toUInt64 <<< 40)
        ||| (b6.toUInt64 <<< 48)
        ||| (b7.toUInt64 <<< 56))

/-- Read `n` raw bytes as a `List UInt8`. -/
def readBytes (n : Nat) : D (List UInt8) := do
  match n with
  | 0 => D.pure []
  | k + 1 => do
    let b ← readU8
    let rest ← readBytes k
    D.pure (b :: rest)

/-! ## Aeneas wrappers

We bypass `Std.UScalar.tryMkOpt` because every `UInt8`/`UInt64` already fits in
the corresponding `Std.U8`/`Std.U64`. The Aeneas-generated types use `BitVec`
as their internal representation, so constructing from `x.toBitVec` is a
zero-cost coercion once Lean unifies `UScalarTy.Ux.numBits` with the raw
bit width. -/

@[inline] def fromStdU8 (x : Std.U8) : UInt8 := x.bv.toNat.toUInt8

@[inline] def fromStdU64 (x : Std.U64) : UInt64 := x.bv.toNat.toUInt64

@[inline] def fromStdUsize (x : Std.Usize) : UInt64 := x.bv.toNat.toUInt64

def readStdU8 : D Std.U8 := do
  let x ← readU8
  match Std.UScalar.tryMkOpt .U8 x.toNat with
  | some v => D.pure v
  | none   => D.fail

def readStdU64 : D Std.U64 := do
  let x ← readU64LE
  match Std.UScalar.tryMkOpt .U64 x.toNat with
  | some v => D.pure v
  | none   => D.fail

def readStdUsize : D Std.Usize := do
  let x ← readU64LE
  match Std.UScalar.tryMkOpt .Usize x.toNat with
  | some v => D.pure v
  | none   => D.fail

/-- Build a Vec from a list, checking the `length ≤ Usize.max` bound at runtime. -/
def mkVec {α} (l : List α) : Option (alloc.vec.Vec α) :=
  if h : l.length ≤ Std.Usize.max then some ⟨l, h⟩ else none

/-- Build a fixed-size Array with runtime length check. -/
def mkArray {α} (n : Std.Usize) (l : List α) : Option (Std.Array α n) :=
  if h : l.length = n.val then some ⟨l, h⟩ else none

/-- Decode a `Vec T` prefixed by a little-endian u32 length, with a per-element
    decoder. -/
def readVec {α} (readElem : D α) : D (alloc.vec.Vec α) := do
  let len ← readU32LE
  let rec loop (n : Nat) : D (List α) := do
    match n with
    | 0 => D.pure []
    | k + 1 => do
      let x ← readElem
      let rest ← loop k
      D.pure (x :: rest)
  let xs ← loop len.toNat
  match mkVec xs with
  | some v => D.pure v
  | none   => D.fail

/-- Read exactly `n` bytes and package as a fixed-size `Std.Array U8 n`. -/
def readFixedU8Array (n : Std.Usize) : D (Std.Array Std.U8 n) := do
  let bytes ← readBytes n.val
  let stds := bytes.filterMap (fun b => Std.UScalar.tryMkOpt .U8 b.toNat)
  match mkArray n stds with
  | some arr => D.pure arr
  | none     => D.fail

def readH256 : D types.H256 := readFixedU8Array 32#usize

/-! ## Type decoders -/

def readCheckpoint : D types.Checkpoint := do
  let root ← readH256
  let slot ← readStdU64
  D.pure { root, slot }

def readAttestationData : D types.AttestationData := do
  let slot   ← readStdU64
  let head   ← readCheckpoint
  let target ← readCheckpoint
  let source ← readCheckpoint
  D.pure { slot, head, target, source }

def readBlockHeader : D types.BlockHeader := do
  let slot           ← readStdU64
  let proposer_index ← readStdU64
  let parent_root    ← readH256
  let state_root     ← readH256
  let body_root      ← readH256
  D.pure { slot, proposer_index, parent_root, state_root, body_root }

def readChainConfig : D types.ChainConfig := do
  let genesis_time ← readStdU64
  D.pure { genesis_time }

def readValidator : D types.Validator := do
  let pubkey ← readFixedU8Array 52#usize
  let index  ← readStdU64
  D.pure { pubkey, index }

def readState : D types.State := do
  let config ← readChainConfig
  let slot ← readStdU64
  let latest_block_header ← readBlockHeader
  let latest_justified ← readCheckpoint
  let latest_finalized ← readCheckpoint
  let historical_block_hashes ← readVec readH256
  let justified_slots ← readVec readBool
  let validators ← readVec readValidator
  let justifications_roots ← readVec readH256
  let justifications_validators ← readVec readBool
  D.pure {
    config, slot, latest_block_header, latest_justified, latest_finalized,
    historical_block_hashes, justified_slots, validators,
    justifications_roots, justifications_validators
  }

def readAggAttestation : D types.AggregatedAttestation := do
  let aggregation_bits ← readVec readBool
  let data ← readAttestationData
  D.pure { aggregation_bits, data }

def readBlockBody : D types.BlockBody := do
  let attestations ← readVec readAggAttestation
  D.pure { attestations }

def readBlock : D types.Block := do
  let slot           ← readStdU64
  let proposer_index ← readStdU64
  let parent_root    ← readH256
  let state_root     ← readH256
  let body           ← readBlockBody
  D.pure { slot, proposer_index, parent_root, state_root, body }

/-! ## Encoder — side-effectful `ByteArray` builder -/

@[inline] def pushU8 (buf : ByteArray) (x : UInt8) : ByteArray := buf.push x

def pushU32LE (buf : ByteArray) (x : UInt32) : ByteArray :=
  let buf := buf.push (x.toUInt8)
  let buf := buf.push ((x >>> 8).toUInt8)
  let buf := buf.push ((x >>> 16).toUInt8)
  let buf := buf.push ((x >>> 24).toUInt8)
  buf

def pushU64LE (buf : ByteArray) (x : UInt64) : ByteArray :=
  let buf := buf.push (x.toUInt8)
  let buf := buf.push ((x >>>  8).toUInt8)
  let buf := buf.push ((x >>> 16).toUInt8)
  let buf := buf.push ((x >>> 24).toUInt8)
  let buf := buf.push ((x >>> 32).toUInt8)
  let buf := buf.push ((x >>> 40).toUInt8)
  let buf := buf.push ((x >>> 48).toUInt8)
  let buf := buf.push ((x >>> 56).toUInt8)
  buf

def pushStdU64 (buf : ByteArray) (x : Std.U64) : ByteArray :=
  pushU64LE buf (fromStdU64 x)

def pushBool (buf : ByteArray) (b : Bool) : ByteArray :=
  buf.push (if b then 1 else 0)

def pushH256 (buf : ByteArray) (h : types.H256) : ByteArray :=
  h.val.foldl (fun b x => b.push (fromStdU8 x)) buf

def pushCheckpoint (buf : ByteArray) (c : types.Checkpoint) : ByteArray :=
  let buf := pushH256 buf c.root
  pushStdU64 buf c.slot

def pushU64Pair (buf : ByteArray) (p : Std.U64 × Std.U64) : ByteArray :=
  pushStdU64 (pushStdU64 buf p.1) p.2

def pushH256U64 (buf : ByteArray) (p : types.H256 × Std.U64) : ByteArray :=
  pushStdU64 (pushH256 buf p.1) p.2

/-- Encode a `Vec` as u32 length prefix + per-element serialiser. -/
def pushVec {α} (buf : ByteArray) (v : alloc.vec.Vec α)
    (pushElem : ByteArray → α → ByteArray) : ByteArray :=
  let buf := pushU32LE buf v.val.length.toUInt32
  v.val.foldl pushElem buf

/-- Encode `state_transition.Error` as a single little-endian u32 tag. -/
def pushStError (buf : ByteArray) (e : state_transition.Error) : ByteArray :=
  pushU32LE buf (match e with
    | .StateSlotIsNewer            => 0
    | .SlotMismatch                => 1
    | .ParentSlotIsNewer           => 2
    | .InvalidProposer             => 3
    | .InvalidParent               => 4
    | .NoValidators                => 5
    | .StateRootMismatch           => 6
    | .SlotGapTooLarge             => 7
    | .ZeroHashInJustificationRoots => 8)

/-- Encode the inner `core.result.Result Unit Error` with a 1-byte tag. -/
def pushInnerResult (buf : ByteArray) (r : core.result.Result Unit state_transition.Error) : ByteArray :=
  match r with
  | .Ok _  => buf.push 0
  | .Err e => pushStError (buf.push 1) e

/-- Encode the Aeneas outer `Result` with a 1-byte tag, invoking `encInner` on success. -/
def pushOuterResult {α} (buf : ByteArray) (r : Aeneas.Std.Result α)
    (encInner : ByteArray → α → ByteArray) : ByteArray :=
  match r with
  | .ok v  => encInner (buf.push 0) v
  | .fail _ => buf.push 1
  | .div   => buf.push 2

/-! ## State encoder (for returning updated state) -/

def pushBlockHeader (buf : ByteArray) (h : types.BlockHeader) : ByteArray :=
  let buf := pushStdU64 buf h.slot
  let buf := pushStdU64 buf h.proposer_index
  let buf := pushH256 buf h.parent_root
  let buf := pushH256 buf h.state_root
  pushH256 buf h.body_root

def pushChainConfig (buf : ByteArray) (c : types.ChainConfig) : ByteArray :=
  pushStdU64 buf c.genesis_time

def pushValidator (buf : ByteArray) (v : types.Validator) : ByteArray :=
  let buf := v.pubkey.val.foldl (fun b x => b.push (fromStdU8 x)) buf
  pushStdU64 buf v.index

def pushState (buf : ByteArray) (s : types.State) : ByteArray :=
  let buf := pushChainConfig buf s.config
  let buf := pushStdU64 buf s.slot
  let buf := pushBlockHeader buf s.latest_block_header
  let buf := pushCheckpoint buf s.latest_justified
  let buf := pushCheckpoint buf s.latest_finalized
  let buf := pushVec buf s.historical_block_hashes pushH256
  let buf := pushVec buf s.justified_slots pushBool
  let buf := pushVec buf s.validators pushValidator
  let buf := pushVec buf s.justifications_roots pushH256
  pushVec buf s.justifications_validators pushBool

/-! ## Fork choice input decoders -/

def readBlockEntry : D (types.H256 × (Std.U64 × types.H256)) := do
  let k   ← readH256
  let sl  ← readStdU64
  let par ← readH256
  D.pure (k, (sl, par))

def readAttEntry : D (Std.U64 × types.AttestationData) := do
  let idx ← readStdU64
  let d   ← readAttestationData
  D.pure (idx, d)

/-! ## Entry-point wrappers

Status byte in the first position of the returned ByteArray:
  0 = success (typed payload follows)
  1 = input decode failure (no further payload)
  2 = inner Aeneas `fail` (no further payload)
  3 = inner Aeneas `div`  (no further payload) -/

/-- state_transition wire input: `State` followed by `Block`. Output: status byte,
    then on status=0: inner-result (1-byte tag + optional u32 error) and the new
    State. -/
@[export consensus_state_transition_ffi]
def stateTransitionFFI (input : ByteArray) : ByteArray := Id.run do
  let cursor : Cursor := { data := input, pos := 0 }
  match readState cursor with
  | none => return ByteArray.empty.push 1
  | some (state, c1) =>
    match readBlock c1 with
    | none => return ByteArray.empty.push 1
    | some (block, _) =>
      match state_transition.state_transition state block with
      | .ok (inner, newState) =>
        let buf := ByteArray.empty.push 0
        let buf := pushInnerResult buf inner
        return pushState buf newState
      | .fail _ => return ByteArray.empty.push 2
      | .div    => return ByteArray.empty.push 3

/-- fork_choice wire input: start_root (32B) | u32 blocks_len | blocks[]
    | u32 attestations_len | attestations[] | min_score (u64). Output: status
    byte, then on status=0: head H256 + vec<(H256,u64)>. -/
@[export consensus_fork_choice_ffi]
def forkChoiceFFI (input : ByteArray) : ByteArray := Id.run do
  let cursor : Cursor := { data := input, pos := 0 }
  let mr := do
    let startRoot ← readH256
    let blocks    ← readVec readBlockEntry
    let atts      ← readVec readAttEntry
    let minScore  ← readStdU64
    D.pure (startRoot, blocks, atts, minScore)
  match mr cursor with
  | none => return ByteArray.empty.push 1
  | some ((startRoot, blocks, atts, minScore), _) =>
    match fork_choice.compute_lmd_ghost_head startRoot blocks atts minScore with
    | .ok (head, weights) =>
      let buf := ByteArray.empty.push 0
      let buf := pushH256 buf head
      return pushVec buf weights pushH256U64
    | .fail _ => return ByteArray.empty.push 2
    | .div    => return ByteArray.empty.push 3

end ConsensusLean4.Ffi
