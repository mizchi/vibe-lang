-- Test new syntax features

-- Block expression
let blockResult = {
    let x = 10;
    let y = 20;
    x + y
}

-- Pipeline operator
let pipelineResult = [1, 2, 3] | map (fn x -> x * 2) | sum

-- Record literal and access
let person = { name: "Alice", age: 30 }
let personName = person.name

-- Do block with effects
let ioResult = do <IO> {
    print "Hello from do block"
}

-- Hole (commented out as it should error)
-- let incomplete = @ + 5

-- Pattern matching with new syntax
let matchResult = case person.age of {
    0 -> "baby"
    30 -> "thirty"
    _ -> "other"
}

-- Final result
blockResult