-- Effect examples that actually work in current XS implementation

-- The only working effect: print
perform print "Hello from XS Effect System!"

-- Multiple print statements
perform print "First line"
perform print "Second line"
perform print "Third line"

-- Note: "perform IO" doesn't work, only "perform print" works