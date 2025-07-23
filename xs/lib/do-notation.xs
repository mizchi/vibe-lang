-- do notation for monadic operations

module DoNotation {
  export doState, seq, bind, then, return
  import State
  
  -- Stateモナド用のdo記法ヘルパー
  -- 実際にはマクロとして実装すべきだが、関数として近似
  
  -- bind演算子 (>>= は予約語の可能性があるのでbindと命名)
  let bind = State.stateBind
  
  -- sequence演算子（値を無視）(>> は予約語の可能性があるのでthenと命名)
  let then ma mb = bind ma (\_ -> mb)
  
  -- return
  let return = State.stateReturn
  
  -- 連続したState操作を実行
  -- doState :: [State s a] -> State s a
  rec doState actions =
    case actions of {
      [] -> return ()
      [action] -> action
      action :: rest -> then action (doState rest)
    }
  
  -- seq: 複数のアクションを順次実行し、最後の値を返す
  rec seq actions =
    case actions of {
      [] -> error "seq requires at least one action"
      [action] -> action
      action :: rest -> bind action (\_ -> seq rest)
    }
}