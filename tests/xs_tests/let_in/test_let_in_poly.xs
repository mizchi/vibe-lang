
(let id (fn (x) x) in
  (let int_result (id 42) in
    (let bool_result (id true) in
      int_result)))
