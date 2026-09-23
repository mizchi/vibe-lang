import Std

set_option autoImplicit false

/-
Slice 2, step 1 of `docs/research/other-languages/borrowing-and-vectorization.md`:
the `borrow` parameter mode's write and escape check (A2), on the smallest
calculus that can show why each part of the rule is there.

**The calculus.** Straight-line, first-order, one function. Values are
integers, references to one-cell buffers (`Array[Int]` of length one, which is
all the aliasing argument needs), and pairs (any aggregate: a struct field, a
tuple, an enum payload). Statements bind a variable or write a buffer. There
is no call, no loop, no closure and no effect yet: each of those is a later
step, and each has a review finding waiting for it (A4's loop ω, A3's
closure callee, A1's effect row).

**The rule under test** is the closed-by-default taint of A2: a value is
borrow-derived if it is the parameter, or if any operand it was built from is
borrow-derived, unless it is an integer (the only buffer-free type here). A
borrow-derived value may be neither written through nor returned.

**The theorem** (`Fn.check_sound`) is T1 and T1′ for this calculus. When the
parameter is the only thing the function can reach (no globals and no other
parameters, which are exactly T1′'s premises), running an accepted function:
- leaves every buffer reachable from the argument unchanged, and
- returns a value that reaches none of them.

**The negative witnesses** (`Borrow/Examples.lean`) are the review findings,
one per broken checker, each with a concrete program that the broken
checker accepts and the real checker refuses, run to show the violation.
-/

namespace VibeFormal.Borrow

abbrev Var := Nat
abbrev Loc := Nat

/-- Runtime values. `pair` stands for every aggregate that can hold a buffer. -/
inductive Val where
  | int (n : Nat)
  | ref (l : Loc)
  | pair (a b : Val)
  deriving DecidableEq, Repr

/-- The buffers a value can reach. -/
def Val.locs : Val → List Loc
  | .int _ => []
  | .ref l => [l]
  | .pair a b => a.locs ++ b.locs

inductive Stmt where
  /-- `let x = n` -/
  | int (x : Var) (n : Nat)
  /-- `let x = y` -/
  | copy (x y : Var)
  /-- `let x = Array::make(1, n)`: a fresh buffer. -/
  | alloc (x : Var) (n : Nat)
  /-- `let x = (y, z)`: aggregate construction. -/
  | pair (x y z : Var)
  /-- `let x = y.0`: projection. -/
  | fst (x y : Var)
  /-- `let x = y.1` -/
  | snd (x y : Var)
  /-- `let x = Array::get(y, 0)`: an `Int`, so buffer-free. -/
  | read (x y : Var)
  /-- `Array::set(y, 0, n)`: a write through `y`. -/
  | write (y : Var) (n : Nat)
  deriving DecidableEq, Repr

/-- A function with one `borrow` parameter. -/
structure Fn where
  param : Var
  body : List Stmt
  ret : Var
  deriving Repr

def upd {α : Type} (f : Var → α) (x : Var) (a : α) : Var → α :=
  fun v => if v = x then a else f v

@[simp] theorem upd_same {α : Type} (f : Var → α) (x : Var) (a : α) :
    upd f x a x = a := by simp [upd]

@[simp] theorem upd_other {α : Type} (f : Var → α) {x v : Var} (a : α) (h : v ≠ x) :
    upd f x a v = f v := by simp [upd, h]

def updHeap (h : Loc → Nat) (l : Loc) (n : Nat) : Loc → Nat :=
  fun k => if k = l then n else h k

structure State where
  env : Var → Option Val
  heap : Loc → Nat
  next : Loc

/-! ## Semantics -/

def Stmt.step (s : State) : Stmt → Option State
  | .int x n => some { s with env := upd s.env x (some (.int n)) }
  | .copy x y =>
    match s.env y with
    | some v => some { s with env := upd s.env x (some v) }
    | none => none
  | .alloc x n =>
    some { env := upd s.env x (some (.ref s.next)),
           heap := updHeap s.heap s.next n,
           next := s.next + 1 }
  | .pair x y z =>
    match s.env y, s.env z with
    | some a, some b => some { s with env := upd s.env x (some (.pair a b)) }
    | _, _ => none
  | .fst x y =>
    match s.env y with
    | some (.pair a _) => some { s with env := upd s.env x (some a) }
    | _ => none
  | .snd x y =>
    match s.env y with
    | some (.pair _ b) => some { s with env := upd s.env x (some b) }
    | _ => none
  | .read x y =>
    match s.env y with
    | some (.ref l) => some { s with env := upd s.env x (some (.int (s.heap l))) }
    | _ => none
  | .write y n =>
    match s.env y with
    | some (.ref l) => some { s with heap := updHeap s.heap l n }
    | _ => none

def execStmts : State → List Stmt → Option State
  | s, [] => some s
  | s, st :: rest =>
    match st.step s with
    | some s' => execStmts s' rest
    | none => none

/-- Run `f` on argument `v`, in a heap where nothing below `next` is fresh. -/
def Fn.run (f : Fn) (v : Val) (heap : Loc → Nat) (next : Loc) : Option (State × Option Val) :=
  match execStmts { env := upd (fun _ => none) f.param (some v), heap, next } f.body with
  | some s => some (s, s.env f.ret)
  | none => none

/-! ## The checker -/

/-- Which variables currently hold a borrow-derived value. -/
abbrev Taint := Var → Bool

/-- A2's rule, closed by default. Only `int` and `read` produce a buffer-free
(`Int`) value; every other form inherits the taint of what it was built
from. -/
def Stmt.check (t : Taint) : Stmt → Option Taint
  | .int x _ => some (upd t x false)
  | .copy x y => some (upd t x (t y))
  | .alloc x _ => some (upd t x false)
  | .pair x y z => some (upd t x (t y || t z))
  | .fst x y => some (upd t x (t y))
  | .snd x y => some (upd t x (t y))
  | .read x _ => some (upd t x false)
  | .write y _ => if t y then none else some t

def checkStmts : Taint → List Stmt → Option Taint
  | t, [] => some t
  | t, st :: rest =>
    match st.check t with
    | some t' => checkStmts t' rest
    | none => none

/-- Accept `f` iff no statement writes through a borrow-derived value and the
result is not borrow-derived (the escape check). -/
def Fn.check (f : Fn) : Bool :=
  match checkStmts (upd (fun _ => false) f.param true) f.body with
  | some t => !t f.ret
  | none => false

/-! ## Soundness -/

def Reaches (P : List Loc) (v : Val) : Prop := ∃ l, l ∈ v.locs ∧ l ∈ P

theorem reaches_pair {P : List Loc} {a b : Val} :
    Reaches P (.pair a b) → Reaches P a ∨ Reaches P b := by
  rintro ⟨l, hl, hP⟩
  simp only [Val.locs, List.mem_append] at hl
  rcases hl with h | h
  · exact Or.inl ⟨l, h, hP⟩
  · exact Or.inr ⟨l, h, hP⟩

theorem reaches_pair_left {P : List Loc} {a b : Val} :
    Reaches P a → Reaches P (.pair a b) := by
  rintro ⟨l, hl, hP⟩
  exact ⟨l, by simp [Val.locs, hl], hP⟩

theorem reaches_pair_right {P : List Loc} {a b : Val} :
    Reaches P b → Reaches P (.pair a b) := by
  rintro ⟨l, hl, hP⟩
  exact ⟨l, by simp [Val.locs, hl], hP⟩

theorem not_reaches_int {P : List Loc} {n : Nat} : ¬ Reaches P (.int n) := by
  rintro ⟨l, hl, _⟩
  simp [Val.locs] at hl

/-- The invariant: every variable that can reach a borrowed buffer is
tainted, every borrowed buffer is older than the allocation frontier, and
every borrowed buffer still holds its original contents. -/
structure Inv (P : List Loc) (h0 : Loc → Nat) (t : Taint) (s : State) : Prop where
  tainted : ∀ x v, s.env x = some v → Reaches P v → t x = true
  old : ∀ l ∈ P, l < s.next
  frame : ∀ l ∈ P, s.heap l = h0 l

/-- Re-establish `tainted` after binding `x`, given that the new value is
covered by `t' x` and every other variable keeps its value and its taint. -/
theorem tainted_upd {P : List Loc} {t : Taint} {env : Var → Option Val}
    (inv : ∀ x v, env x = some v → Reaches P v → t x = true)
    (x : Var) (w : Val) (b : Bool) (hw : Reaches P w → b = true) :
    ∀ y v, upd env x (some w) y = some v → Reaches P v → upd t x b y = true := by
  intro y v hy hr
  by_cases h : y = x
  · subst h
    simp at hy
    subst hy
    simpa using hw hr
  · rw [upd_other _ _ h] at hy
    rw [upd_other _ _ h]
    exact inv y v hy hr

theorem Stmt.check_preserves {P : List Loc} {h0 : Loc → Nat} {t t' : Taint} {s s' : State}
    (st : Stmt) (hc : st.check t = some t') (hs : st.step s = some s')
    (inv : Inv P h0 t s) : Inv P h0 t' s' := by
  cases st with
  | int x n =>
    simp only [Stmt.check, Option.some.injEq] at hc
    simp only [Stmt.step, Option.some.injEq] at hs
    subst hc hs
    exact ⟨tainted_upd inv.tainted x _ false (fun h => absurd h not_reaches_int),
      inv.old, inv.frame⟩
  | copy x y =>
    simp only [Stmt.check, Option.some.injEq] at hc
    subst hc
    simp only [Stmt.step] at hs
    split at hs
    · rename_i v hv
      simp only [Option.some.injEq] at hs
      subst hs
      exact ⟨tainted_upd inv.tainted x v (t y) (fun hr => inv.tainted y v hv hr),
        inv.old, inv.frame⟩
    · simp at hs
  | alloc x n =>
    simp only [Stmt.check, Option.some.injEq] at hc
    simp only [Stmt.step, Option.some.injEq] at hs
    subst hc hs
    refine ⟨?_, ?_, ?_⟩
    · refine tainted_upd inv.tainted x _ false ?_
      rintro ⟨l, hl, hP⟩
      simp [Val.locs] at hl
      subst hl
      exact absurd (inv.old _ hP) (Nat.lt_irrefl _)
    · intro l hl
      exact Nat.lt_succ_of_lt (inv.old l hl)
    · intro l hl
      have hne : l ≠ s.next := Nat.ne_of_lt (inv.old l hl)
      simp [updHeap, hne, inv.frame l hl]
  | pair x y z =>
    simp only [Stmt.check, Option.some.injEq] at hc
    subst hc
    simp only [Stmt.step] at hs
    split at hs
    · rename_i a b ha hb
      simp only [Option.some.injEq] at hs
      subst hs
      refine ⟨tainted_upd inv.tainted x _ _ ?_, inv.old, inv.frame⟩
      intro hr
      rcases reaches_pair hr with h | h
      · simp [inv.tainted y a ha h]
      · simp [inv.tainted z b hb h]
    · simp at hs
  | fst x y =>
    simp only [Stmt.check, Option.some.injEq] at hc
    subst hc
    simp only [Stmt.step] at hs
    split at hs
    · rename_i a b hy
      simp only [Option.some.injEq] at hs
      subst hs
      exact ⟨tainted_upd inv.tainted x a (t y)
          (fun hr => inv.tainted y _ hy (reaches_pair_left hr)),
        inv.old, inv.frame⟩
    · simp at hs
  | snd x y =>
    simp only [Stmt.check, Option.some.injEq] at hc
    subst hc
    simp only [Stmt.step] at hs
    split at hs
    · rename_i a b hy
      simp only [Option.some.injEq] at hs
      subst hs
      exact ⟨tainted_upd inv.tainted x b (t y)
          (fun hr => inv.tainted y _ hy (reaches_pair_right hr)),
        inv.old, inv.frame⟩
    · simp at hs
  | read x y =>
    simp only [Stmt.check, Option.some.injEq] at hc
    subst hc
    simp only [Stmt.step] at hs
    split at hs
    · simp only [Option.some.injEq] at hs
      subst hs
      exact ⟨tainted_upd inv.tainted x _ false (fun h => absurd h not_reaches_int),
        inv.old, inv.frame⟩
    · simp at hs
  | write y n =>
    simp only [Stmt.check] at hc
    split at hc
    · simp at hc
    · rename_i hty
      simp only [Option.some.injEq] at hc
      subst hc
      simp only [Stmt.step] at hs
      split at hs
      · rename_i l hy
        simp only [Option.some.injEq] at hs
        subst hs
        refine ⟨inv.tainted, inv.old, ?_⟩
        intro k hk
        have hne : k ≠ l := by
          intro heq
          subst heq
          exact hty (inv.tainted y _ hy ⟨k, by simp [Val.locs], hk⟩)
        simp [updHeap, hne, inv.frame k hk]
      · simp at hs

theorem checkStmts_preserves {P : List Loc} {h0 : Loc → Nat} :
    ∀ (body : List Stmt) {t t' : Taint} {s s' : State},
      checkStmts t body = some t' → execStmts s body = some s' →
      Inv P h0 t s → Inv P h0 t' s'
  | [], t, t', s, s', hc, hs, inv => by
    simp only [checkStmts, Option.some.injEq] at hc
    simp only [execStmts, Option.some.injEq] at hs
    subst hc hs
    exact inv
  | st :: rest, t, t', s, s', hc, hs, inv => by
    simp only [checkStmts] at hc
    split at hc
    · rename_i tm htm
      simp only [execStmts] at hs
      split at hs
      · rename_i sm hsm
        exact checkStmts_preserves rest hc hs (st.check_preserves htm hsm inv)
      · simp at hs
    · simp at hc

/-- **T1 and T1′ for the core calculus.** If `f` is accepted, then running it
on argument `v` (with every buffer `v` reaches older than the allocation
frontier) leaves each of those buffers unchanged and returns a value that
reaches none of them. -/
theorem Fn.check_sound (f : Fn) (v : Val) (heap : Loc → Nat) (next : Loc)
    (hchk : f.check = true) (hold : ∀ l ∈ v.locs, l < next)
    {s : State} {r : Option Val} (hrun : f.run v heap next = some (s, r)) :
    (∀ l ∈ v.locs, s.heap l = heap l) ∧
    (∀ w, r = some w → ∀ l ∈ w.locs, l ∉ v.locs) := by
  unfold Fn.check at hchk
  split at hchk
  · rename_i t ht
    unfold Fn.run at hrun
    split at hrun
    · rename_i s1 hs1
      simp only [Option.some.injEq, Prod.mk.injEq] at hrun
      obtain ⟨rfl, rfl⟩ := hrun
      have inv0 : Inv v.locs heap (upd (fun _ => false) f.param true)
          { env := upd (fun _ => none) f.param (some v), heap, next } := by
        refine ⟨?_, hold, fun _ _ => rfl⟩
        intro x w hx _
        by_cases h : x = f.param
        · subst h; simp
        · simp only [upd_other _ _ h] at hx; simp at hx
      have inv := checkStmts_preserves f.body ht hs1 inv0
      refine ⟨inv.frame, ?_⟩
      intro w hw l hl hP
      have := inv.tainted f.ret w hw ⟨l, hl, hP⟩
      simp [this] at hchk
    · simp at hrun
  · simp at hchk

end VibeFormal.Borrow
