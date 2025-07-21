
(let apply_twice (fn (f x)
  (let once (f x) in
    (f once)))
in
  (apply_twice (fn (n) (* n 2)) 3))
