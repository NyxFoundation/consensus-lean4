-- Implementations of the external functions that Aeneas cannot translate.
-- Originally stubbed with `axiom` in FunsExternal_Template.lean; these defs make
-- Funs.lean computable so the library can be compiled and called via FFI.
-- `FunsExternal_Template.lean` is refreshed on every Aeneas run and remains the
-- canonical signature reference — diff it against this file to catch upstream
-- signature drift.
import Aeneas
import ConsensusLean4.Types
open Aeneas Aeneas.Std Result ControlFlow Error
set_option linter.dupNamespace false
set_option linter.hashCommand false
set_option linter.unusedVariables false

set_option maxHeartbeats 1000000
open ethlambda_verification

/-- [core::cmp::{core::cmp::PartialEq<core::cmp::Ordering> for core::cmp::Ordering}::eq] -/
@[rust_fun
  "core::cmp::{core::cmp::PartialEq<core::cmp::Ordering, core::cmp::Ordering>}::eq"]
def core.cmp.Ordering.Insts.CoreCmpPartialEqOrdering.eq
  (a b : Ordering) : Result Bool :=
  ok (a == b)

/-- [core::result::{core::ops::try_trait::Try<T, core::result::Result<core::convert::Infallible, E>> for core::result::Result<T, E>}::branch]
    Desugaring of the `?` operator on `Result<T,E>`: split into the `ControlFlow`
    carrier used by the generated code. -/
@[rust_fun
  "core::result::{core::ops::try_trait::Try<core::result::Result<@T, @E>, @T, core::result::Result<core::convert::Infallible, @E>>}::branch"]
def core.result.Result.Insts.CoreOpsTry_traitTryTResultInfallibleE.branch
  {T : Type} {E : Type} (r : core.result.Result T E) :
  Result (core.ops.control_flow.ControlFlow
    (core.result.Result core.convert.Infallible E) T) :=
  match r with
  | core.result.Result.Ok x =>
    ok (core.ops.control_flow.ControlFlow.Continue x)
  | core.result.Result.Err e =>
    ok (core.ops.control_flow.ControlFlow.Break (core.result.Result.Err e))

/-- [core::result::{core::ops::try_trait::FromResidual<core::result::Result<core::convert::Infallible, E>> for core::result::Result<T, F>}::from_residual]
    Companion to `branch`: lift a residual `Err` back into the outer `Result<T,F>`
    via the supplied `From F E` instance. The `Ok` case is unreachable because
    `Infallible` is uninhabited. -/
@[rust_fun
  "core::result::{core::ops::try_trait::FromResidual<core::result::Result<@T, @F>, core::result::Result<core::convert::Infallible, @E>>}::from_residual"]
def core.result.Result.Insts.CoreOpsTry_traitFromResidualResultInfallibleE.from_residual
  (T : Type) {E : Type} {F : Type} (convertFromInst : core.convert.From F E) :
  core.result.Result core.convert.Infallible E → Result (core.result.Result T F)
  | core.result.Result.Ok x => nomatch x
  | core.result.Result.Err e => do
    let f ← convertFromInst.from_ e
    ok (core.result.Result.Err f)

/-- [alloc::vec::{alloc::vec::Vec<T>}::clear] -/
@[rust_fun "alloc::vec::{alloc::vec::Vec<@T>}::clear"]
def alloc.vec.Vec.clear
  {T : Type} (A : Type) (_v : alloc.vec.Vec T) : Result (alloc.vec.Vec T) :=
  ok (alloc.vec.Vec.new T)

/-- [alloc::vec::{alloc::vec::Vec<T>}::is_empty] -/
@[rust_fun "alloc::vec::{alloc::vec::Vec<@T>}::is_empty"]
def alloc.vec.Vec.is_empty
  {T : Type} (A : Type) (v : alloc.vec.Vec T) : Result Bool :=
  ok v.val.isEmpty
