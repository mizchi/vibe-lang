let h = handler {
  print s k -> k ()
}

with h {
  perform print "test"
}