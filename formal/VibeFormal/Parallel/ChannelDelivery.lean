import Std

set_option autoImplicit false

/-
#1238 P1 (runtime protocol): the bounded channel's delivery guarantees.

`lib/@vibex/concurrent` (#1081) ships a cooperative run-to-completion bounded
MPMC channel: capacity-0 rendezvous, per-sender FIFO, last-release close,
drain-then-None. This slice models the two properties a user of that channel
reasons with -- **no duplication** and **no loss** -- plus the close protocol
that makes "no loss" observable: closing does not discard what is already
buffered, so a receiver drains before it sees `None`.

**In scope.** One channel's buffer as the delivery order, receive as taking
from the front, close as a flag that only changes what an EMPTY receive
returns. Enough to state that what comes out is exactly what went in, in
order, once each.

**Out of scope.** Capacity and the blocking a full buffer causes (the
`send_wait`/`recv_wait` suspension path -- that is scheduling, and ADR-0076's
suspend lowering is where it is pinned), interleaving of several senders
beyond the per-sender FIFO the buffer already models, and linearizability
against a concurrent specification, which needs a history model rather than a
state one and is its own slice.
-/

namespace VibeFormal.Concurrency

/-- Payloads are opaque identities: delivery does not inspect them. -/
abbrev Payload := Nat

/-- A channel: what has been sent and not yet received, in delivery order, and
whether every sender has released. -/
structure Chan where
  buffer : List Payload
  closed : Bool
  deriving DecidableEq, Repr

namespace Chan

/-- Send appends: the buffer IS the delivery order. -/
def send (chan : Chan) (payload : Payload) : Chan :=
  ⟨chan.buffer ++ [payload], chan.closed⟩

/-- The last sender releasing closes the channel. It does not touch the
buffer -- that is exactly what makes drain-then-None hold. -/
def close (chan : Chan) : Chan :=
  ⟨chan.buffer, true⟩

/-- Receive takes from the front. An empty OPEN channel yields nothing yet and
is unchanged (the caller suspends); an empty CLOSED channel is terminated. -/
def recv : Chan → Option Payload × Chan
  | ⟨[], closed⟩ => (none, ⟨[], closed⟩)
  | ⟨payload :: rest, closed⟩ => (some payload, ⟨rest, closed⟩)

/-- Drain every buffered payload, in order. -/
def drain : Chan → List Payload
  | ⟨buffer, _⟩ => buffer

/-- **FIFO.** A send into an empty channel is what the next receive returns. -/
theorem recv_send_empty (closed : Bool) (payload : Payload) :
    recv (send ⟨[], closed⟩ payload) = (some payload, ⟨[], closed⟩) := by
  simp [send, recv]

/-- **No reordering.** With something already buffered, a later send does not
overtake it. -/
theorem recv_send_nonempty (head : Payload) (rest : List Payload) (closed : Bool)
    (payload : Payload) :
    recv (send ⟨head :: rest, closed⟩ payload) = (some head, ⟨rest ++ [payload], closed⟩) := by
  simp [send, recv]

/-- **No duplication.** Receiving removes what it returned: the payload is not
in the resulting buffer's front position again, and the buffer strictly
shrinks. -/
theorem recv_consumes (head : Payload) (rest : List Payload) (closed : Bool) :
    (recv ⟨head :: rest, closed⟩).2 = ⟨rest, closed⟩ := by
  simp [recv]

/-- **Close does not discard.** Closing leaves the buffer untouched, so
everything sent before the close is still deliverable. -/
theorem drain_close (chan : Chan) : drain (close chan) = drain chan := by
  simp [close, drain]

/-- **Drain before None.** A closed channel with something buffered still
delivers it -- `None` means terminated, never "closed". -/
theorem recv_closed_nonempty (head : Payload) (rest : List Payload) :
    recv ⟨head :: rest, true⟩ = (some head, ⟨rest, true⟩) := by
  simp [recv]

/-- ...and only once drained does it report termination. -/
theorem recv_closed_empty : recv ⟨[], true⟩ = (none, ⟨[], true⟩) := by
  simp [recv]

/-- Termination is stable: a drained closed channel keeps reporting `None`, so
a receiver loop terminates rather than spinning between states. -/
theorem recv_closed_empty_idempotent :
    (recv (recv ⟨[], true⟩).2).1 = none := by
  simp [recv]

/-- An empty OPEN channel is NOT terminated -- it yields nothing yet and is
unchanged, which is the state `recv_wait` suspends in. Distinguishing this
from the closed case is the whole content of the close protocol. -/
theorem recv_open_empty_unchanged :
    recv ⟨[], false⟩ = (none, ⟨[], false⟩) := by
  simp [recv]

/-- **No loss.** Everything sent is still queued for delivery: sending appends
to the drain order, so no send is dropped on the floor. -/
theorem drain_send (chan : Chan) (payload : Payload) :
    drain (send chan payload) = drain chan ++ [payload] := by
  simp [send, drain]

end Chan

end VibeFormal.Concurrency
