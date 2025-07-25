# Vibe Language - AI 向け高速静的解析言語

## 概要

Vibe 言語は、AI が理解・解析しやすいように設計された静的型付き関数型プログラミング言語です。コンテンツアドレス型のコード管理、純粋関数型設計、そして AI フレンドリーなエラーメッセージにより、AI によるコード理解と生成を最適化します。

## 言語の特徴

### 1. コンテンツアドレス型コードベース（Unison 風）

- すべての式が SHA256 ハッシュで一意に識別される
- 同じコードは常に同じハッシュを生成（決定論的）
- 変更の追跡が容易で、AI が差分を効率的に理解できる
- UCM（Unison Codebase Manager）風の edit/update 機能

### 2. 純粋関数型プログラミング

- 副作用のない純粋関数のみ
- 自動カリー化による部分適用
- 参照透過性により、AI が関数の振る舞いを確実に予測可能
- Perceus 参照カウントによる効率的なメモリ管理

### 3. Haskell 風構文とブロックスコープ

- シェルフレンドリーな読みやすい構文
- ブロックスコープとパイプライン演算子のサポート
- Haskell に基づいた型システムと関数型プログラミング

### 4. Hindley-Milner 型推論

- 明示的な型注釈を最小限に
- 完全な型推論により、AI が型情報を活用しやすい
- Let 多相による柔軟な型システム

### 5. AI フレンドリーなエラーメッセージ

- 構造化されたエラー情報（カテゴリー、提案、メタデータ）
- 型変換の自動提案
- レーベンシュタイン距離による類似変数名の提案
- トークン効率的な英語メッセージ（将来的に多言語化予定）

### 6. 名前空間システム

- 階層的な名前空間（`Math.Utils.fibonacci`）
- コンテンツベースの依存関係管理
- 名前の解決とエイリアス機能
- インクリメンタルな再コンパイル

### 7. 構造的コード変換

- AST コマンドによる安全な変換操作
- Replace、Rename、Extract、Wrap などの基本操作
- 型安全性を保証する変換
- AI やツールからの予測可能な操作

### 8. エフェクトシステム（実装中）

- 拡張可能エフェクト（Extensible Effects）
- 関数レベルでのエフェクト推論
- `perform`構文によるエフェクト実行
- `handle/with`構文によるエフェクトハンドラー（実装予定）
- IO、State、Exception、Async などの組み込みエフェクト

### 9. セマンティック解析フェーズ

- パース後の構造検証
- ブロックごとのエフェクト権限管理
- スコープとキャプチャの解析
- 特殊フォーム（match、do、handle）の検証

### crate の構成

- **vibe-language**: 言語コア（AST 定義、型定義、パーサー、プリティプリンタ、エフェクト定義）
- **vibe-compiler**: コンパイラ（型チェッカー、エフェクト推論、セマンティック解析、メモリ最適化）
- **vibe-runtime**: ランタイム（インタープリター、評価器、エフェクトランタイム）
- **vibe-codebase**: UCM 風のコードベース管理（コードベース、インクリメンタルコンパイル、ブロック属性管理）
- **vibe-shell**: 統合シェル・REPL（Vibe Shell、コマンドラインツール）

### メタデータ管理

- AST とは別にコメントや一時変数ラベルを管理
- NodeId による一意な識別
- コード展開時にメタデータを考慮した整形

## 基本構文

### 命名規則

- **lowerCamelCase**: 変数名、関数名はハイフンなしの lowerCamelCase を使用
- 例: `strConcat`、`intToString`、`foldLeft`（~~`str-concat`~~、~~`int-to-string`~~、~~`fold-left`~~）

```haskell
# 変数定義
let x = 42
let y : Int = 10  # 型注釈（オプション）

# 関数定義（自動カリー化）
let add = fn x y -> x + y
let inc = add 1  # 部分適用

# $演算子（低優先順位関数適用）
print $ 1 + 2              # print (1 + 2)
map double $ [1, 2, 3]     # map double [1, 2, 3]
f $ g $ h x                # f (g (h x)) - 右結合

# letIn構文（ローカルバインディング）
let x = 10 in x + 5  # 結果: 15
let x = 5 in
  let y = 10 in
    x * y  # 結果: 50

# 再帰関数
rec factorial n =
  if (eq n 0) {
    1
  } else {
    n * (factorial (n - 1))
  }

# rec内でletIn使用（内部ヘルパー関数）
rec quicksort lst =
  match lst {
    [] -> []
    pivot :: rest ->
      let smaller = filter (fn x -> x < pivot) rest in
      let larger = filter (fn x -> x >= pivot) rest in
        append (quicksort smaller) (cons pivot (quicksort larger))
  }

# letRec（相互再帰対応）
letRec even n = if (eq n 0) { true } else { odd (n - 1) }
letRec odd n = if (eq n 0) { false } else { even (n - 1) }

# パターンマッチング（ofキーワード不要）
match xs {
  [] -> 0                        # 空リスト
  [h] -> h                       # 単一要素
  h :: t -> 1 + (length t)       # head/tailパターン
}

# 複数要素と残りのパターン
match lst {
  [a, b, c, ...rest] -> a + b + c  # 最初の3要素を取得
  [x, y] -> x + y                   # 2要素のみ
  _ -> 0                            # その他
}

# 代数的データ型
type Option a =
  | None
  | Some a

type Result e a =
  | Error e
  | Ok a

# モジュール
module Math {
  export add, multiply, factorial
  let add = fn x y -> x + y
  ...
}

# インポート
import Math
import List as L

# 名前空間での定義
namespace Math.Utils {
  let fibonacci = rec fib n ->
    if n < 2 {
      n
    } else {
      (fib (n - 1)) + (fib (n - 2))
    }
}

# 完全修飾名でのアクセス
Math.Utils.fibonacci 10

# レコード（オブジェクトリテラル）
let person = { name: "Alice", age: 30 }

# フィールドアクセス
let name = person.name
let age = person.age

# ネストしたレコード
let company = {
  name: "TechCorp",
  address: { city: "Tokyo", zip: "100-0001" }
}

# ネストしたフィールドアクセス
let city = company.address.city

# 関数的な更新（新しいレコードを作成）
let updatedPerson = { name: "Bob", age: person.age }

# エフェクトの使用例
# perform構文でエフェクトを実行
let greet = fn name -> perform IO ("Hello, " ++ name)

# handle構文でエフェクトを処理（実装予定）
handle {
  x <- perform State.get;
  perform State.put (x + 1);
  perform State.get
} {
  State.get () k -> k 0 0    # 初期状態0を返す
  State.put s k -> k () s    # 状態を更新
}
```

## 標準ライブラリ

### core.vibe

- 基本的な関数合成、恒等関数、定数関数
- Maybe/Either 型と関連関数
- ブーリアン演算、数値ヘルパー

### list.vibe

- リスト操作: map, filter, foldLeft, foldRight
- リスト生成: range, replicate
- リスト検索: find, elem, all, any

### math.vibe

- 数学関数: pow, factorial, gcd, lcm
- 数値述語: even, odd, positive, negative
- 統計関数: sum, product, average

### string.vibe

- 文字列操作: concat, join, repeat
- 文字列比較: strEq, strNeq
- 文字列変換: intToString, stringToInt

## Vibe Shell (vsh)

### 基本コマンド

- `help` - ヘルプ表示
- `history [n]` - 評価履歴表示
- `ls [pattern]` - 名前付き式の一覧（パターンフィルタ対応）
- `search <query>` - 型・AST・依存関係による検索
- `find <pattern>` - 名前パターンによる検索
- `add <name> = <expr>` - 式に名前を付けて追加
- `view <name|hash>` - 定義の表示

### 検索機能

- `search type:Int->Int` - 型による検索
- `search ast:match` - AST 構造による検索
- `search dependsOn:foo` - 依存関係による検索

### 使用例

```
xs> let double = fn x -> x * 2
double : Int -> Int

xs> double 21
42

xs> add double_fn = fn x -> x * 2
Added double_fn

xs> search type:Int->Int
Found 3 definitions:
double : Int -> Int [bac2c0f3]
double_fn : Int -> Int [bac2c0f3]
inc : Int -> Int [def456ab]

xs> search ast:match
Found 2 definitions:
quicksort : List a -> List a [abc123de]
findFirst : (a -> Bool) -> List a -> Option a [fed987cb]
```

## エラーメッセージの設計

### エラーカテゴリー

- **SYNTAX**: 構文エラー
- **TYPE**: 型エラー
- **SCOPE**: スコープエラー（未定義変数など）
- **PATTERN**: パターンマッチエラー
- **MODULE**: モジュール関連エラー
- **RUNTIME**: 実行時エラー

### エラー構造

```
ERROR[TYPE]: Type mismatch: expected type 'Int', but found type 'String'
Location: line 3, column 5
Code: x + y
Type mismatch: expected Int, found String
Suggestions:
  1. Convert string to integer using 'int_of_string'
     Replace with: intOfString y
```

## 実装状況

### 完了済み機能

- ✅ Haskell 風パーサー（ブロックスコープ、パイプライン演算子、lowerCamelCase 対応）
- ✅ HM 型推論（完全な型推論サポート）
- ✅ 基本的なインタープリター
- ✅ 統合 CLI ツール (vsh: parse/check/run/test/bench/shell)
- ✅ 高機能 REPL (Vibe Shell with 検索機能)
- ✅ コンテンツアドレス型コードベース
- ✅ 自動カリー化と部分適用
- ✅ 標準ライブラリ（core, list, math, string）
- ✅ パターンマッチング（`::` 演算子、リストパターン）
- ✅ レコード型（オブジェクトリテラル）
- ✅ 代数的データ型
- ✅ モジュールシステム（基本実装）
- ✅ AST メタデータ管理
- ✅ AI フレンドリーなエラーメッセージ
- ✅ 階層的な名前空間システム
- ✅ 関数単位の依存関係追跡（型定義含む）
- ✅ AST コマンドによる構造的変換
- ✅ インクリメンタル型チェック
- ✅ 差分テスト実行システム
- ✅ match 構文の統一化（case/of キーワード廃止）
- ✅ ==演算子のサポート
- ✅ エフェクトシステム（基本実装）
- ✅ セマンティック解析フェーズ
- ✅ AST/型による構造化検索
- ✅ ハッシュ参照（`#abc123`）
- ✅ バージョン指定インポート（`import Math@abc123`）
- ✅ 型推論結果の自動埋め込み
- ✅ 省略可能なパラメータ（`param?:Type?`）
- ✅ 新しい関数定義構文（`let func x:Int y:Int -> Int = x + y`）
- ✅ Option 型の糖衣構文（`String?`）
- ✅ $演算子（Haskell 風の低優先順位関数適用）

### 開発中/計画中

- 🚧 **新パーサーへの移行作業中**
  - 実験的なGLLパーサーベースの統一文法を実装中
  - `vibe-language/src/parser/experimental/`にて開発
  - 統一構文: `let`バインディング、`case`式、`if-then-else`、パイプライン演算子
  - SPPFからASTへの変換実装が必要
- 📋 do 記法の完全実装
- 📋 handle/with 構文の完全実装
- 📋 エフェクト多相性
- 📋 統一文法の完全実装（keyword_form）
- 📋 構造化シェルのパイプライン処理
- 📋 実行権限システム（エフェクトベース）
- 📋 WASI サンドボックス
- 📋 並列実行サポート
- 📋 より高度な型システム（GADTs、型クラスなど）

## パフォーマンス

- インクリメンタルコンパイル（Salsa 使用）
- Perceus 参照カウントによる効率的な GC
- WebAssembly GC ターゲット
- 型チェッカーベンチマーク実装済み

## テストカバレッジ

現在のテストカバレッジ: 76.63%

## 開発方針

1. **AI ファースト**: すべての設計判断は AI による理解・生成を優先
2. **純粋性**: 副作用を排除し、予測可能な動作を保証
3. **効率性**: 静的解析の高速化を重視
4. **拡張性**: 将来の機能追加を考慮したモジュラー設計

## 開発プラクティス

### テスト駆動開発

各ステップでは以下のテストを実行することを推奨します：

1. **型チェックとコンパイル**

   ```bash
   cargo check --all
   cargo build --all
   ```

2. **ユニットテスト**

   ```bash
   cargo test --all
   ```

3. **XS コード（セルフホスティング部分）のテスト**

   ```bash
   # vshを使用したテスト実行
   cargo run -p vsh --bin vsh -- test

   # 特定のファイルのテスト
   cargo run -p vsh --bin vsh -- test tests/xs_tests/

   # または Makefile を使用
   make test-xs
   ```

### コード品質管理

リファクタリング時には以下のツールを使用してコード品質を維持：

1. **Clippy（Rust の静的解析ツール）**

   ```bash
   cargo clippy --all -- -D warnings
   ```

2. **similarity-rs（重複コード検出）**
   ```bash
   # 重複コードの検出と除去
   cargo install similarity
   similarity check src/
   ```

### 推奨される開発フロー

1. 機能の追加・修正前に既存のテストが通ることを確認
2. 新機能のテストを先に書く（TDD）
3. 実装後、すべてのテストが通ることを確認
4. Clippy でコード品質をチェック
5. 重複コードがないか確認
6. ドキュメントを更新

## 今後の展望

- マルチコア CPU での並列実行
- より高度な型システム（依存型、線形型など）
- ビジュアルプログラミング対応
- AI による自動最適化
- 分散コードベース対応

---

# Claude Code Spec-Driven Development

This project implements Kiro-style Spec-Driven Development for Claude Code using hooks and slash commands.

## Project Context

### Project Steering

- Product overview: `.kiro/steering/product.md`
- Technology stack: `.kiro/steering/tech.md`
- Project structure: `.kiro/steering/structure.md`
- Custom steering docs for specialized contexts

### Active Specifications

- Current spec: Check `.kiro/specs/` for active specifications
- Use `/kiro:spec-status [feature-name]` to check progress

## Development Guidelines

- Think in English, generate responses in English

## Spec-Driven Development Workflow

### Phase 0: Steering Generation (Recommended)

#### Kiro Steering (`.kiro/steering/`)

```
/kiro:steering               # Intelligently create or update steering documents
/kiro:steering-custom        # Create custom steering for specialized contexts
```

**Steering Management:**

- **`/kiro:steering`**: Unified command that intelligently detects existing files and handles them appropriately. Creates new files if needed, updates existing ones while preserving user customizations.

**Note**: For new features or empty projects, steering is recommended but not required. You can proceed directly to spec-requirements if needed.

### Phase 1: Specification Creation

```
/kiro:spec-init [feature-name]           # Initialize spec structure only
/kiro:spec-requirements [feature-name]   # Generate requirements → Review → Edit if needed
/kiro:spec-design [feature-name]         # Generate technical design → Review → Edit if needed
/kiro:spec-tasks [feature-name]          # Generate implementation tasks → Review → Edit if needed
```

### Phase 2: Progress Tracking

```
/kiro:spec-status [feature-name]         # Check current progress and phases
```

## Spec-Driven Development Workflow

Kiro's spec-driven development follows a strict **3-phase approval workflow**:

### Phase 1: Requirements Generation & Approval

1. **Generate**: `/kiro:spec-requirements [feature-name]` - Generate requirements document
2. **Review**: Human reviews `requirements.md` and edits if needed
3. **Approve**: Manually update `spec.json` to set `"requirements": true`

### Phase 2: Design Generation & Approval

1. **Generate**: `/kiro:spec-design [feature-name]` - Generate technical design (requires requirements approval)
2. **Review**: Human reviews `design.md` and edits if needed
3. **Approve**: Manually update `spec.json` to set `"design": true`

### Phase 3: Tasks Generation & Approval

1. **Generate**: `/kiro:spec-tasks [feature-name]` - Generate implementation tasks (requires design approval)
2. **Review**: Human reviews `tasks.md` and edits if needed
3. **Approve**: Manually update `spec.json` to set `"tasks": true`

### Implementation

Only after all three phases are approved can implementation begin.

**Key Principle**: Each phase requires explicit human approval before proceeding to the next phase, ensuring quality and accuracy throughout the development process.

## Development Rules

1. **Consider steering**: Run `/kiro:steering` before major development (optional for new features)
2. **Follow the 3-phase approval workflow**: Requirements → Design → Tasks → Implementation
3. **Manual approval required**: Each phase must be explicitly approved by human review
4. **No skipping phases**: Design requires approved requirements; Tasks require approved design
5. **Update task status**: Mark tasks as completed when working on them
6. **Keep steering current**: Run `/kiro:steering` after significant changes
7. **Check spec compliance**: Use `/kiro:spec-status` to verify alignment

## Automation

This project uses Claude Code hooks to:

- Automatically track task progress in tasks.md
- Check spec compliance
- Preserve context during compaction
- Detect steering drift

### Task Progress Tracking

When working on implementation:

1. **Manual tracking**: Update tasks.md checkboxes manually as you complete tasks
2. **Progress monitoring**: Use `/kiro:spec-status` to view current completion status
3. **TodoWrite integration**: Use TodoWrite tool to track active work items
4. **Status visibility**: Checkbox parsing shows completion percentage

## Getting Started

1. Initialize steering documents: `/kiro:steering`
2. Create your first spec: `/kiro:spec-init [your-feature-name]`
3. Follow the workflow through requirements, design, and tasks

## Kiro Steering Details

Kiro-style steering provides persistent project knowledge through markdown files:

### Core Steering Documents

- **product.md**: Product overview, features, use cases, value proposition
- **tech.md**: Architecture, tech stack, dev environment, commands, ports
- **structure.md**: Directory organization, code patterns, naming conventions

### Custom Steering

Create specialized steering documents for:

- API standards
- Testing approaches
- Code style guidelines
- Security policies
- Database conventions
- Performance standards
- Deployment workflows

### Inclusion Modes

- **Always Included**: Loaded in every interaction (default)
- **Conditional**: Loaded for specific file patterns (e.g., `"*.test.js"`)
- **Manual**: Loaded on-demand with `#filename` reference

## Kiro Steering Configuration

### Current Steering Files

The `/kiro:steering` command manages these files automatically. Manual updates to this section reflect changes made through steering commands.

### Active Steering Files

- `product.md`: Always included - Product context and business objectives
- `tech.md`: Always included - Technology stack and architectural decisions
- `structure.md`: Always included - File organization and code patterns

### Custom Steering Files

<!-- Added by /kiro:steering-custom command -->
<!-- Example entries:
- `api-standards.md`: Conditional - `"src/api/**/*"`, `"**/*api*"` - API design guidelines
- `testing-approach.md`: Conditional - `"**/*.test.*"`, `"**/spec/**/*"` - Testing conventions
- `security-policies.md`: Manual - Security review guidelines (reference with @security-policies.md)
-->

### Usage Notes

- **Always files**: Automatically loaded in every interaction
- **Conditional files**: Loaded when working on matching file patterns
- **Manual files**: Reference explicitly with `@filename.md` syntax when needed
- **Updating**: Use `/kiro:steering` or `/kiro:steering-custom` commands to modify this configuration
