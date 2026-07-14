# #847 regression fixture

A stray non-`.vibe` sibling file (this one) must not make auto-discovery
crash — `contract_sibling_impl_raws` must ignore it, not misclassify it as a
subdirectory and try to `Fs::readdir` it.
