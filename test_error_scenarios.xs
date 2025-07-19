; Test various error scenarios to evaluate error messages

; Scenario 1: Type mismatch
(let x 42)
(let y "hello")
(+ x y)  ; Error: Can't add Int and String

; Scenario 2: Undefined variable (typo)
(let result (mpa inc (list 1 2 3)))  ; Error: 'mpa' should be 'map'

; Scenario 3: Wrong pattern matching
(match (list 1 2 3)
  ((Cons h t) h)  ; Error: Wrong pattern for list
  ((Nil) 0))

; Scenario 4: Function arity mismatch
(let add (lambda (x y) (+ x y)))
(add 1)  ; Error: Missing argument

; Scenario 5: Type in let binding
(let z: Bool 42)  ; Error: Expected Bool, got Int