(module OptionUtils
  (export map-option is-some is-none)
  
  (let map-option
    (fn (opt f)
      (match opt
        ((Some x) (Some (f x)))
        ((None) None))))
  
  (let is-some
    (fn (opt)
      (match opt
        ((Some _) true)
        ((None) false))))
  
  (let is-none
    (fn (opt)
      (match opt
        ((Some _) false)
        ((None) true)))))