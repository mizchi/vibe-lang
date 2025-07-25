-- Example of module system usage

-- Define a Math module
module Math {
    export add, sub, mul, PI
    
    let PI = 3.14159
    
    let add x y = x + y
    let sub x y = x - y
    let mul x y = x * y
}

-- Define a List utilities module
module ListUtils {
    export length, sum
    
    rec length lst =
        case lst of {
            [] -> 0
            h :: t -> 1 + (length t)
        }
    
    rec sum lst =
        case lst of {
            [] -> 0
            h :: t -> h + (sum t)
        }
}

-- Use the modules
import Math (add, PI)
import ListUtils as L

-- Now we can use the imported functions
let result = add 10 20
IO.print result

let area = PI * (5 * 5)
IO.print area

let numbers = [1, 2, 3, 4, 5]
let total = L.sum numbers
IO.print total