;; Lexer implementation using State monad

(module LexerState
  (export tokenizeWithState LexerState)
  (import State)
  (import StringOps)
  (import DoNotation)
  
  ;; レキサーの状態
  (type LexerState
    (LexerState String Int))  ; input, position
  
  ;; 現在位置の文字を取得
  (let currentChar
    (State.State (fn (state)
      (match state
        ((LexerState input pos)
          (if (>= pos (stringLength input))
              (pair (None) state)
              (pair (Some (StringOps.charAt input pos)) state)))))))
  
  ;; 位置を進める
  (let advance
    (State.State (fn (state)
      (match state
        ((LexerState input pos)
          (pair () (LexerState input (+ pos 1))))))))
  
  ;; 文字を読んで進める
  (let readChar
    (DoNotation.>>= currentChar (fn (charOpt)
      (DoNotation.>> advance
        (State.stateReturn charOpt)))))
  
  ;; 条件を満たす間文字を読む
  (rec takeWhile (pred)
    (rec takeWhileAcc (acc)
      (DoNotation.>>= currentChar (fn (charOpt)
        (match charOpt
          ((None) (State.stateReturn (reverse acc)))
          ((Some ch)
            (if (pred ch)
                (DoNotation.>>= readChar (fn (_)
                  (takeWhileAcc (cons ch acc))))
                (State.stateReturn (reverse acc)))))))))
    (takeWhileAcc (list)))
  
  ;; 空白文字をスキップ
  (let skipWhitespace
    (DoNotation.>>= (takeWhile isWhitespace) (fn (_)
      (State.stateReturn ()))))
  
  ;; 数字を読む
  (let readNumber
    (DoNotation.>>= (takeWhile isDigit) (fn (digits)
      (State.stateReturn (stringFromList digits)))))
  
  ;; シンボルを読む
  (let readSymbol
    (DoNotation.>>= currentChar (fn (firstCharOpt)
      (match firstCharOpt
        ((None) (State.stateReturn ""))
        ((Some firstChar)
          (if (isSymbolStart firstChar)
              (DoNotation.>>= readChar (fn (_)
                (DoNotation.>>= (takeWhile isSymbolCont) (fn (rest)
                  (State.stateReturn (stringFromList (cons firstChar rest)))))))
              (State.stateReturn "")))))))
  
  ;; 文字列リテラルを読む
  (rec readString
    (DoNotation.>>= readChar (fn (_)  ; Skip opening quote
      (readStringChars (list)))))
  
  (rec readStringChars (acc)
    (DoNotation.>>= currentChar (fn (charOpt)
      (match charOpt
        ((None) (error "Unterminated string literal"))
        ((Some ch)
          (cond
            ((stringEq ch "\"")
              (DoNotation.>> advance
                (State.stateReturn (stringFromList (reverse acc)))))
            ((stringEq ch "\\")
              (DoNotation.>>= readChar (fn (_)
                (DoNotation.>>= readChar (fn (escapedOpt)
                  (match escapedOpt
                    ((None) (error "Unterminated escape sequence"))
                    ((Some escaped)
                      (readStringChars (cons (unescapeChar escaped) acc)))))))))
            (else
              (DoNotation.>>= readChar (fn (_)
                (readStringChars (cons ch acc)))))))))))
  
  ;; トークンを読む
  (let readToken
    (DoNotation.>>= skipWhitespace (fn (_)
      (DoNotation.>>= currentChar (fn (charOpt)
        (match charOpt
          ((None) (State.stateReturn (EOF)))
          ((Some ch)
            (cond
              ((stringEq ch "(")
                (DoNotation.>> advance (State.stateReturn (LParen))))
              ((stringEq ch ")")
                (DoNotation.>> advance (State.stateReturn (RParen))))
              ((stringEq ch "\"")
                (DoNotation.>>= readString (fn (str)
                  (State.stateReturn (StringLit str)))))
              ((isDigit ch)
                (DoNotation.>>= readNumber (fn (numStr)
                  (State.stateReturn (IntLit (stringToInt numStr))))))
              ((isSymbolStart ch)
                (DoNotation.>>= readSymbol (fn (sym)
                  (State.stateReturn (Symbol sym)))))
              (else
                (error (stringConcat "Unexpected character: " ch)))))))))))
  
  ;; すべてのトークンを読む
  (rec readAllTokens
    (DoNotation.>>= readToken (fn (token)
      (match token
        ((EOF) (State.stateReturn (list token)))
        (_ (DoNotation.>>= readAllTokens (fn (rest)
             (State.stateReturn (cons token rest)))))))))
  
  ;; メイン関数: 文字列をトークン化
  (let tokenizeWithState (fn (input)
    (State.evalState readAllTokens (LexerState input 0))))
  
  ;; ヘルパー関数
  (let isWhitespace (fn (ch)
    (or (stringEq ch " ")
        (or (stringEq ch "\t")
            (or (stringEq ch "\n")
                (stringEq ch "\r"))))))
  
  (let isDigit (fn (ch)
    (and (>= ch "0") (<= ch "9"))))
  
  (let isSymbolStart (fn (ch)
    (or (isAlpha ch)
        (elem ch (list "_" "-" "+" "*" "/" "=" "<" ">" "!" "?" ":" "&" "|")))))
  
  (let isSymbolCont (fn (ch)
    (or (isSymbolStart ch)
        (isDigit ch))))
  
  (let isAlpha (fn (ch)
    (or (and (>= ch "a") (<= ch "z"))
        (and (>= ch "A") (<= ch "Z")))))
  
  ;; 文字のリストから文字列を作成
  (rec stringFromList (chars)
    (match chars
      ((list) "")
      ((list ch rest)
        (stringConcat ch (stringFromList rest)))))
  
  ;; エスケープ文字を処理
  (let unescapeChar (fn (ch)
    (cond
      ((stringEq ch "n") "\n")
      ((stringEq ch "t") "\t")
      ((stringEq ch "r") "\r")
      ((stringEq ch "\\") "\\")
      ((stringEq ch "\"") "\"")
      (else ch))))
  
  ;; リストを逆順に
  (rec reverse (lst)
    (reverseAcc lst (list)))
  
  (rec reverseAcc (lst acc)
    (match lst
      ((list) acc)
      ((list h t) (reverseAcc t (cons h acc)))))
  
  ;; Option型
  (type Option a
    (Some a)
    (None))
  
  ;; Token型（再定義）
  (type Token
    (LParen)
    (RParen)
    (Symbol String)
    (IntLit Int)
    (FloatLit Float)
    (StringLit String)
    (EOF)))