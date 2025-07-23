-- Test hole completion feature

-- Simple hole
let x = @ + 5

-- Hole with type hint (when type inference is implemented)
let y = @:Int * 2

-- Named hole
let z = @value + 10

-- Hole in block
let result = {
    let a = 10;
    let b = @;
    a + b
}

-- Hole in list
let list = [1, 2, @, 4]

-- Hole in function application
let double = fn x -> x * 2
let val = double @

-- Hole in pipeline
let piped = @ | double

-- Multiple holes
let sum = @ + @ + @