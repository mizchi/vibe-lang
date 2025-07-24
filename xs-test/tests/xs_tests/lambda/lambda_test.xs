-- Lambda expression tests
-- expect: true

let test1 = eq ((\x -> x) 10) 10 in
  let const42 = \x -> 42 in
    let test2 = eq (const42 99) 42 in
      let test3 = eq ((\x y -> x + y) 3 4) 7 in
        let f = \x -> \y -> x + y in
          let add5 = f 5 in
            let test4 = eq (add5 3) 8 in
              let apply = \f x -> f x in
                let double = \x -> x * 2 in
                  let test5 = eq (apply double 21) 42 in
                    let curryAdd = \x -> \y -> x + y in
                      let add10 = curryAdd 10 in
                        let test6 = eq (add10 32) 42 in
                          let makeAdder = \n -> \x -> x + n in
                            let add3 = makeAdder 3 in
                              let test7 = eq (add3 7) 10 in
                                if test1 {
                                  if test2 {
                                    if test3 {
                                      if test4 {
                                        if test5 {
                                          if test6 {
                                            test7
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