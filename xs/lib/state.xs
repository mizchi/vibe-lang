;; State monad implementation for XS

(module State
  (export State runState evalState execState get put modify 
          stateReturn stateBind stateMap)
  
  ;; State s a = s -> (a, s)
  ;; Stateは状態を受け取って値と新しい状態のペアを返す関数
  (type State s a
    (State (fn (s) (pair a s))))
  
  ;; Stateモナドを実行
  (let runState (fn (state initialState)
    (match state
      ((State f) (f initialState)))))
  
  ;; 値だけを取得
  (let evalState (fn (state initialState)
    (match (runState state initialState)
      ((pair value _) value))))
  
  ;; 状態だけを取得
  (let execState (fn (state initialState)
    (match (runState state initialState)
      ((pair _ newState) newState))))
  
  ;; 現在の状態を取得
  (let get
    (State (fn (s) (pair s s))))
  
  ;; 状態を設定
  (let put (fn (newState)
    (State (fn (_) (pair () newState)))))
  
  ;; 状態を変更
  (let modify (fn (f)
    (State (fn (s) (pair () (f s))))))
  
  ;; return (pure)
  (let stateReturn (fn (value)
    (State (fn (s) (pair value s)))))
  
  ;; bind (>>=)
  (let stateBind (fn (ma f)
    (State (fn (s)
      (match (runState ma s)
        ((pair value newState)
          (runState (f value) newState)))))))
  
  ;; fmap
  (let stateMap (fn (f ma)
    (stateBind ma (fn (a) (stateReturn (f a))))))
  
  ;; ユーティリティ: ペア型（既にあるはずだが念のため）
  (type Pair a b
    (pair a b)))