import Std

set_option autoImplicit false

/-
Slice 2, step 1 of `docs/research/other-languages/borrowing-and-vectorization.md`:
the `borrow` parameter mode's write and escape check (A2), on the smallest
calculus that can show why each part of the rule is there.

**The calculus.** Straight-line, first-order, one function. Values are
integers, references to one-cell buffers (`Array[Int]` of length one, which is
all the aliasing argument needs), and pairs (any aggregate: a struct field, a
tuple, an enum payload). Types are `Int`, `Buf` and pairs of types; a type is
buffer-free when no `Buf` occurs in it, which is the allow-list the proposal
asks for. Statements bind a variable or write a buffer. There is no call, no
loop, no closure and no effect yet: each of those is a later step, and each
has a review finding waiting for it (A4's loop ω, A3's closure callee, A1's
effect row).

**The rule under test** is the closed-by-default taint of A2: a value is
borrow-derived if it is the parameter, or if any operand it was built from is
borrow-derived, unless its TYPE is buffer-free. The exemption is by type, so a
projection of an `Int` field out of a borrowed aggregate is exempt just as a
`read` is. A borrow-derived value may be neither written through nor returned.

**The theorem** (`Fn.check_sound`), when the parameter is the only thing the
function can reach (no globals and no other parameters, which are exactly
T1′'s premises), says that running an accepted function on a well-typed
argument:
- never writes a buffer reachable from the argument, at ANY point of the run
  (every write is logged in `State.written`, so a write that is later undone
  still counts);
- leaves every such buffer with its original contents (the frame part of T1′);
- returns a value that reaches none of them (no retain).

**What it does not claim.** The model has no reference counts, so T1's "RC
unchanged" conjunct is not proved here; neither is anything about calls,
loops, closures, effects, `mut` or `consume`.

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

/-- Static types. -/
inductive Ty where
  | int
  | buf
  | pair (a b : Ty)
  deriving DecidableEq, Repr

/-- The buffer-free allow-list: a type is buffer-free iff no `buf` occurs in
it. -/
def Ty.bufferFree : Ty → Bool
  | .int => true
  | .buf => false
  | .pair a b => a.bufferFree && b.bufferFree

inductive HasTy : Val → Ty → Prop where
  | int (n : Nat) : HasTy (.int n) .int
  | ref (l : Loc) : HasTy (.ref l) .buf
  | pair {a b : Val} {A B : Ty} : HasTy a A → HasTy b B → HasTy (.pair a b) (.pair A B)

/-- What makes the exemption sound: a value of a buffer-free type reaches no
buffer. -/
theorem HasTy.locs_nil {v : Val} {T : Ty} (h : HasTy v T) (bf : T.bufferFree = true) :
    v.locs = [] := by
  induction h with
  | int n => rfl
  | ref l => simp [Ty.bufferFree] at bf
  | pair _ _ iha ihb =>
    simp only [Ty.bufferFree, Bool.and_eq_true] at bf
    simp [Val.locs, iha bf.1, ihb bf.2]

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

/-- A function with one `borrow` parameter of type `paramTy`. -/
structure Fn where
  param : Var
  paramTy : Ty
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

/-- `written` logs every buffer written, most recent first, so the theorem
can speak about the whole run and not only its final heap. -/
structure State where
  env : Var → Option Val
  heap : Loc → Nat
  next : Loc
  written : List Loc

/-! ## Semantics -/

def Stmt.step (s : State) : Stmt → Option State
  | .int x n => some { s with env := upd s.env x (some (.int n)) }
  | .copy x y =>
    match s.env y with
    | some v => some { s with env := upd s.env x (some v) }
    | none => none
  | .alloc x n =>
    some { s with env := upd s.env x (some (.ref s.next)),
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
    | some (.ref l) => some { s with heap := updHeap s.heap l n, written := l :: s.written }
    | _ => none

def execStmts : State → List Stmt → Option State
  | s, [] => some s
  | s, st :: rest =>
    match st.step s with
    | some s' => execStmts s' rest
    | none => none

/-- Run `f` on argument `v`, in a heap where nothing below `next` is fresh. -/
def Fn.run (f : Fn) (v : Val) (heap : Loc → Nat) (next : Loc) : Option (State × Option Val) :=
  match execStmts { env := upd (fun _ => none) f.param (some v), heap, next, written := [] }
      f.body with
  | some s => some (s, s.env f.ret)
  | none => none

/-! ## The checker -/

/-- Which variables currently hold a borrow-derived value. -/
abbrev Taint := Var → Bool

/-- The checker's state: each variable's type and whether it is
borrow-derived. -/
structure CState where
  ty : Var → Option Ty
  taint : Taint

/-- Bind `x : T`, built from operands whose taint is `src`. A buffer-free
type is never tainted: that is the whole exemption, applied by type. -/
def CState.bind (c : CState) (x : Var) (T : Ty) (src : Bool) : CState :=
  { ty := upd c.ty x (some T), taint := upd c.taint x (src && !T.bufferFree) }

/-- A2's rule, closed by default: every form inherits the taint of what it
was built from, unless its result type is buffer-free. -/
def Stmt.check (c : CState) : Stmt → Option CState
  | .int x _ => some (c.bind x .int false)
  | .copy x y =>
    match c.ty y with
    | some T => some (c.bind x T (c.taint y))
    | none => none
  | .alloc x _ => some (c.bind x .buf false)
  | .pair x y z =>
    match c.ty y, c.ty z with
    | some A, some B => some (c.bind x (.pair A B) (c.taint y || c.taint z))
    | _, _ => none
  | .fst x y =>
    match c.ty y with
    | some (.pair A _) => some (c.bind x A (c.taint y))
    | _ => none
  | .snd x y =>
    match c.ty y with
    | some (.pair _ B) => some (c.bind x B (c.taint y))
    | _ => none
  | .read x y =>
    match c.ty y with
    | some .buf => some (c.bind x .int false)
    | _ => none
  | .write y _ =>
    match c.ty y with
    | some .buf => if c.taint y then none else some c
    | _ => none

def checkStmts : CState → List Stmt → Option CState
  | c, [] => some c
  | c, st :: rest =>
    match st.check c with
    | some c' => checkStmts c' rest
    | none => none

/-- The checker's state on entry: only the parameter is bound, and it is
borrow-derived unless its type is buffer-free. -/
def Fn.initCheck (f : Fn) : CState :=
  CState.bind { ty := fun _ => none, taint := fun _ => false } f.param f.paramTy true

/-- Accept `f` iff it is well typed, no statement writes through a
borrow-derived value, and the result is not borrow-derived (the escape
check). -/
def Fn.check (f : Fn) : Bool :=
  match checkStmts f.initCheck f.body with
  | some c => !c.taint f.ret
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

/-- A value that reaches a buffer does not have a buffer-free type. -/
theorem not_bufferFree_of_reaches {P : List Loc} {v : Val} {T : Ty}
    (h : HasTy v T) (hr : Reaches P v) : T.bufferFree = false := by
  cases hbf : T.bufferFree
  · rfl
  · obtain ⟨l, hl, _⟩ := hr
    simp [h.locs_nil hbf] at hl

/-- The invariant: every variable is well typed, every variable that can
reach a borrowed buffer is tainted, every borrowed buffer is older than the
allocation frontier, no borrowed buffer has been written, and every borrowed
buffer still holds its original contents. -/
structure Inv (P : List Loc) (h0 : Loc → Nat) (c : CState) (s : State) : Prop where
  typed : ∀ x v, s.env x = some v → ∃ T, c.ty x = some T ∧ HasTy v T
  tainted : ∀ x v, s.env x = some v → Reaches P v → c.taint x = true
  old : ∀ l ∈ P, l < s.next
  untouched : ∀ l ∈ s.written, l ∉ P
  frame : ∀ l ∈ P, s.heap l = h0 l

theorem Inv.typeOf {P : List Loc} {h0 : Loc → Nat} {c : CState} {s : State}
    (inv : Inv P h0 c s) {y : Var} {v : Val} {T : Ty}
    (hv : s.env y = some v) (hT : c.ty y = some T) : HasTy v T := by
  obtain ⟨U, hU, hvU⟩ := inv.typed y v hv
  rw [hT] at hU
  cases hU
  exact hvU

/-- Binding `x := w : T` preserves `typed` and `tainted`, provided the source
taint `src` covers `w` whenever `w` reaches a borrowed buffer. -/
theorem bind_typed_tainted {P : List Loc} {c : CState} {env : Var → Option Val}
    (hty : ∀ x v, env x = some v → ∃ T, c.ty x = some T ∧ HasTy v T)
    (htn : ∀ x v, env x = some v → Reaches P v → c.taint x = true)
    (x : Var) (w : Val) (T : Ty) (src : Bool) (hw : HasTy w T)
    (hsrc : Reaches P w → src = true) :
    (∀ y v, upd env x (some w) y = some v → ∃ U, (c.bind x T src).ty y = some U ∧ HasTy v U) ∧
    (∀ y v, upd env x (some w) y = some v → Reaches P v →
      (c.bind x T src).taint y = true) := by
  constructor
  · intro y v hy
    by_cases h : y = x
    · subst h
      simp at hy
      subst hy
      exact ⟨T, by simp [CState.bind], hw⟩
    · simp only [upd_other _ _ h] at hy
      simpa [CState.bind, upd_other _ _ h] using hty y v hy
  · intro y v hy hr
    by_cases h : y = x
    · subst h
      simp at hy
      subst hy
      simp [CState.bind, hsrc hr, not_bufferFree_of_reaches hw hr]
    · simp only [upd_other _ _ h] at hy
      simpa [CState.bind, upd_other _ _ h] using htn y v hy hr

theorem Inv.bind {P : List Loc} {h0 : Loc → Nat} {c : CState} {s : State}
    (inv : Inv P h0 c s) (x : Var) (w : Val) (T : Ty) (src : Bool) (hw : HasTy w T)
    (hsrc : Reaches P w → src = true) :
    Inv P h0 (c.bind x T src) { s with env := upd s.env x (some w) } := by
  obtain ⟨h1, h2⟩ := bind_typed_tainted inv.typed inv.tainted x w T src hw hsrc
  exact ⟨h1, h2, inv.old, inv.untouched, inv.frame⟩

theorem Stmt.check_preserves {P : List Loc} {h0 : Loc → Nat} {c c' : CState} {s s' : State}
    (st : Stmt) (hc : st.check c = some c') (hs : st.step s = some s')
    (inv : Inv P h0 c s) : Inv P h0 c' s' := by
  cases st with
  | int x n =>
    simp only [Stmt.check, Option.some.injEq] at hc
    simp only [Stmt.step, Option.some.injEq] at hs
    subst hc hs
    exact inv.bind x _ .int false (.int n) (fun hr => by
      obtain ⟨l, hl, _⟩ := hr; simp [Val.locs] at hl)
  | copy x y =>
    simp only [Stmt.check] at hc
    split at hc
    · rename_i T hT
      simp only [Option.some.injEq] at hc
      subst hc
      simp only [Stmt.step] at hs
      split at hs
      · rename_i v hv
        simp only [Option.some.injEq] at hs
        subst hs
        exact inv.bind x v T _ (inv.typeOf hv hT) (fun hr => inv.tainted y v hv hr)
      · simp at hs
    · simp at hc
  | alloc x n =>
    simp only [Stmt.check, Option.some.injEq] at hc
    simp only [Stmt.step, Option.some.injEq] at hs
    subst hc hs
    obtain ⟨h1, h2⟩ := bind_typed_tainted inv.typed inv.tainted x (.ref s.next) .buf false
      (.ref _) (by
        rintro ⟨l, hl, hP⟩
        simp [Val.locs] at hl
        subst hl
        exact absurd (inv.old _ hP) (Nat.lt_irrefl _))
    refine ⟨h1, h2, ?_, inv.untouched, ?_⟩
    · intro l hl
      exact Nat.lt_succ_of_lt (inv.old l hl)
    · intro l hl
      have hne : l ≠ s.next := Nat.ne_of_lt (inv.old l hl)
      simp [updHeap, hne, inv.frame l hl]
  | pair x y z =>
    simp only [Stmt.check] at hc
    split at hc
    · rename_i A B hA hB
      simp only [Option.some.injEq] at hc
      subst hc
      simp only [Stmt.step] at hs
      split at hs
      · rename_i a b ha hb
        simp only [Option.some.injEq] at hs
        subst hs
        refine inv.bind x _ _ _ (.pair (inv.typeOf ha hA) (inv.typeOf hb hB)) ?_
        intro hr
        rcases reaches_pair hr with h | h
        · simp [inv.tainted y a ha h]
        · simp [inv.tainted z b hb h]
      · simp at hs
    · simp at hc
  | fst x y =>
    simp only [Stmt.check] at hc
    split at hc
    · rename_i A B hT
      simp only [Option.some.injEq] at hc
      subst hc
      simp only [Stmt.step] at hs
      split at hs
      · rename_i a b hy
        simp only [Option.some.injEq] at hs
        subst hs
        have hab := inv.typeOf hy hT
        cases hab with
        | pair ha _ =>
          exact inv.bind x a A _ ha (fun hr => inv.tainted y _ hy (reaches_pair_left hr))
      · simp at hs
    · simp at hc
  | snd x y =>
    simp only [Stmt.check] at hc
    split at hc
    · rename_i A B hT
      simp only [Option.some.injEq] at hc
      subst hc
      simp only [Stmt.step] at hs
      split at hs
      · rename_i a b hy
        simp only [Option.some.injEq] at hs
        subst hs
        have hab := inv.typeOf hy hT
        cases hab with
        | pair _ hb =>
          exact inv.bind x b B _ hb (fun hr => inv.tainted y _ hy (reaches_pair_right hr))
      · simp at hs
    · simp at hc
  | read x y =>
    simp only [Stmt.check] at hc
    split at hc
    · simp only [Option.some.injEq] at hc
      subst hc
      simp only [Stmt.step] at hs
      split at hs
      · simp only [Option.some.injEq] at hs
        subst hs
        exact inv.bind x _ .int false (.int _) (fun hr => by
          obtain ⟨l, hl, _⟩ := hr; simp [Val.locs] at hl)
      · simp at hs
    · simp at hc
  | write y n =>
    simp only [Stmt.check] at hc
    split at hc
    · split at hc
      · simp at hc
      · rename_i hty
        simp only [Option.some.injEq] at hc
        subst hc
        simp only [Stmt.step] at hs
        split at hs
        · rename_i l hy
          simp only [Option.some.injEq] at hs
          subst hs
          have hl : l ∉ P := by
            intro hP
            exact hty (inv.tainted y _ hy ⟨l, by simp [Val.locs], hP⟩)
          refine ⟨inv.typed, inv.tainted, inv.old, ?_, ?_⟩
          · intro k hk
            simp only [List.mem_cons] at hk
            rcases hk with rfl | hk
            · exact hl
            · exact inv.untouched k hk
          · intro k hk
            have hne : k ≠ l := fun heq => hl (heq ▸ hk)
            simp [updHeap, hne, inv.frame k hk]
        · simp at hs
    · simp at hc

theorem checkStmts_preserves {P : List Loc} {h0 : Loc → Nat} :
    ∀ (body : List Stmt) {c c' : CState} {s s' : State},
      checkStmts c body = some c' → execStmts s body = some s' →
      Inv P h0 c s → Inv P h0 c' s'
  | [], c, c', s, s', hc, hs, inv => by
    simp only [checkStmts, Option.some.injEq] at hc
    simp only [execStmts, Option.some.injEq] at hs
    subst hc hs
    exact inv
  | st :: rest, c, c', s, s', hc, hs, inv => by
    simp only [checkStmts] at hc
    split at hc
    · rename_i cm hcm
      simp only [execStmts] at hs
      split at hs
      · rename_i sm hsm
        exact checkStmts_preserves rest hc hs (st.check_preserves hcm hsm inv)
      · simp at hs
    · simp at hc

/-- **The no-write, frame and no-retain parts of T1/T1′ for the core
calculus.** If `f` is accepted, then running it on a well-typed argument `v`
(with every buffer `v` reaches older than the allocation frontier):
- writes none of those buffers at any point of the run,
- leaves each of them with its original contents, and
- returns a value that reaches none of them.
Reference counts are not modelled, so T1's "RC unchanged" is not claimed. -/
theorem Fn.check_sound (f : Fn) (v : Val) (heap : Loc → Nat) (next : Loc)
    (hchk : f.check = true) (hty : HasTy v f.paramTy) (hold : ∀ l ∈ v.locs, l < next)
    {s : State} {r : Option Val} (hrun : f.run v heap next = some (s, r)) :
    (∀ l ∈ s.written, l ∉ v.locs) ∧
    (∀ l ∈ v.locs, s.heap l = heap l) ∧
    (∀ w, r = some w → ∀ l ∈ w.locs, l ∉ v.locs) := by
  unfold Fn.check at hchk
  split at hchk
  · rename_i c hc
    unfold Fn.run at hrun
    split at hrun
    · rename_i s1 hs1
      simp only [Option.some.injEq, Prod.mk.injEq] at hrun
      obtain ⟨rfl, rfl⟩ := hrun
      have inv0 : Inv v.locs heap f.initCheck
          { env := upd (fun _ => none) f.param (some v), heap, next, written := [] } := by
        obtain ⟨h1, h2⟩ := bind_typed_tainted (P := v.locs)
          (c := { ty := fun _ => none, taint := fun _ => false })
          (env := fun _ => none) (by simp) (by simp) f.param v f.paramTy true hty
          (fun _ => rfl)
        exact ⟨h1, h2, hold, by simp, fun _ _ => rfl⟩
      have inv := checkStmts_preserves f.body hc hs1 inv0
      refine ⟨inv.untouched, inv.frame, ?_⟩
      intro w hw l hl hP
      have := inv.tainted f.ret w hw ⟨l, hl, hP⟩
      simp [this] at hchk
    · simp at hrun
  · simp at hchk

end VibeFormal.Borrow
