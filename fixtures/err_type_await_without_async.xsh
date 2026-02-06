let f = (x: Int) -> Int {
  await x
}

__DATA__
{"error_contains": "EffectNotAllowed"}
