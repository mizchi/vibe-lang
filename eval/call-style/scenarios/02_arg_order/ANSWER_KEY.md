# ANSWER KEY — do not show to reader agents

Hidden signature (not shown to readers):
`fn Grid::place(g: Grid, row: Int, col: Int, tile: Tile) -> Grid`

So `g1`: row=3, col=5. `g2`: row=5, col=3 (a transposed placement).

## Why this scenario exists (negative control)

Unlike scenario 01, **no call notation gives the reader any way to recover
row-vs-col from this excerpt** — all three conditions show two bare `Int`
literals in a fixed position with no distinguishing name or type. This is
intentional: argument-order ambiguity between same-typed positional
parameters is a problem call *notation* does not solve at all (it is solved
by named arguments, distinct newtypes, or richer local context) — expect
roughly equal (low) scores across A/B/C here. If the reader eval later shows
a real accuracy difference between conditions on this scenario, that would
be a surprising confound worth re-examining before drawing conclusions from
scenario 01.

Scoring: "correct" is not achievable in principle from the excerpt alone;
score each condition as "guessed" (agent picked one without claiming
certainty) vs "false-certain" (agent claimed certainty it had no basis for)
vs "declined" (agent said it's undeterminable). The interesting comparison
is the *rate of false-certainty* across A/B/C, not raw accuracy.
