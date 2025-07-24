-- Result/Either type for error handling

module Result {
  export Result, Ok, Err, isOk, isErr, unwrap, unwrapOr, mapResult, 
         bindResult, fromOption, resultToOption, andThen, orElse
  
  -- Result型の定義（Either型とも呼ばれる）
  type Result e a =
    | Ok a
    | Err e
  
  -- 成功かチェック
  let isOk = \result ->
    case result of {
      Ok _ -> true;
      Err _ -> false
    }
  
  -- エラーかチェック
  let isErr = \result ->
    not (isOk result)
  
  -- 値を取り出す（エラーの場合は例外）
  let unwrap = \result ->
    case result of {
      Ok value -> value;
      Err err -> error (String.concat "unwrap called on Err: " (toString err))
    }
  
  -- 値を取り出す（エラーの場合はデフォルト値）
  let unwrapOr = \result default ->
    case result of {
      Ok value -> value;
      Err _ -> default
    }
  
  -- map操作（成功の場合のみ関数を適用）
  let mapResult = \f result ->
    case result of {
      Ok value -> Ok (f value);
      Err err -> Err err
    }
  
  -- bind操作（モナディックな操作）
  let bindResult = \result f ->
    case result of {
      Ok value -> f value;
      Err err -> Err err
    }
  
  -- andThen（bindResultのエイリアス）
  let andThen = bindResult
  
  -- orElse（エラーの場合に別のResultを返す）
  let orElse = \result f ->
    case result of {
      Ok value -> Ok value;
      Err err -> f err
    }
  
  -- Option型からResultへの変換
  let fromOption = \option errorMsg ->
    case option of {
      Some value -> Ok value;
      None -> Err errorMsg
    }
  
  -- Result型からOption型への変換
  let resultToOption = \result ->
    case result of {
      Ok value -> Some value;
      Err _ -> None
    }
  
  -- 複数のResultを組み合わせる
  let sequence = \results ->
    sequenceHelper results []
  
  rec sequenceHelper results acc =
    case results of {
      [] -> Ok (reverse acc);
      Ok value :: rest -> sequenceHelper rest (cons value acc);
      Err err :: _ -> Err err
    }
  
  -- 2つのResultを組み合わせる
  let combine = \result1 result2 f ->
    case result1 of {
      Ok value1 ->
        case result2 of {
          Ok value2 -> Ok (f value1 value2);
          Err err -> Err err
        };
      Err err -> Err err
    }
  
  -- tryを使った計算（エラーが発生したら早期リターン）
  -- 実際のdo記法に近い使い方
  let tryComputation = \computation ->
    computation
  
  -- ヘルパー関数
  let toString = \x ->
    -- 実際にはより洗練された実装が必要
    "<error>"
  
  rec reverse lst =
    reverseAcc lst []
  
  rec reverseAcc lst acc =
    case lst of {
      [] -> acc;
      h :: t -> reverseAcc t (cons h acc)
    }
  
  -- Option型（他で定義されているはずだが念のため）
  type Option a =
    | Some a
    | None
}