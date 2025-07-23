let h = handler {
  print s k -> k ()
}

perform print "test"