-- Test hash references

-- First define some expressions and note their hashes
let x = 42
let double = fn n -> n * 2

-- After noting the hashes from shell output, we could reference them:
-- Example (using hypothetical hashes):
-- let y = #abc123  -- refers to the expression that produced hash abc123
-- double #def456   -- apply double to the result of expression with hash def456

-- For now, just test that these expressions generate hashes
x
double 21