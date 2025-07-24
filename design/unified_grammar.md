# Unified Grammar Design

## Current State
We have special parsing rules for:
- `match expr { patterns }`
- `do { statements }`
- `handle expr { handlers }`
- `perform Effect args`
- `with handler body`

## Proposed Simplification

### Grammar Rules

```
expr ::= 
  | primary_expr
  | expr expr                    // application
  | expr infix_op expr          // infix
  | keyword_form

primary_expr ::=
  | literal
  | identifier  
  | '(' expr ')'
  | '[' expr_list ']'
  | block
  | lambda

keyword_form ::=
  | 'match' expr block          // match x { ... }
  | 'do' block                  // do { ... }
  | 'handle' expr block         // handle e { ... }
  | 'perform' identifier expr*  // perform IO "hello"
  | 'if' expr block ('else' block)?
  | 'let' pattern '=' expr ('in' expr)?
  | 'rec' pattern '=' expr

block ::= '{' block_content '}'

block_content ::=
  | expr_sequence              // normal block
  | pattern_cases              // match patterns
  | do_statements              // do notation
  | handler_cases              // effect handlers
  | record_fields              // record literal
```

### Semantic Analysis Phase

After parsing, we can validate:
1. `match` blocks contain valid patterns
2. `do` blocks contain valid bind statements
3. `handle` blocks contain valid handler cases

This separates syntactic concerns from semantic ones, making the parser simpler and more uniform.

## Benefits

1. **Simpler Parser**: Fewer special cases
2. **Better Error Messages**: Can provide context-aware errors in semantic phase
3. **Easier Extensions**: New keyword forms just need to follow the pattern
4. **IDE Support**: Uniform structure makes tooling easier

## Implementation Strategy

1. First pass: Parse everything uniformly
2. Second pass: Validate and transform based on context
3. Type checking: Already happens separately