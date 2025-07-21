# XS Language Runtime Architecture Analysis

## 現状の責務分析

### 1. xs-compiler (memory optimization module)
**役割**: AST → IR変換 + メモリ管理の準備
- ASTからIRへの変換を担当
- 将来的にはPerceus参照カウント管理（drop/dup挿入）を実装予定
- 現在は単純なIR変換のみ実装

**問題点**:
- メモリ管理の実装が未完成
- IR表現が基本的すぎる（型情報やメモリ管理情報が不足）

### 2. xs-runtime
**役割**: AST直接実行
- ASTを直接評価（tree-walking interpreter）
- ビルトイン関数のランタイム実装
- パターンマッチングの実行
- クロージャとRecClosureの管理
- 環境（Environment）による変数管理

**問題点**:
- AST直接実行なので最適化が困難
- PerceusやWebAssemblyとの統合パスがない

### 3. xs-workspace (incremental compilation)
**役割**: インクリメンタルコンパイルのキャッシュ層
- ファイル単位でのパース・型チェック結果のキャッシュ
- 変更検知と差分コンパイル

**問題点**:
- 現在はパースと型チェックのみ対応
- IR生成やコード生成のキャッシュは未実装

### 4. xs-wasm
**役割**: IR → WebAssembly変換と実行
- IRからWebAssembly（GC付き）への変換
- WebAssembly Text Format (WAT) の生成
- Wasmtimeを使った実行環境
- テストランナーフレームワーク

**問題点**:
- ビルトイン関数の実装が不完全
- GC型の活用が不十分（プレースホルダーのみ）
- クロージャやリストの実装が未完成

## 統合計画

### Phase 1: ランタイムアーキテクチャの明確化

```
[Source] → [Parser] → [Type Checker] → [Perceus] → [IR] → [Backend] → [Runtime]
                          ↓                                       ↓
                    [xs_salsa cache]                    [Interpreter/WASM]
```

### Phase 2: IR（中間表現）の強化

1. **型付きIR (Typed IR)**
   ```rust
   pub enum TypedIrExpr {
       Literal { value: Literal, ty: Type },
       Var { name: String, ty: Type },
       Let { name: String, value: Box<TypedIrExpr>, body: Box<TypedIrExpr>, ty: Type },
       // ...
   }
   ```

2. **メモリ管理情報付きIR**
   ```rust
   pub enum MemoryOp {
       Drop(String),    // 参照カウント減少
       Dup(String),     // 参照カウント増加
       Reuse(String),   // メモリ再利用
   }
   ```

### Phase 3: バックエンドの統一インターフェース

```rust
pub trait Backend {
    type Output;
    type Error;
    
    fn compile(&mut self, ir: &TypedIrExpr) -> Result<Self::Output, Self::Error>;
    fn execute(&self, compiled: &Self::Output) -> Result<Value, RuntimeError>;
}

// インタープリター実装
pub struct InterpreterBackend;
impl Backend for InterpreterBackend {
    type Output = TypedIrExpr;
    // IR を直接実行
}

// WebAssembly実装
pub struct WasmBackend;
impl Backend for WasmBackend {
    type Output = WasmModule;
    // WebAssemblyにコンパイルして実行
}
```

### Phase 4: ビルトイン関数の統一実装

```rust
pub trait BuiltinFunction {
    fn name(&self) -> &str;
    fn type_signature(&self) -> Type;
    fn interpret(&self, args: &[Value]) -> Result<Value, RuntimeError>;
    fn compile_to_wasm(&self, args: &[WasmInstr]) -> Vec<WasmInstr>;
}

// 例: 加算関数
pub struct AddFunction;
impl BuiltinFunction for AddFunction {
    fn name(&self) -> &str { "+" }
    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int)))
        )
    }
    fn interpret(&self, args: &[Value]) -> Result<Value, RuntimeError> {
        match args {
            [Value::Int(a), Value::Int(b)] => Ok(Value::Int(a + b)),
            _ => Err(RuntimeError::TypeMismatch)
        }
    }
    fn compile_to_wasm(&self, args: &[WasmInstr]) -> Vec<WasmInstr> {
        vec![
            args[0].clone(),
            args[1].clone(),
            WasmInstr::I64Add,
        ]
    }
}
```

### Phase 5: 実装順序

1. **IR層の強化** (perceus/src/ir.rs)
   - TypedIrExprの実装
   - 型情報の保持
   - メモリ管理情報の追加

2. **ビルトインの統一** (runtime/src/builtins.rs)
   - BuiltinFunctionトレイトの実装
   - 全ビルトイン関数の移行

3. **バックエンド統一** (runtime/src/backend.rs)
   - Backendトレイトの実装
   - InterpreterBackendの実装
   - WasmBackendの改善

4. **Perceusメモリ管理** (perceus/src/memory.rs)
   - 参照カウント解析
   - Drop/Dup挿入
   - Reuse最適化

5. **xs_salsa統合** (xs_salsa/src/lib.rs)
   - IR生成のキャッシュ
   - コンパイル結果のキャッシュ

### Phase 6: 最終的なディレクトリ構造

```
xs-lang-v3/
├── xs_core/          # 基本的な型定義
├── parser/           # パーサー
├── checker/          # 型チェッカー
├── perceus/          # Perceus変換（AST→IR）
├── runtime/          # 統一ランタイム
│   ├── src/
│   │   ├── lib.rs
│   │   ├── ir.rs          # 型付きIR定義
│   │   ├── backend.rs     # バックエンドトレイト
│   │   ├── interpreter.rs # インタープリターバックエンド
│   │   ├── builtins.rs    # ビルトイン関数
│   │   └── value.rs       # ランタイム値
├── wasm_backend/     # WebAssemblyバックエンド
├── xs_salsa/         # インクリメンタルコンパイル
└── cli/              # CLIツール
```

## 優先実装事項

1. **ビルトイン関数の統一実装**
   - 現在interpreterに散らばっている実装を統一
   - WebAssemblyでも動作するように

2. **型付きIRの実装**
   - 型情報を保持したIR
   - バックエンド間での共通表現

3. **基本的なWebAssembly実行**
   - 算術演算の完全実装
   - print関数の実装（WASI使用）

これにより、AIがコードを理解・生成する際に一貫性のあるアーキテクチャを提供できます。