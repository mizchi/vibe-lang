;; Test module definition and import

;; Define a simple Math module
(module Math
  (export add multiply PI)
  
  ;; Constants
  (let PI 3.14159)
  
  ;; Functions
  (let add (fn (x y) (+ x y)))
  (let multiply (fn (x y) (* x y)))
  
  ;; Internal helper (not exported)
  (let square (fn (x) (* x x)))) in

;; Import specific items
(import Math (add PI)) in

;; Use imported functions
(let result1 (add 5 3) in
(let result2 (* PI 2) in

;; Test results
(let dummy1 (print "5 + 3 =") in
(let dummy2 (print result1) in
(let dummy3 (print "PI * 2 =") in
(let dummy4 (print result2) in

(print "Module test completed!"))))))))