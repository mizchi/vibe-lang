-- XS Shell Pipeline Functions
-- Provides shell-style pipeline operations for the REPL

-- Pipe operator - connects two operations
let pipe = \input op -> 
  op input

-- List all definitions
let definitions = \() -> 
  builtinDefinitions

-- List shorthand
let ls = definitions

-- Filter definitions by a predicate
let filter = \field value ->
  \defs ->
    builtinFilter defs field value

-- Select specific fields from definitions
let select = \fields ->
  \defs ->
    builtinSelect defs fields

-- Sort definitions by a field
let sort = \field ->
  \defs ->
    builtinSort defs field false

-- Sort definitions by a field in descending order
let sortDesc = \field ->
  \defs ->
    builtinSort defs field true

-- Take first n items
let take = \n ->
  \items ->
    builtinTake items n

-- Group definitions by a field
let groupBy = \field ->
  \defs ->
    builtinGroupBy defs field

-- Count items
let count = \items ->
  builtinCount items

-- Search definitions with query
let search = \query ->
  builtinSearch query

-- Example pipeline operations:
-- pipe (definitions) (filter "kind" "function")
-- pipe (pipe (definitions) (filter "kind" "function")) (sort "name")
-- pipe (search "type:Int") (take 5)