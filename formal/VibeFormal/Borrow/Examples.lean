import VibeFormal.Borrow.Core

set_option autoImplicit false

/-
Negative witnesses and positive controls for `Borrow/Core.lean`.

Each broken checker below is one rule that review of the proposal found
missing (see the "Why the model has to come first" list in
`docs/research/other-languages/borrowing-and-vectorization.md`). For each one
there is a concrete program that:
1. the broken checker ACCEPTS,
2. the real checker (`Fn.check`) REJECTS, and
3. violates what `Fn.check_sound` guarantees when run: the borrowed buffer is
   written, or the result reaches it.

Point 3 is what makes these witnesses rather than disagreements: the
soundness theorem forbids exactly what these runs do, so a checker that
accepts them cannot satisfy it. Every fact is closed by `decide`, so these
are executed rather than asserted.

The last group goes the other way: it shows that the buffer-free exemption is
applied by TYPE, so projecting an `Int` field out of a borrowed aggregate is
accepted, where a checker without the exemption refuses a safe program.
-/

namespace VibeFormal.Borrow

/-- A checker assembled from a per-statement rule and a switch for the escape
check. `Fn.check` is `checkWith Stmt.check true`. -/
def checkStmtsWith (rule : CState → Stmt → Option CState) : CState → List Stmt → Option CState
  | c, [] => some c
  | c, st :: rest =>
    match rule c st with
    | some c' => checkStmtsWith rule c' rest
    | none => none

def checkWith (rule : CState → Stmt → Option CState) (escape : Bool) (f : Fn) : Bool :=
  match checkStmtsWith rule f.initCheck f.body with
  | some c => !(escape && c.taint f.ret)
  | none => false

/-- The real rule, reassembled. -/
def realRule (c : CState) (st : Stmt) : Option CState := st.check c

/-! ### Broken rules. Each keeps the real typing and drops one taint flow. -/

/-- The variable a statement binds, if any. -/
def Stmt.defines : Stmt → Option Var
  | .int x _ | .copy x _ | .alloc x _ | .pair x _ _ | .fst x _ | .snd x _ | .read x _ => some x
  | .write _ _ => none

/-- Run the real rule, then forget the taint of what `st` binds whenever
`forget st` holds. -/
def forgetting (forget : Stmt → Bool) (c : CState) (st : Stmt) : Option CState :=
  (st.check c).map fun c' =>
    match forget st, st.defines with
    | true, some x => { c' with taint := upd c'.taint x false }
    | _, _ => c'

/-- Only the parameter's own NAME is tainted: nothing derived from it is. -/
def nameOnlyRule : CState → Stmt → Option CState := forgetting fun _ => true

/-- Taint does not flow into an aggregate built from a borrowed value. -/
def noAggregateRule : CState → Stmt → Option CState :=
  forgetting fun | .pair .. => true | _ => false

/-- Taint does not flow out of a projection. -/
def noProjectionRule : CState → Stmt → Option CState :=
  forgetting fun | .fst .. | .snd .. => true | _ => false

/-- No buffer-free exemption: taint flows by operand alone, whatever the
result type. Sound, but it refuses safe programs. -/
def noExemptionRule (c : CState) (st : Stmt) : Option CState :=
  (st.check c).map fun c' =>
    match st with
    | .copy x y | .fst x y | .snd x y => { c' with taint := upd c'.taint x (c.taint y) }
    | .pair x y z => { c' with taint := upd c'.taint x (c.taint y || c.taint z) }
    | _ => c'

/-! ### Programs. Variable 0 is always the `borrow` parameter. -/

/-- `let q = p; Array::set(q, 0, 7)` -/
def writeThroughCopy : Fn :=
  { param := 0, paramTy := .buf, body := [.copy 1 0, .write 1 7], ret := 1 }

/-- `let q = p; Array::set(q, 0, 7); Array::set(q, 0, 0)`: the final heap is
the initial one, so only the write log shows the violation. -/
def writeAndRestore : Fn :=
  { param := 0, paramTy := .buf, body := [.copy 1 0, .write 1 7, .write 1 0, .int 2 0],
    ret := 2 }

/-- `let h = (p, p); let b = h.0; Array::set(b, 0, 7)` -/
def writeThroughAggregate : Fn :=
  { param := 0, paramTy := .buf, body := [.pair 1 0 0, .fst 2 1, .write 2 7, .int 3 0],
    ret := 3 }

/-- `fn f(borrow h: Holder) { let b = h.buf; Array::set(b, 0, 7) }` -/
def writeThroughProjection : Fn :=
  { param := 0, paramTy := .pair .buf .int, body := [.fst 1 0, .write 1 7, .int 2 0],
    ret := 2 }

/-- `fn f(borrow xs) -> Array[Int] { xs }` -/
def returnTheBorrow : Fn := { param := 0, paramTy := .buf, body := [], ret := 0 }

/-- `fn f(borrow h: Holder) -> Int { h.n }`: the field is an `Int`, so the
result is buffer-free and may be returned. -/
def returnIntField : Fn :=
  { param := 0, paramTy := .pair .buf .int, body := [.snd 1 0], ret := 1 }

/-- Positive control: read the borrow, write only a fresh buffer, return an
`Int` and the fresh buffer in a pair. Every rule must accept this, or the
witnesses above could be passing for the wrong reason. -/
def readAndWriteFresh : Fn :=
  { param := 0, paramTy := .pair .buf .int,
    body := [.fst 1 0, .read 2 1, .alloc 3 0, .write 3 9, .pair 4 2 3],
    ret := 4 }

/-! ### Runs. The argument is buffer `0` (or a pair holding it); the heap
starts at zero everywhere and the allocation frontier is `1`. -/

def heap0 : Loc → Nat := fun _ => 0

/-- The borrowed buffer's contents after running `f` on `arg`. -/
def borrowedAfter (f : Fn) (arg : Val) : Option Nat :=
  (f.run arg heap0 1).map (fun p => p.1.heap 0)

/-- Was the borrowed buffer written at any point of the run? -/
def borrowedWritten (f : Fn) (arg : Val) : Option Bool :=
  (f.run arg heap0 1).map (fun p => p.1.written.contains 0)

/-- Does the result reach the borrowed buffer? -/
def resultReachesBorrow (f : Fn) (arg : Val) : Option Bool :=
  (f.run arg heap0 1).map (fun p => match p.2 with
    | some w => w.locs.contains 0
    | none => false)

/-- The result of running `f` on `arg`. -/
def resultOf (f : Fn) (arg : Val) : Option (Option Val) :=
  (f.run arg heap0 1).map (·.2)

/-! ### Witnesses -/

theorem nameOnly_admits_write_through_copy :
    checkWith nameOnlyRule true writeThroughCopy = true ∧
    writeThroughCopy.check = false ∧
    borrowedAfter writeThroughCopy (.ref 0) = some 7 := by decide

/-- Why the theorem speaks about the write log: a final-heap frame alone is
satisfied by this run. -/
theorem nameOnly_admits_write_and_restore :
    checkWith nameOnlyRule true writeAndRestore = true ∧
    writeAndRestore.check = false ∧
    borrowedAfter writeAndRestore (.ref 0) = some 0 ∧
    borrowedWritten writeAndRestore (.ref 0) = some true := by decide

theorem noAggregate_admits_write_through_aggregate :
    checkWith noAggregateRule true writeThroughAggregate = true ∧
    writeThroughAggregate.check = false ∧
    borrowedAfter writeThroughAggregate (.ref 0) = some 7 := by decide

theorem noProjection_admits_write_through_projection :
    checkWith noProjectionRule true writeThroughProjection = true ∧
    writeThroughProjection.check = false ∧
    borrowedAfter writeThroughProjection (.pair (.ref 0) (.int 1)) = some 7 := by decide

theorem noEscape_admits_return :
    checkWith realRule false returnTheBorrow = true ∧
    returnTheBorrow.check = false ∧
    resultReachesBorrow returnTheBorrow (.ref 0) = some true := by decide

/-! ### The exemption applies to projections -/

theorem projection_of_int_field_is_exempt :
    returnIntField.check = true ∧
    checkWith noExemptionRule true returnIntField = false ∧
    resultOf returnIntField (.pair (.ref 0) (.int 5)) = some (some (.int 5)) := by decide

/-! ### Positive control -/

theorem every_rule_accepts_the_control :
    readAndWriteFresh.check = true ∧
    checkWith realRule true readAndWriteFresh = true ∧
    checkWith nameOnlyRule true readAndWriteFresh = true ∧
    checkWith noAggregateRule true readAndWriteFresh = true ∧
    checkWith noProjectionRule true readAndWriteFresh = true ∧
    checkWith noExemptionRule true readAndWriteFresh = true ∧
    borrowedAfter readAndWriteFresh (.pair (.ref 0) (.int 1)) = some 0 ∧
    borrowedWritten readAndWriteFresh (.pair (.ref 0) (.int 1)) = some false ∧
    resultReachesBorrow readAndWriteFresh (.pair (.ref 0) (.int 1)) = some false := by
  decide

end VibeFormal.Borrow
