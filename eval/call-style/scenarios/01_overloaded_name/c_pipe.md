You are shown a short excerpt from the middle of a function written in
"Vibe", a programming language you have never seen before. There is no
surrounding context (the rest of the file was cut). Do not guess about
Vibe's general design beyond what this excerpt shows you.

```
let handle = (cart, overflow, item) -> {
  if cart |> Cart::size() >= 10 {
    overflow |> Crate::push(item)
    cart
  } else {
    cart |> Cart::push(item)
  }
}
```

Answer these questions using ONLY the excerpt above:

1. What is the type of the value bound to `overflow`?
2. Does the call involving `overflow` mutate `overflow` in place, or does
   it return a new value while leaving the original `overflow` unchanged?
   State your confidence (certain / fairly confident / guessing) and the
   evidence in the excerpt you used to decide.
3. What is the type of the value bound to `cart`?

Answer concisely, question by question.
