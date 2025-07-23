-- String operations tests
-- expect: true

let test1 = String.eq (String.concat "Hello, " "World!") "Hello, World!" in
  let test2 = eq (String.length "hello") 5 in
    let test3 = eq (String.length "") 0 in
      let test4 = String.eq (Int.toString 42) "42" in
        let test5 = String.eq (Int.toString (-123)) "-123" in
          let test6 = eq (String.toInt "123") 123 in
            let test7 = String.eq "test" "test" in
              let test8 = if String.eq "hello" "world" { false } else { true } in
                let s1 = String.concat "a" "b" in
                  let s2 = String.concat s1 "c" in
                    let test9 = String.eq s2 "abc" in
                      let test10 = String.eq 
                                    (String.concat (String.concat "one" "two") "three")
                                    "onetwothree" in
                        if test1 {
                          if test2 {
                            if test3 {
                              if test4 {
                                if test5 {
                                  if test6 {
                                    if test7 {
                                      if test8 {
                                        if test9 {
                                          test10
                                        } else {
                                          false
                                        }
                                      } else {
                                        false
                                      }
                                    } else {
                                      false
                                    }
                                  } else {
                                    false
                                  }
                                } else {
                                  false
                                }
                              } else {
                                false
                              }
                            } else {
                              false
                            }
                          } else {
                            false
                          }
                        } else {
                          false
                        }