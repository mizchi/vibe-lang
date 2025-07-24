-- Basic effect examples that currently work in XS

-- 1. Simple IO effect (this works!)
perform IO "Hello from XS Effect System!"

-- 2. Arithmetic with result (pure computation)
let result = 1 + 2 + 3
result

-- 3. Conditional with effects
if true {
  perform IO "This is the true branch"
} else {
  perform IO "This is the false branch"
}

-- 4. Let binding (effects in bindings don't evaluate yet)
let x = 42
x

-- Note: The following don't work yet at runtime:
-- - perform State ()
-- - perform Exception "error"
-- - perform Async 42
-- - Effect handlers
-- - Do notation