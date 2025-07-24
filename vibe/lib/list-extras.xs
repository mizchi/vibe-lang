-- Additional list operations for XS standard library

-- reverse - reverses a list (using helper function)
reverseHelper lst acc =
  case lst of {
    [] -> acc;
    h :: t -> reverseHelper t (cons h acc)
  }

reverse lst = reverseHelper lst []

-- append - concatenates two lists  
append xs ys =
  case xs of {
    [] -> ys;
    h :: t -> cons h (append t ys)
  }

-- take - takes first n elements from a list
take n lst =
  if n = 0 {
    []
  } else {
    case lst of {
      [] -> [];
      h :: t -> cons h (take (n - 1) t)
    }
  }

-- drop - drops first n elements from a list
drop n lst =
  if n = 0 {
    lst
  } else {
    case lst of {
      [] -> [];
      h :: t -> drop (n - 1) t
    }
  }

-- Export all functions
[reverse, append, take, drop]