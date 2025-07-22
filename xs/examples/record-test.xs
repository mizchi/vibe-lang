;; Test record literal and field access

;; Simple record
(let person { name: "Alice", age: 30, city: "Tokyo" } in

;; Field access
(let name person.name in
(let age person.age in

;; Nested record
(let address { street: "Main St", number: 123 } in
(let company { name: "Tech Corp", address: address } in

;; Nested field access
(let company-name company.name in
(let street company.address.street in

;; Function with record parameter
(let get-name (fn (p) p.name) in
(let alice-name (get-name person) in

;; Print results
(let dummy1 (print "Person name:") in
(let dummy2 (print name) in
(let dummy3 (print "\nPerson age:") in
(let dummy4 (print age) in
(let dummy5 (print "\nCompany name:") in
(let dummy6 (print company-name) in
(let dummy7 (print "\nCompany street:") in
(let dummy8 (print street) in
(let dummy9 (print "\nget-name result:") in
(let dummy10 (print alice-name) in

(print "\nRecord test completed!"))))))))))))))))))))))