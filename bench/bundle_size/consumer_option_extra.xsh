import { unwrap_or, zip_sum } from "../../xsh/std/option.xsh"

let out = zip_sum(Some(2), Some(5))
unwrap_or(out, 0)
