// Arrow expression confused with comparison
let x = if a -> b { 1 } else { 2 }

__DATA__
{"error_contains": "UnknownName"}
