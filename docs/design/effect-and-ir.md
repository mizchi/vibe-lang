# Koka ベースの Effect System + コンテンツアドレッシングに基づく型と IR 設計

## 概要

本ドキュメントは、Koka 言語の row 型による Effect System をベースに、Unison のようなコンテンツアドレッシング機構を導入し、WebAssembly (Wasm) 上で実行可能な中間表現 (IR) を設計することを目的とする。

---

## 1. 言語設計の目標

- **型安全な副作用管理**：副作用を型レベルで静的に追跡（Koka 式 Effect Row）
- **柔軟なハンドラ解釈**：Algebraic Effect + Resume をサポート
- **構文・意味の分離**：DSL 定義と handler の分離、意味付けの自由度を確保
- **コンテンツアドレッシング**：型・効果・構文木を含めた deterministic な識別
- **Wasm ターゲット**：実行系を WebAssembly VM 上で構築可能にする
- **パーミッションベースの実行制御**：Deno のような効果スコープの制限とハンドラ注入による安全な実行
- **WasmFX の活用検討**：WebAssembly における typed continuation と effect handler 機構である WasmFX を活用し、`resume` のネイティブな表現と効率的な実行モデルを実現する

---

## 2. 型システム

### 2.1 関数型の拡張

```ts
// 通常の関数型
(Int) -> String

// 効果付き関数型
(Int) ->{IO, Log} String
```

- `->{...}` に効果 row を含めることで、関数が使用する副作用を明示
- `EffectRow = Set<string>` により、静的な効果制約の合成と推論を可能にする

### 2.2 Algebraic Effect の定義（ADT）

```ts
effect Http {
  get : string -> string
}

effect Fs {
  read : string -> string
}
```

これは ADT として内部表現され、Free Effect 的構文木を構築するための命令セットになる。

### 2.3 パーミッション付き Handler

```ts
type Permission =
  | { tag: "FsRead"; paths: Glob[] }
  | { tag: "HttpGet"; domains: string[] };

type EffectHandler = {
  name: string;
  permissions: Permission[];
  handlerImpl: Record<string, (...args: any[]) => Step>;
};
```

- handler は `with FsHandler { ... }` のようにスコープ注入され、

  - `EffectCall` の実行時に必要なパーミッションを満たしているか検査される。
  - 実行時に `PermissionDenied` エラーが発生する可能性も型で追跡可能（例: `->{Fs, PermissionError}`）

---

## 3. 中間表現（IR）

### 3.1 Term ノード

```ts
type Term<A> =
  | Literal<A>
  | Var<string>
  | Lambda<string, Term<A>>
  | Apply<Term<any>, Term<any>>
  | Let<string, Term<any>, Term<A>>
  | EffectCall<Tag, Value[]>
  | Handle<Tag, Term<A>, HandlerCase[]>;
```

### 3.2 HandlerCase

```ts
type HandlerCase = {
  tag: string;
  params: string[];
  resumeVar: string;
  body: Term<any>;
};
```

### 3.3 型付き関数定義

```ts
type FuncDef = {
  name: string;
  type: Type<A>;
  effects: EffectRow;
  body: Term<A>;
};
```

この構造により、効果を含めた構文木全体をハッシュ化し、Unison 的な再利用が可能。

---

## 4. コンテンツアドレッシング

- 全ての関数・型・IR 構文木は deterministic serialization により SHA-256 等で識別される
- 識別子は `hash(FuncDef)` として導出
- 依存する関数も同様に content-addressed され、DAG として構造化される

---

## 5. 実行モデルとトランポリン（resume 処理）

### 5.1 Step 型（trampoline）

```ts
type Step =
  | { tag: "Pure"; value: Value }
  | { tag: "Effect"; name: string; args: Value[]; resume: (v: Value) => Step };
```

### 5.2 評価ループ

```ts
function run(step: Step, handlers: EffectHandler[]): Value {
  while (true) {
    if (step.tag === "Pure") return step.value;
    if (step.tag === "Effect") {
      const handler = findHandler(step.name, handlers);
      if (!checkPermission(handler.permissions, step.name, step.args)) {
        throw new Error("Permission denied");
      }
      step = handler.handlerImpl[step.name](...step.args, step.resume);
    }
  }
}
```

- `Effect` ノードは resume continuation を伴い、handler により意味付けされる
- 実行時には handler にバインドされた permission set を使ってアクセス制御を行う
- trampoline によって Wasm 上でも safe に resume ベースの制御が可能

---

## 6. Wasm 実装に向けた考慮

| 機能                 | Wasm 上の表現                                                                      |
| -------------------- | ---------------------------------------------------------------------------------- |
| 継続 (`resume`)      | call_indirect or explicit CPS encoding                                             |
| handler の切替       | 関数テーブル + dispatch 構造                                                       |
| 効果の記述           | IR ノード + 型注釈に保持（実行時には不要）                                         |
| 実行時パーミッション | handler 内部のチェック関数で安全制御                                               |
| WasmFX 対応          | `cont.new`, `resume`, `control tag` により Effect Handler を型安全にネイティブ表現 |

---

## 今後の検討課題

- Row-polymorphic effect inference アルゴリズム
- handler のモジュール的構成（handler injection）
- resume の多段ネストや複数 resume 呼び出しに対する静的制約
- Wasm での continuation stack 管理の低レベル最適化
- パーミッション型と構文の明示的導入（`Capability<Effect>`）設計
- WasmFX をベースにした IR → WebAssembly の直接変換パスと runtime 支援の設計
