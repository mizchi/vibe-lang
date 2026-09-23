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
3. violates T1/T1′ when run: the borrowed buffer changes, or the result
   reaches it.

Point 3 is what makes these witnesses rather than disagreements: the
soundness theorem forbids exactly what these runs do, so a checker that
accepts them cannot satisfy it. Every fact is closed by `decide`, so these
are executed rather than asserted.
-/

namespace VibeFormal.Borrow

/-- A checker assembled from a per-statement rule and a switch for the escape
check. `Fn.check` is `checkWith Stmt.check true`. -/
def checkStmtsWith (rule : Taint → Stmt → Option Taint) : Taint → List Stmt → Option Taint
  | t, [] => some t
  | t, st :: rest =>
    match rule t st with
    | some t' => checkStmtsWith rule t' rest
    | none => none

def checkWith (rule : Taint → Stmt → Option Taint) (escape : Bool) (f : Fn) : Bool :=
  match checkStmtsWith rule (upd (fun _ => false) f.param true) f.body with
  | some t => !(escape && t f.ret)
  | none => false

/-- The real rule, reassembled, agrees with `Fn.check` on every witness below
(checked per program, since the two are the same definition up to argument
order). -/
def realRule (t : Taint) (st : Stmt) : Option Taint := st.check t

/-! ### Broken rules -/

/-- Only the parameter's own NAME is tainted: nothing derived from it is. -/
def nameOnlyRule (t : Taint) : Stmt → Option Taint
  | .write y _ => if t y then none else some t
  | .int x _ | .copy x _ | .alloc x _ | .pair x _ _ | .fst x _ | .snd x _ | .read x _ =>
    some (upd t x false)

/-- Taint does not flow into an aggregate built from a borrowed value. -/
def noAggregateRule (t : Taint) : Stmt → Option Taint
  | .pair x _ _ => some (upd t x false)
  | st => st.check t

/-- Taint does not flow out of a projection. -/
def noProjectionRule (t : Taint) : Stmt → Option Taint
  | .fst x _ => some (upd t x false)
  | .snd x _ => some (upd t x false)
  | st => st.check t

/-! ### Programs. Variable 0 is always the `borrow` parameter. -/

/-- `let q = p; Array::set(q, 0, 7)` -/
def writeThroughCopy : Fn := { param := 0, body := [.copy 1 0, .write 1 7], ret := 1 }

/-- `let h = (p, p); let b = h.0; Array::set(b, 0, 7)` -/
def writeThroughAggregate : Fn :=
  { param := 0, body := [.pair 1 0 0, .fst 2 1, .write 2 7, .int 3 0], ret := 3 }

/-- `fn f(borrow h: Holder) { let b = h.buf; Array::set(b, 0, 7) }` -/
def writeThroughProjection : Fn :=
  { param := 0, body := [.fst 1 0, .write 1 7, .int 2 0], ret := 2 }

/-- `fn f(borrow xs) -> Array[Int] { xs }` -/
def returnTheBorrow : Fn := { param := 0, body := [], ret := 0 }

/-- Positive control: read the borrow, write only a fresh buffer, return an
`Int` and the fresh buffer in a pair. Every rule must accept this, or the
witnesses above could be passing for the wrong reason. -/
def readAndWriteFresh : Fn :=
  { param := 0,
    body := [.fst 1 0, .read 2 1, .alloc 3 0, .write 3 9, .pair 4 2 3],
    ret := 4 }

/-! ### Runs. The argument is buffer `0` (or a pair holding it); the heap
starts at zero everywhere and the allocation frontier is `1`. -/

def heap0 : Loc → Nat := fun _ => 0

/-- The borrowed buffer's contents after running `f` on `arg`. -/
def borrowedAfter (f : Fn) (arg : Val) : Option Nat :=
  (f.run arg heap0 1).map (fun p => p.1.heap 0)

/-- Does the result reach the borrowed buffer? -/
def resultReachesBorrow (f : Fn) (arg : Val) : Option Bool :=
  (f.run arg heap0 1).map (fun p => match p.2 with
    | some w => w.locs.contains 0
    | none => false)

/-! ### Witnesses -/

theorem nameOnly_admits_write_through_copy :
    checkWith nameOnlyRule true writeThroughCopy = true ∧
    writeThroughCopy.check = false ∧
    borrowedAfter writeThroughCopy (.ref 0) = some 7 := by decide

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

/-! ### Positive control -/

theorem every_rule_accepts_the_control :
    readAndWriteFresh.check = true ∧
    checkWith realRule true readAndWriteFresh = true ∧
    checkWith nameOnlyRule true readAndWriteFresh = true ∧
    checkWith noAggregateRule true readAndWriteFresh = true ∧
    checkWith noProjectionRule true readAndWriteFresh = true ∧
    borrowedAfter readAndWriteFresh (.pair (.ref 0) (.int 1)) = some 0 ∧
    resultReachesBorrow readAndWriteFresh (.pair (.ref 0) (.int 1)) = some false := by
  decide

end VibeFormal.Borrow
