;; XS Language Lexer Implementation
;; S式のレキサーをXS言語で実装

(module Lexer
  (export Token TokenType tokenize)
  
  ;; トークンの型定義
  (type TokenType
    (LParen)      ; (
    (RParen)      ; )
    (Symbol String)
    (IntLit Int)
    (FloatLit Float)
    (StringLit String)
    (Comment String)
    (EOF))
  
  ;; トークン構造体
  (type Token
    (Token TokenType Int Int)) ; type, start, end
  
  ;; 文字が空白文字かチェック
  (let isWhitespace (fn (ch)
    (match ch
      (" " true)
      ("\t" true)
      ("\n" true)
      ("\r" true)
      (_ false))))
  
  ;; 文字が数字かチェック
  (let isDigit (fn (ch)
    (and (>= ch "0") (<= ch "9"))))
  
  ;; 文字がシンボルの開始文字かチェック
  (let isSymbolStart (fn (ch)
    (or (and (>= ch "a") (<= ch "z"))
        (or (and (>= ch "A") (<= ch "Z"))
            (elem ch (list "_" "-" "+" "*" "/" "=" "<" ">" "!" "?" ":" "&" "|"))))))
  
  ;; 文字がシンボルの継続文字かチェック
  (let isSymbolCont (fn (ch)
    (or (isSymbolStart ch)
        (isDigit ch))))
  
  ;; 文字列をトークンリストに変換
  (rec tokenize (input)
    (tokenizeWithPos input 0))
  
  ;; 位置情報付きでトークン化
  (rec tokenizeWithPos (input pos)
    (if (>= pos (stringLength input))
        (list (Token (EOF) pos pos))
        (let ch (stringAt input pos) in
          (cond
            ;; 空白文字はスキップ
            ((isWhitespace ch)
              (tokenizeWithPos input (+ pos 1)))
            
            ;; 左括弧
            ((stringEq ch "(")
              (cons (Token (LParen) pos (+ pos 1))
                    (tokenizeWithPos input (+ pos 1))))
            
            ;; 右括弧
            ((stringEq ch ")")
              (cons (Token (RParen) pos (+ pos 1))
                    (tokenizeWithPos input (+ pos 1))))
            
            ;; コメント
            ((stringEq ch ";")
              (let comment-end (findLineEnd input (+ pos 1)) in
                (let comment-text (stringSlice input (+ pos 1) comment-end) in
                  (cons (Token (Comment comment-text) pos comment-end)
                        (tokenizeWithPos input comment-end)))))
            
            ;; 文字列リテラル
            ((stringEq ch "\"")
              (let string-end (findStringEnd input (+ pos 1)) in
                (if (< string-end 0)
                    (error "Unterminated string literal")
                    (let string-content (stringSlice input (+ pos 1) string-end) in
                      (cons (Token (StringLit string-content) pos (+ string-end 1))
                            (tokenizeWithPos input (+ string-end 1)))))))
            
            ;; 数値リテラル（簡易版）
            ((isDigit ch)
              (let num-end (findNumberEnd input pos) in
                (let num-str (stringSlice input pos num-end) in
                  (if (stringContains num-str ".")
                      (cons (Token (FloatLit (stringToFloat num-str)) pos num-end)
                            (tokenizeWithPos input num-end))
                      (cons (Token (IntLit (stringToInt num-str)) pos num-end)
                            (tokenizeWithPos input num-end))))))
            
            ;; シンボル
            ((isSymbolStart ch)
              (let sym-end (findSymbolEnd input pos) in
                (let sym-str (stringSlice input pos sym-end) in
                  (cons (Token (Symbol sym-str) pos sym-end)
                        (tokenizeWithPos input sym-end)))))
            
            ;; 不明な文字
            (else
              (error (stringConcat "Unexpected character: " ch)))))))
  
  ;; 行末を見つける
  (rec findLineEnd (input pos)
    (if (>= pos (stringLength input))
        pos
        (if (stringEq (stringAt input pos) "\n")
            pos
            (findLineEnd input (+ pos 1)))))
  
  ;; 文字列の終端を見つける
  (rec findStringEnd (input pos)
    (if (>= pos (stringLength input))
        -1  ; エラー: 終端なし
        (let ch (stringAt input pos) in
          (cond
            ((stringEq ch "\"") pos)
            ((stringEq ch "\\") 
              (findStringEnd input (+ pos 2)))  ; エスケープ文字をスキップ
            (else
              (findStringEnd input (+ pos 1)))))))
  
  ;; 数値の終端を見つける
  (rec findNumberEnd (input pos)
    (if (>= pos (stringLength input))
        pos
        (let ch (stringAt input pos) in
          (if (or (isDigit ch) (stringEq ch "."))
              (findNumberEnd input (+ pos 1))
              pos))))
  
  ;; シンボルの終端を見つける
  (rec findSymbolEnd (input pos)
    (if (>= pos (stringLength input))
        pos
        (let ch (stringAt input pos) in
          (if (isSymbolCont ch)
              (findSymbolEnd input (+ pos 1))
              pos)))))