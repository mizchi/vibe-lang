;; Simple test to verify self-hosting concepts
;; This demonstrates what works and what doesn't in current XS

;; Test basic list operations that we need for parsing
(let testList (list 1 2 3))
(print (cons 0 testList))  ; Should print (list 0 1 2 3)

;; Test pattern matching on custom types
(type Token
  (TInt Int)
  (TSymbol String)
  (TList))

(let tok1 (TInt 42))
(let tok2 (TSymbol "foo"))

(let describeToken (fn (tok)
  (match tok
    ((TInt n) (stringConcat "Integer: " (intToString n)))
    ((TSymbol s) (stringConcat "Symbol: " s))
    ((TList) "List"))))

(print (describeToken tok1))
(print (describeToken tok2))

;; Test simple type representation
(type SimpleType
  (SInt)
  (SBool)
  (SFunc SimpleType SimpleType))

(let intToBool (SFunc (SInt) (SBool)))

(let typeToString (fn (t)
  (match t
    ((SInt) "Int")
    ((SBool) "Bool")
    ((SFunc from to) 
      (stringConcat (typeToString from)
                    (stringConcat " -> "
                                  (typeToString to)))))))

(print (typeToString intToBool))

;; Demonstrate what's missing for real self-hosting:
(print "\nLimitations found:")
(print "1. No stringAt function for character access")
(print "2. No ref/deref for mutable state")
(print "3. No try-catch for error handling")
(print "4. No macro system for control structures")

;; But we can still do useful computation!
(rec map (f lst)
  (match lst
    ((list) (list))
    ((list h t) (cons (f h) (map f t)))))

(let double (fn (x) (* x 2)))
(print (map double (list 1 2 3 4 5)))