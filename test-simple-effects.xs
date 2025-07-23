-- Simple effect test

-- Test perform with built-in print effect
perform print "Hello from effect system!"

-- Test basic block with perform
{
    perform print "In a block";
    42
}