# ANSWER KEY — do not show to reader agents

Ground truth execution order (same for all 3 conditions, only notation differs):

1. `String::split(raw, ",")` : `String -> Array[String]`
2. `Array::filter(_, is_valid_int)` : `Array[String] -> Array[String]`
3. `Array::map(_, double_str)` : `Array[String] -> Array[Int]`
4. `Array::sum(_)` : `Array[Int] -> Int`

## Why this scenario exists

All three conditions are semantically unambiguous here (no overloaded names,
no hidden types) — this scenario isolates **tracing effort**, not
correctness. Expectation grounded in the language design rationale already
on record (ADR-0020 §3, and the user's own stated motivation for the
`Module::fn` + `|>` design): condition **A (nested explicit)** requires
reading inside-out / right-to-left to recover execution order (a classic
complaint about deeply nested calls in any language); conditions **B (dot
chain)** and **C (pipe)** both read top-to-bottom / left-to-right in
execution order, so both should self-report "none" or "a little"
back-and-forth, while A should self-report "a lot" or explicitly describe
reading inside-out.

If B and C score equivalently here (as expected), that's consistent with
the idea that **pipe already solves the chain-ordering problem vibe adopted
UFCS-adjacent styles for** — meaning the readability case for dot-call over
pipe has to rest on scenario 01's asymmetry (or on terseness/familiarity
alone), not on chain-tracing, since pipe ties dot on this axis while keeping
the type-name transparency dot gives up.

Scoring: record each condition's self-reported back-and-forth level and
whether the step list matches the ground truth order above.
