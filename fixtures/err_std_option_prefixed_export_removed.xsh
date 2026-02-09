import { option_map } from "./xsh/std/option.xsh"

option_map(Some(5), (x) -> x * 2)

__DATA__
{"error_contains":"unknown function: `option_map`"}
