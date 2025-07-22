; XS Shell Pipeline Functions
; Provides shell-style pipeline operations for the REPL

; Pipe operator - connects two operations
(let pipe (fn (input op) 
  (op input)))

; List all definitions
(let definitions (fn () 
  (builtinDefinitions)))

; List shorthand
(let ls definitions)

; Filter definitions by a predicate
(let filter (fn (field value)
  (fn (defs)
    (builtinFilter defs field value))))

; Select specific fields from definitions
(let select (fn fields
  (fn (defs)
    (builtinSelect defs fields))))

; Sort definitions by a field
(let sort (fn (field)
  (fn (defs)
    (builtinSort defs field false))))

; Sort definitions by a field in descending order
(let sortDesc (fn (field)
  (fn (defs)
    (builtinSort defs field true))))

; Take first n items
(let take (fn (n)
  (fn (items)
    (builtinTake items n))))

; Group definitions by a field
(let groupBy (fn (field)
  (fn (defs)
    (builtinGroupBy defs field))))

; Count items
(let count (fn (items)
  (builtinCount items)))

; Search definitions with query
(let search (fn (query)
  (builtinSearch query)))

; Example pipeline operations:
; (pipe (definitions) (filter "kind" "function"))
; (pipe (pipe (definitions) (filter "kind" "function")) (sort "name"))
; (pipe (search "type:Int") (take 5))