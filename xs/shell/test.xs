-- Test shell commands
-- import shell.commands as Cmd

-- For now, test echo directly
import shell.echo as Echo

-- Test echo command
perform print "=== Testing echo ==="
Echo.echo ["Hello", "World"]
Echo.echo ["XS", "Shell", "Commands"]
Echo.echo []