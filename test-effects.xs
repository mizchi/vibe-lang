-- Test effect system features

-- Basic do block with IO effect
let ioTest = do <IO> {
    perform print "Hello from do block"
}

-- Handler example (syntax demonstration)
let handled = handler {
    print msg k -> {
        -- Custom print handler
        k (strConcat "[CUSTOM] " msg)
    }
} {
    perform print "Test message"
}

-- With handler syntax
let withHandlerTest = with handler {
    print msg k -> k ()  -- Suppress printing
} {
    perform print "This won't be printed"
}

-- Multiple effects in do block
let multiEffect = do <IO, State> {
    perform print "Starting computation";
    let x = perform getState;
    perform setState (x + 1);
    perform print "Done"
}

-- Effect polymorphism (when implemented)
let genericEffect e = do <e> {
    42
}