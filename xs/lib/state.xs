-- State monad implementation for XS

module State {
  export State, runState, evalState, execState, get, put, modify,
         stateReturn, stateBind, stateMap
  
  -- State s a = s -> (a, s)
  -- Stateは状態を受け取って値と新しい状態のペアを返す関数
  type State s a =
    | State (\s -> Pair a s)
  
  -- Stateモナドを実行
  let runState state initialState =
    case state of {
      State f -> f initialState
    }
  
  -- 値だけを取得
  let evalState state initialState =
    case runState state initialState of {
      Pair value _ -> value
    }
  
  -- 状態だけを取得
  let execState state initialState =
    case runState state initialState of {
      Pair _ newState -> newState
    }
  
  -- 現在の状態を取得
  let get = State (\s -> Pair s s)
  
  -- 状態を設定
  let put newState = State (\_ -> Pair () newState)
  
  -- 状態を変更
  let modify f = State (\s -> Pair () (f s))
  
  -- return (pure)
  let stateReturn value = State (\s -> Pair value s)
  
  -- bind (>>=)
  let stateBind ma f =
    State (\s ->
      case runState ma s of {
        Pair value newState -> runState (f value) newState
      }
    )
  
  -- fmap
  let stateMap f ma =
    stateBind ma (\a -> stateReturn (f a))
  
  -- ユーティリティ: ペア型（既にあるはずだが念のため）
  type Pair a b =
    | Pair a b
}