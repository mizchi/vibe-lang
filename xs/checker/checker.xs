;; Type checker for XS language

(module TypeChecker
  (export infer type-check)
  (import Types)
  (import Parser)
  
  ;; 型推論のメイン関数
  (rec infer (env expr)
    (match expr
      ;; リテラル
      ((Parser.IntLit _) (Types.TInt))
      ((Parser.FloatLit _) (Types.TFloat))
      ((Parser.StringLit _) (Types.TString))
      
      ;; 変数参照
      ((Parser.Symbol name)
        (match (lookup-env name env)
          ((Some scheme) (Types.instantiate scheme))
          ((None) (error (string-concat "Undefined variable: " name)))))
      
      ;; Let式
      ((Parser.Let name value)
        (let value-type (infer env value) in
          (let new-env (extend-env name (Types.mono value-type) env) in
            value-type)))
      
      ;; 関数適用
      ((Parser.Apply fn args)
        (let fn-type (infer env fn) in
          (infer-apply env fn-type args)))
      
      ;; ラムダ式
      ((Parser.Lambda params body)
        (let param-types (map (fn (_) (Types.type-var)) params) in
          (let new-env (extend-env-many params param-types env) in
            (let body-type (infer new-env body) in
              (make-function-type param-types body-type)))))
      
      ;; If式
      ((Parser.If cond then else)
        (let cond-type (infer env cond) in
          (do
            (unify cond-type (Types.TBool))
            (let then-type (infer env then) in
              (let else-type (infer env else) in
                (do
                  (unify then-type else-type)
                  then-type))))))
      
      ;; リスト
      ((Parser.List elements)
        (match elements
          ((list) (Types.TList (Types.type-var)))
          ((list h t)
            (let elem-type (infer env h) in
              (do
                (check-list-elements env elem-type t)
                (Types.TList elem-type))))))
      
      ;; その他
      (_ (error "Unsupported expression in type inference"))))
  
  ;; 関数適用の型推論
  (rec infer-apply (env fn-type args)
    (match args
      ((list) fn-type)
      ((list arg rest-args)
        (let arg-type (infer env arg) in
          (let result-type (Types.type-var) in
            (do
              (unify fn-type (Types.TFunction arg-type result-type))
              (infer-apply env result-type rest-args)))))))
  
  ;; 関数型を構築（カリー化）
  (rec make-function-type (param-types result-type)
    (match param-types
      ((list) result-type)
      ((list p rest)
        (Types.TFunction p (make-function-type rest result-type)))))
  
  ;; リストの要素の型をチェック
  (rec check-list-elements (env expected-type elements)
    (match elements
      ((list) true)
      ((list h t)
        (let elem-type (infer env h) in
          (do
            (unify expected-type elem-type)
            (check-list-elements env expected-type t))))))
  
  ;; 型の単一化（簡易版）
  (rec unify (t1 t2)
    (match (pair t1 t2)
      ;; 同じ基本型
      ((pair (Types.TInt) (Types.TInt)) true)
      ((pair (Types.TFloat) (Types.TFloat)) true)
      ((pair (Types.TBool) (Types.TBool)) true)
      ((pair (Types.TString) (Types.TString)) true)
      
      ;; リスト型
      ((pair (Types.TList a) (Types.TList b))
        (unify a b))
      
      ;; 関数型
      ((pair (Types.TFunction a1 r1) (Types.TFunction a2 r2))
        (do
          (unify a1 a2)
          (unify r1 r2)))
      
      ;; 型変数（簡易版 - occurs checkなし）
      ((pair (Types.TVar v) t) true)  ; 本来は置換を記録
      ((pair t (Types.TVar v)) true)
      
      ;; 型が合わない
      (_ (error (string-concat "Type mismatch: " 
                               (string-concat (type-to-string t1)
                                             (string-concat " vs " 
                                                           (type-to-string t2))))))))
  
  ;; 型環境の操作
  (let empty-env (Types.TypeEnv (list)))
  
  (rec lookup-env (name env)
    (match env
      ((Types.TypeEnv bindings)
        (lookup-alist name bindings))))
  
  (rec lookup-alist (key alist)
    (match alist
      ((list) (None))
      ((list (pair k v) rest)
        (if (string-eq k key)
            (Some v)
            (lookup-alist key rest)))))
  
  (let extend-env (fn (name scheme env)
    (match env
      ((Types.TypeEnv bindings)
        (Types.TypeEnv (cons (pair name scheme) bindings))))))
  
  (rec extend-env-many (names types env)
    (match (pair names types)
      ((pair (list) (list)) env)
      ((pair (list n ns) (list t ts))
        (extend-env-many ns ts 
                        (extend-env n (Types.mono t) env)))
      (_ (error "Mismatched parameter and type lists"))))
  
  ;; 型を文字列に変換（デバッグ用）
  (rec type-to-string (t)
    (match t
      ((Types.TInt) "Int")
      ((Types.TFloat) "Float")
      ((Types.TBool) "Bool")
      ((Types.TString) "String")
      ((Types.TList elem) 
        (string-concat "List " (type-to-string elem)))
      ((Types.TFunction from to)
        (string-concat "(" 
                      (string-concat (type-to-string from)
                                    (string-concat " -> "
                                                  (string-concat (type-to-string to) ")")))))
      ((Types.TVar v) v)
      ((Types.TUserDefined name args)
        name)))
  
  ;; 型チェックのメイン関数
  (let type-check (fn (expr)
    (infer empty-env expr)))
  
  ;; Option型（Types.xsから）
  (type Option a
    (Some a)
    (None)))