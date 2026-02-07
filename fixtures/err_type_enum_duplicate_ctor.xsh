// Enum with duplicate constructor names
enum Status { Active, Pending, Active }
let s = Active

__DATA__
{"error_contains": "duplicate"}
