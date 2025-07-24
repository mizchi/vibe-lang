# Unified Syntax Design

## Current Special Forms
1. `match expr { patterns }`
2. `do { statements }`  
3. `handle expr { handlers }`
4. `perform Effect args`
5. `with handler body`

## Proposed Unified Syntax

All special forms become function calls with block arguments:

```
-- Pattern matching
match expr {
  pattern1 -> result1
  pattern2 -> result2
}

-- Do notation
do {
  x <- action1;
  y <- action2;
  result
}

-- Effect handling
handle expr {
  Effect1 args k -> handler1
  Effect2 args k -> handler2
  return x -> result
}

-- Perform effect (already function-like)
perform IO "hello"

-- With handler (already function-like)
with handler body
```

## Grammar Simplification

```
expr ::= primary_expr (application | infix)*

primary_expr ::= 
  | literal
  | identifier
  | '(' expr ')'
  | '[' expr_list ']'
  | '{' block '}'
  | 'fn' params '->' expr
  | 'if' expr block ('else' block)?
  | keyword_expr

keyword_expr ::=
  | 'match' expr block
  | 'do' block
  | 'handle' expr block
  | 'perform' identifier expr*
  | 'with' expr expr

block ::= '{' (statement | expr)* '}'

application ::= primary_expr+
```

This unifies all constructs under a simple rule: keywords followed by their arguments (expressions or blocks).