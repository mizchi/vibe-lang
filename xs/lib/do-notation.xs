;; do notation for monadic operations

(module DoNotation
  (export doState seq >>= >> return)
  (import State)
  
  ;; Stateモナド用のdo記法ヘルパー
  ;; 実際にはマクロとして実装すべきだが、関数として近似
  
  ;; bind演算子
  (let >>= State.stateBind)
  
  ;; sequence演算子（値を無視）
  (let >> (fn (ma mb)
    (>>= ma (fn (_) mb))))
  
  ;; return
  (let return State.stateReturn)
  
  ;; 連続したState操作を実行
  ;; doState :: [State s a] -> State s a
  (rec doState (actions)
    (match actions
      ((list) (return ()))
      ((list action) action)
      ((list action rest)
        (>> action (doState rest)))))
  
  ;; seq: 複数のアクションを順次実行し、最後の値を返す
  (rec seq (actions)
    (match actions
      ((list) (error "seq requires at least one action"))
      ((list action) action)
      ((list action rest)
        (>>= action (fn (_) (seq rest)))))))