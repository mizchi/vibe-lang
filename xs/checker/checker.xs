;; Type checker for XS language

(module TypeChecker
  (export infer typeCheck)
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
        (match (lookupEnv name env)
          ((Some scheme) (Types.instantiate scheme))
          ((None) (error (stringConcat "Undefined variable: " name)))))
      
      ;; Let式
      ((Parser.Let name value)
        (let valueType (infer env value) in
          (let newEnv (extendEnv name (Types.mono valueType) env) in
            valueType)))
      
      ;; 関数適用
      ((Parser.Apply fn args)
        (let fnType (infer env fn) in
          (inferApply env fnType args)))
      
      ;; ラムダ式
      ((Parser.Lambda params body)
        (let paramTypes (map (fn (_) (Types.typeVar)) params) in
          (let newEnv (extendEnvMany params paramTypes env) in
            (let bodyType (infer newEnv body) in
              (makeFunctionType paramTypes bodyType)))))
      
      ;; If式
      ((Parser.If cond then else)
        (let condType (infer env cond) in
          (do
            (unify condType (Types.TBool))
            (let thenType (infer env then) in
              (let elseType (infer env else) in
                (do
                  (unify thenType elseType)
                  thenType))))))
      
      ;; リスト
      ((Parser.List elements)
        (match elements
          ((list) (Types.TList (Types.typeVar)))
          ((list h t)
            (let elemType (infer env h) in
              (do
                (checkListElements env elemType t)
                (Types.TList elemType))))))
      
      ;; その他
      (_ (error "Unsupported expression in type inference"))))
  
  ;; 関数適用の型推論
  (rec inferApply (env fnType args)
    (match args
      ((list) fnType)
      ((list arg restArgs)
        (let argType (infer env arg) in
          (let resultType (Types.typeVar) in
            (do
              (unify fnType (Types.TFunction argType resultType))
              (inferApply env resultType restArgs)))))))
  
  ;; 関数型を構築（カリー化）
  (rec makeFunctionType (paramTypes resultType)
    (match paramTypes
      ((list) resultType)
      ((list p rest)
        (Types.TFunction p (makeFunctionType rest resultType)))))
  
  ;; リストの要素の型をチェック
  (rec checkListElements (env expectedType elements)
    (match elements
      ((list) true)
      ((list h t)
        (let elemType (infer env h) in
          (do
            (unify expectedType elemType)
            (checkListElements env expectedType t))))))
  
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
      (_ (error (stringConcat "Type mismatch: " 
                               (stringConcat (typeToString t1)
                                             (stringConcat " vs " 
                                                           (typeToString t2))))))))
  
  ;; 型環境の操作
  (let emptyEnv (Types.TypeEnv (list)))
  
  (rec lookupEnv (name env)
    (match env
      ((Types.TypeEnv bindings)
        (lookupAlist name bindings))))
  
  (rec lookupAlist (key alist)
    (match alist
      ((list) (None))
      ((list (pair k v) rest)
        (if (stringEq k key)
            (Some v)
            (lookupAlist key rest)))))
  
  (let extendEnv (fn (name scheme env)
    (match env
      ((Types.TypeEnv bindings)
        (Types.TypeEnv (cons (pair name scheme) bindings))))))
  
  (rec extendEnvMany (names types env)
    (match (pair names types)
      ((pair (list) (list)) env)
      ((pair (list n ns) (list t ts))
        (extendEnvMany ns ts 
                        (extendEnv n (Types.mono t) env)))
      (_ (error "Mismatched parameter and type lists"))))
  
  ;; 型を文字列に変換（デバッグ用）
  (rec typeToString (t)
    (match t
      ((Types.TInt) "Int")
      ((Types.TFloat) "Float")
      ((Types.TBool) "Bool")
      ((Types.TString) "String")
      ((Types.TList elem) 
        (stringConcat "List " (typeToString elem)))
      ((Types.TFunction from to)
        (stringConcat "(" 
                      (stringConcat (typeToString from)
                                    (stringConcat " -> "
                                                  (stringConcat (typeToString to) ")")))))
      ((Types.TVar v) v)
      ((Types.TUserDefined name args)
        name)))
  
  ;; 型チェックのメイン関数
  (let typeCheck (fn (expr)
    (infer emptyEnv expr)))
  
  ;; Option型（Types.xsから）
  (type Option a
    (Some a)
    (None)))