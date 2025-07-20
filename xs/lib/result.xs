;; Result/Either type for error handling

(module Result
  (export Result Ok Err isOk isErr unwrap unwrapOr mapResult 
          bindResult fromOption resultToOption andThen orElse)
  
  ;; Result型の定義（Either型とも呼ばれる）
  (type Result e a
    (Ok a)
    (Err e))
  
  ;; 成功かチェック
  (let isOk (fn (result)
    (match result
      ((Ok _) true)
      ((Err _) false))))
  
  ;; エラーかチェック
  (let isErr (fn (result)
    (not (isOk result))))
  
  ;; 値を取り出す（エラーの場合は例外）
  (let unwrap (fn (result)
    (match result
      ((Ok value) value)
      ((Err err) (error (string-concat "unwrap called on Err: " (toString err)))))))
  
  ;; 値を取り出す（エラーの場合はデフォルト値）
  (let unwrapOr (fn (result default)
    (match result
      ((Ok value) value)
      ((Err _) default))))
  
  ;; map操作（成功の場合のみ関数を適用）
  (let mapResult (fn (f result)
    (match result
      ((Ok value) (Ok (f value)))
      ((Err err) (Err err)))))
  
  ;; bind操作（モナディックな操作）
  (let bindResult (fn (result f)
    (match result
      ((Ok value) (f value))
      ((Err err) (Err err)))))
  
  ;; andThen（bindResultのエイリアス）
  (let andThen bindResult)
  
  ;; orElse（エラーの場合に別のResultを返す）
  (let orElse (fn (result f)
    (match result
      ((Ok value) (Ok value))
      ((Err err) (f err)))))
  
  ;; Option型からResultへの変換
  (let fromOption (fn (option errorMsg)
    (match option
      ((Some value) (Ok value))
      ((None) (Err errorMsg)))))
  
  ;; Result型からOption型への変換
  (let resultToOption (fn (result)
    (match result
      ((Ok value) (Some value))
      ((Err _) (None)))))
  
  ;; 複数のResultを組み合わせる
  (let sequence (fn (results)
    (sequenceHelper results (list))))
  
  (rec sequenceHelper (results acc)
    (match results
      ((list) (Ok (reverse acc)))
      ((list (Ok value) rest)
        (sequenceHelper rest (cons value acc)))
      ((list (Err err) _)
        (Err err))))
  
  ;; 2つのResultを組み合わせる
  (let combine (fn (result1 result2 f)
    (match result1
      ((Ok value1)
        (match result2
          ((Ok value2) (Ok (f value1 value2)))
          ((Err err) (Err err))))
      ((Err err) (Err err)))))
  
  ;; tryを使った計算（エラーが発生したら早期リターン）
  ;; 実際のdo記法に近い使い方
  (let tryComputation (fn (computation)
    computation))
  
  ;; ヘルパー関数
  (let toString (fn (x)
    ;; 実際にはより洗練された実装が必要
    "<error>"))
  
  (rec reverse (lst)
    (reverseAcc lst (list)))
  
  (rec reverseAcc (lst acc)
    (match lst
      ((list) acc)
      ((list h t) (reverseAcc t (cons h acc)))))
  
  ;; Option型（他で定義されているはずだが念のため）
  (type Option a
    (Some a)
    (None)))