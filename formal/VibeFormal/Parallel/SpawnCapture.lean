import Std

set_option autoImplicit false

/-
#1238 (concurrency の静的安全性, retargeted): `TaskGroup`'s spawn-capture rule.

The slice this replaces was written against #818's `Spawn` capability handler,
which was closed not_planned; the project shipped `TaskGroup` instead (#1081) --
a plain library type plus a compiler-side check. The property worth modeling
did not change, so this models the rule the checker actually enforces.

A closure handed to `TaskGroup::spawn` runs concurrently with the code that
built it, so what it CAPTURES decides whether the program is safe. The live
rule (`checker_spawnable.vibe`'s `sp_spawnable_ok`) admits a capture when it
is structurally `Send`, or when it is an endpoint -- `TaskGroup`, `TaskHandle`,
`Sender`, `Receiver` -- tagged with THIS spawn's own region. An endpoint from a
DIFFERENT nursery is rejected exactly like any other non-Send value, which is
what keeps a channel from outliving the group that owns it.

**In scope.** The classification of a capture, the legality of a spawn given
its captures, and that legality is decided per-capture (so a diagnostic can
name one).

**Out of scope.** What `Send` means structurally (the checker computes it from
the type; here it is an input), the region-escape check on a spawn's RESULT
(`TaskHandle` outliving its group -- the same region machinery, different
direction), and anything dynamic: this is the static rule only.
-/

namespace VibeFormal.Concurrency

/-- A nursery's region identity. Regions are compared by identity, never by
structure: two nurseries are the same region only if they are the same
nursery. -/
abbrev Region := Nat

/-- What a captured value is, as far as the rule can see. -/
inductive Capture where
  /-- Structurally sendable: safe to move into another task unconditionally. -/
  | sendValue
  /-- An endpoint (TaskGroup / TaskHandle / Sender / Receiver) belonging to
  the nursery `region`. -/
  | endpoint (region : Region)
  /-- Neither -- a plain shared value that is not `Send`. -/
  | shared
  deriving DecidableEq, Repr

/-- May `capture` cross into a task spawned on nursery `here`? -/
def Capture.Ok (here : Region) : Capture → Prop
  | .sendValue => True
  | .endpoint region => region = here
  | .shared => False

/-- A spawn is legal when every one of its captures is. Stated over the list so
that rejecting one capture is what rejects the spawn -- which is what lets the
checker's diagnostic name a single variable. -/
def SpawnOk (here : Region) (captures : List Capture) : Prop :=
  ∀ capture ∈ captures, Capture.Ok here capture

namespace SpawnOk

/-- Capturing nothing is always legal. -/
theorem nil (here : Region) : SpawnOk here [] := by
  intro capture member
  simp at member

/-- Legality is decided per capture: one illegal capture rejects the spawn.
This is the direction the diagnostic uses. -/
theorem not_of_capture {here : Region} {captures : List Capture} {bad : Capture}
    (member : bad ∈ captures) (illegal : ¬ Capture.Ok here bad) :
    ¬ SpawnOk here captures := by
  intro ok
  exact illegal (ok bad member)

/-- ...and the converse: legality of the whole is exactly legality of each
part, so a checker may walk captures in any order and stop at the first
failure. -/
theorem cons {here : Region} {capture : Capture} {rest : List Capture}
    (head : Capture.Ok here capture) (tail : SpawnOk here rest) :
    SpawnOk here (capture :: rest) := by
  intro c member
  rcases List.mem_cons.mp member with headEq | inRest
  · exact headEq ▸ head
  · exact tail c inRest

end SpawnOk

/--
**Negative witness 1: a foreign endpoint.** A `Sender` belonging to a
DIFFERENT nursery cannot be captured. Without this a channel could outlive the
group that owns it -- the endpoint would still be usable after its nursery had
finished draining and closed.
-/
theorem not_spawnOk_foreign_endpoint {here there : Region} (distinct : there ≠ here) :
    ¬ SpawnOk here [Capture.endpoint there] := by
  refine SpawnOk.not_of_capture List.mem_cons_self ?_
  intro ok
  exact distinct ok

/--
**Negative witness 2: a non-Send value.** A plain shared value is rejected
however the nursery is arranged -- the region rule is an ADDITION to `Send`,
not a replacement for it.
-/
theorem not_spawnOk_shared (here : Region) :
    ¬ SpawnOk here [Capture.shared] := by
  refine SpawnOk.not_of_capture List.mem_cons_self ?_
  intro ok
  exact ok

/--
Positive counterpart: a `Send` value and an endpoint of THIS nursery are both
fine, together. Confirms the rule rejects foreign endpoints and non-Send
values rather than rejecting captures in general.
-/
theorem spawnOk_send_and_own_endpoint (here : Region) :
    SpawnOk here [Capture.sendValue, Capture.endpoint here] := by
  refine SpawnOk.cons trivial (SpawnOk.cons rfl (SpawnOk.nil here))

/--
The rule is not vacuous in the other direction either: the SAME endpoint that
is legal on its own nursery is illegal on another one. This is the whole
content of "same-nursery" -- legality depends on the pair, not on the endpoint
alone.
-/
theorem endpoint_legality_is_relative {a b : Region} (distinct : a ≠ b) :
    SpawnOk a [Capture.endpoint a] ∧ ¬ SpawnOk b [Capture.endpoint a] := by
  constructor
  · exact SpawnOk.cons rfl (SpawnOk.nil a)
  · exact not_spawnOk_foreign_endpoint distinct

end VibeFormal.Concurrency
