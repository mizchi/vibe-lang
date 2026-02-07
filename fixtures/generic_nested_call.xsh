let identity = [T](x: T) -> T { x }
identity(identity(identity(42)))

__DATA__
{"last": "42"}
