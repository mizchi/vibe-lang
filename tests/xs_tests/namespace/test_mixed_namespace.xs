-- expect: "Count: 42"
-- Test: Mixed namespace usage with String and Int modules
String.concat "Count: " (Int.toString (Int.add 40 2))