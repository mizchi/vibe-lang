-- Test hash-based import syntax

-- Define a module
module Math {
  export fibonacci, factorial
  
  rec fibonacci n =
    if n < 2 {
      n
    } else {
      (fibonacci (n - 1)) + (fibonacci (n - 2))
    }
  
  rec factorial n =
    if (eq n 0) {
      1
    } else {
      n * (factorial (n - 1))
    }
}

-- Regular import
import Math

-- Import with specific hash (example)
import Math@abc123

-- Import with alias
import Math@def456 as OldMath

-- Use imported functions
Math.fibonacci 5
OldMath.factorial 5