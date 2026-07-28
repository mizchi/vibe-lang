You are shown a short excerpt from a function written in "Vibe", a
programming language you have never seen before. There is no surrounding
context (the rest of the file was cut). Do not guess about Vibe's general
design beyond what this excerpt shows you.

```
let total = raw.split(",").filter(is_valid_int).map(double_str).sum()
```

Assume `raw` is a `String`, `is_valid_int` is a function from `String` to
`Bool`, and `double_str` is a function from `String` to `Int`.

Explain this excerpt as an ordered list of steps, in the order they actually
EXECUTE (not the order they appear on the page), stating the type of the
value produced by each step. Then answer: did you have to jump around the
text (e.g. read inside-out, or reread a line) to construct that order, or
did reading top-to-bottom/left-to-right already give you the execution
order? Rate how much back-and-forth this excerpt required: none / a little /
a lot.
