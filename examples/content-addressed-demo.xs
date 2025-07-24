-- Content-Addressed Code Demo
-- This file demonstrates the content-addressed features of XS

-- When expressions are evaluated in the shell, they are assigned a hash
-- This allows referencing previous expressions by their content hash

-- Example workflow in XS Shell:
-- xs> let double = fn x -> x * 2
-- double : Int -> Int
--   [abc123de...]
--
-- xs> #abc123de  -- Reference the function by its hash
-- <closure>

-- Import with specific version hash
-- This ensures you're using exactly the version you tested with
import Math@1a2b3c4d
import String@5e6f7a8b as Str

-- Type definitions are also tracked as dependencies
type User = {
  name: String,
  age: Int,
  email: String?  -- Optional field using sugar syntax
}

-- When this function is stored, the system tracks that it depends on the User type
let validateUser user:User -> Bool =
  match user.email {
    None -> user.age >= 13  -- No email required for teens
    Some email -> 
      (user.age >= 18) && (Str.contains email "@")
  }

-- Functions can reference other functions by hash
-- This creates an immutable dependency graph
let processUsers users:[User] validator:(User -> Bool) -> [User] =
  filter validator users

-- Example of how type inference results are embedded
-- Even without explicit type annotations, the system will store:
-- getAdults : [User] -> [User]
let getAdults = processUsers #def456  -- Reference validateUser by hash

-- Namespace definitions with content addressing
namespace Utils {
  -- Each definition in a namespace gets its own hash
  let formatUser user:User -> String =
    match user.email {
      None -> user.name
      Some email -> strConcat user.name (strConcat " <" (strConcat email ">"))
    }
}

-- The dependency graph ensures that:
-- 1. If User type changes, all dependent functions are flagged
-- 2. Specific versions can be referenced by hash
-- 3. Code is immutable - updates create new hashes
-- 4. Type information is preserved even without annotations