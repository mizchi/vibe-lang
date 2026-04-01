# Rivet Agent OS 比較メモ

## 目的

`https://rivet.dev/docs/agent-os/` を起点に Agent OS の考え方を確認し、
`vibe-lang` から見て:

- そのまま連携しやすい部分
- `vibe` 側に移植すると価値が高い部分
- 逆に `vibe` で再実装しない方がよい部分

を整理する。

調査日: 2026-04-01

## 要約

短期では、`agentOS` を実行基盤として使い、`vibe` は JS/WASM tool として埋め込むのが最も現実的。

中期では、`agentOS` の次の発想を `vibe` の session/runtime 層へ取り込む価値が高い。

- session ごとに状態を持つ
- transcript を中心に実行履歴を残す
- permission を human-in-the-loop で承認する
- tool / agent / workflow を型付き contract として扱う

一方で、container sandbox や preview environment のような「実行基盤そのもの」は `vibe` が再実装するより、
外部ホストに委ねた方が筋が良い。

## Agent OS の主な特徴

今回確認した範囲で、Agent OS はだいたい次の方向を持つ。

- agent 実行を session 単位で管理する
- session ごとに transcript を残す
- agent が tool を呼ぶとき permission を挟める
- JavaScript 関数を host tool として公開できる
- agent-to-agent で delegation できる
- workflow / queue / background execution を持てる
- sandbox / networking / security model が runtime の責務として整理されている
- session ごとに永続 state を持つ設計が強い

この設計は「LLM を呼ぶ関数群」よりも、「agent を安全に長時間動かす OS / runtime」に近い。

## vibe 側ですでに近いもの

`vibe` は未完成な点もあるが、Agent OS と噛み合う土台をすでにかなり持っている。

### 1. capability model

`vibe` には runtime capability として次がある。

- `FsRead`, `FsWrite`, `FsDelete`, `FsExecute`
- `NetConnect`, `NetListen`
- `McpCall`, `McpServe`
- `A2ADelegate`, `A2AReceive`
- `GitSnapshot`, `GitRollback`, `GitBranch`
- `ClockRead`, `ClockMonotonic`, `RandomRead`
- `EnvRead`, `EnvWrite`, `ProcessSpawn`
- `LlmCall`

参照:

- [src/capability/types.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/capability/types.mbt)
- [src/capability/set.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/capability/set.mbt)
- [src/capability/presets.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/capability/presets.mbt)

これは Agent OS の permission model とかなり相性が良い。

### 2. runtime enforcement

`CapabilitySet` は単なる型ではなく、少なくとも interpreter runtime では実際に enforcement されている。

- `sh` / `sh_lines` は `ProcessSpawn`
- `Fs::*` は `FsRead` / `FsWrite`
- `Http::*` は `NetConnect` / `NetListen`
- `sleep` は `ClockRead`

参照:

- [src/runtime/eval.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/runtime/eval.mbt)
- [docs/http_server_contract.md](/Users/mz/ghq/github.com/mizchi/vibe-lang/docs/http_server_contract.md)

つまり `agentOS` 側の許可結果を `vibe` の capability に写像すれば、
最低限の deny/allow はすでに実行時に表現できる。

### 3. Deno-style allow flags

`vibe` CLI には `--allow-fs`, `--allow-net`, `--allow-env`, `--allow-run`, `--allow-all`
を capability に落とし込む実装がある。

参照:

- [src/cmd/vibe/syntax_mode.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/cmd/vibe/syntax_mode.mbt)
- [docs/vibe.md](/Users/mz/ghq/github.com/mizchi/vibe-lang/docs/vibe.md)

これは Agent OS の permission を CLI/runtime に接続する入口として使いやすい。

### 4. session worker

`vibe` には `session-http` / `session-json` があり、
`run/check/test` を高速化するため persistent worker を既に持っている。

参照:

- [docs/cli-commands.md](/Users/mz/ghq/github.com/mizchi/vibe-lang/docs/cli-commands.md)
- [src/cmd/vibe/cli_session.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/cmd/vibe/cli_session.mbt)
- [docs/archive/adr/0034-compiled-only-execution-surface.md](/Users/mz/ghq/github.com/mizchi/vibe-lang/docs/archive/adr/0034-compiled-only-execution-surface.md)

Agent OS の session 概念と最も直接つながるのはここ。

### 5. JS/WASM service surface

`js/vibe` は次の API を既に公開している。

- `init`
- `check`
- `format`
- `checkProject`
- `ideOutline`
- `idePeekDef`
- `ideSearch`
- `eval`

参照:

- [js/vibe/index.d.ts](/Users/mz/ghq/github.com/mizchi/vibe-lang/js/vibe/index.d.ts)

Agent OS の host tool が JS 関数を公開できる前提なら、
これはそのまま tool 化しやすい。

### 6. A2A / orchestration の萌芽

`vibe` には capability 側に `McpCall` / `A2ADelegate` があり、
さらに `threads` には task / actor / channel の spec がある。

参照:

- [src/capability/types.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/capability/types.mbt)
- [vibe/prelude/threads/spec.vibe](/Users/mz/ghq/github.com/mizchi/vibe-lang/vibe/prelude/threads/spec.vibe)
- [vibe/prelude/threads/runtime.vibe](/Users/mz/ghq/github.com/mizchi/vibe-lang/vibe/prelude/threads/runtime.vibe)

ただし現状は「表現力と spec」はあるが、
Agent OS のような agent runtime / queue / resume までは実装されていない。

## そのまま連携しやすい部分

### 1. `js/vibe` を Agent OS tool として使う

もっとも簡単で効果が高い。

例:

- `vibe_check(source)`
- `vibe_check_project(entry, files)`
- `vibe_format(source)`
- `vibe_ide_outline(entry, files, path?)`
- `vibe_ide_peek_def(entry, files, symbol)`

この構成なら:

- Agent OS 側は orchestration, session, permission, transcript に集中できる
- `vibe` 側は compiler/runtime と IDE API に集中できる
- `vibe.wasm` をそのまま再利用できる

### 2. permission を `CapabilitySet` に写像する

Agent OS の permission grant を `CapabilitySet` に変換すれば、
`vibe` runtime で既にある deny/allow と繋がる。

対応イメージ:

- file read/write 許可 -> `FsRead` / `FsWrite`
- outgoing network 許可 -> `NetConnect`
- listen 許可 -> `NetListen`
- subprocess 許可 -> `ProcessSpawn`
- env 許可 -> `EnvRead`
- model/tool/agent 許可 -> `LlmCall` / `McpCall` / `A2ADelegate`

### 3. session ごとに `vibe session-http/json` を持つ

Agent OS session と `vibe` session worker を 1:1 に近く対応させると、
同一会話中の warm compile / incremental cache を最大限に使える。

これは `agentOS` に対して `vibe` が独自価値を出しやすい部分でもある。

## 移植すると価値が高い機能

### 1. transcript-first session

最優先。

`vibe` の session worker は高速だが、
「何を実行し、どの permission を要求し、どの tool を呼び、何が返ったか」
を一級の transcript として扱う API はまだ薄い。

欲しいもの:

- run/check/test/tool-call のイベント列
- permission request / grant / deny の記録
- file diff / snapshot の記録
- replay 可能な session transcript

これが入ると:

- AI agent の挙動を後から追いやすい
- 失敗ケースを fixture 化しやすい
- session worker が単なる cache ではなく execution log になる

### 2. human-in-the-loop permission

現状の `vibe` は `--allow-*` の静的付与が中心。
Agent OS っぽくするなら、実行中に:

1. permission request を発行
2. host が approve / deny
3. session が resume

の流れを持ちたい。

これは `CapabilitySet` を捨てるのではなく、
`CapabilitySet` を「現在 grant 済みの authority」として使い、
不足時に request を上げる形が自然。

### 3. per-session durable state

Agent OS が session ごとに永続状態を持つ発想は `vibe` にも有効。

候補:

- incremental compile cache
- module graph
- transcript index
- agent memory
- generated artifact metadata
- permission history

`vibe` はすでに `db` / graph / cache の内部資産を持っているので、
session 永続層を足すとかなり整理されるはず。

### 4. typed tool contract

`vibe` の設計方針は contract 層を厳密にしたいので、
Agent OS の tool を参考に:

- tool input/output schema
- capability requirement
- deterministic / nondeterministic 属性
- replay 可否

を 1 つの contract として宣言できると良い。

理想的には:

- `vibe` で tool contract を書く
- JS/MCP/CLI adapter を生成する
- capability と transcript 記録が自動で付く

### 5. A2A runtime bridge

`A2ADelegate` capability はあるが、
実際の agent delegation protocol はまだ薄い。

Agent OS を参考にすると:

- delegate request
- task identity
- status update
- partial result
- cancel / timeout
- final result

が必要になる。

これは `threads` の task/channel と概念相性が良いので、
`vibe` の orchestration surface として育てる価値がある。

## 移植優先度が低いもの

### 1. container sandbox の再実装

Docker / gVisor / network isolation / preview URL まで `vibe` が持つのは守備範囲が広すぎる。

ここは:

- Agent OS
- Deno
- wasmtime host
- CI / container platform

の責務に寄せた方がよい。

`vibe` が持つべきなのは「どの capability を要求するか」「許可されていないとき何を返すか」まで。

### 2. cloud workflow runtime 全部

queue, job scheduler, distributed retries, hosted preview のような部分は、
言語処理系の中核より service/runtime の責務。

`vibe` に必要なのは:

- protocol
- contract
- capability
- transcript

であって、ホスティング基盤全部ではない。

## 推奨アーキテクチャ

短期の推奨構成は次の通り。

```
Agent OS
  ├─ session / transcript / permission / A2A
  ├─ host tools
  │    └─ js/vibe (check / format / ide / eval / build)
  └─ sandbox / networking / workflow

vibe
  ├─ language / checker / compiler
  ├─ runtime capability enforcement
  ├─ session worker
  └─ JS/WASM API
```

つまり:

- Agent OS は「agent runtime」
- `vibe` は「language runtime + compiler service」

として分担する。

## 実装順の提案

### Phase 1

- `js/vibe` を Agent OS tool として公開する
- `check` / `format` / `ide*` を先に接続する
- permission は最初は coarse-grained でよい

### Phase 2

- Agent OS session と `vibe session-http/json` を接続する
- warm compile / project cache を会話単位で再利用する
- transcript に `vibe` 実行イベントを残す

### Phase 3

- permission request / approve / resume を `vibe` runtime に入れる
- `CapabilitySet` を動的 grant 可能にする
- deny 時に「失敗」だけでなく「要求」にも分岐できるようにする

### Phase 4

- `McpCall` / `A2ADelegate` の実 runtime bridge を作る
- tool contract / transcript / status update を統一する

## 結論

Agent OS は `vibe` の競合というより、`vibe` を安全な agent 実行面に載せるための外部 runtime として見るのが自然。

特に相性が良いのは次の 4 点。

- `js/vibe` の tool 化
- permission -> `CapabilitySet` 写像
- session -> `session-http/json` 接続
- transcript / approval / A2A の概念移植

逆に、sandbox/container/workflow hosting まで `vibe` が抱える必要は薄い。

`vibe` が強くなる方向は:

- capability と effect の contract を厳密にする
- session と transcript を first-class にする
- tool / agent / workflow を型付き surface にする

であり、そこに Agent OS の設計を取り込むのは十分に価値がある。

## 外部参照

- `https://rivet.dev/docs/agent-os/`
- `https://rivet.dev/docs/agent-os/agent-to-agent/`
- `https://rivet.dev/docs/agent-os/security`
- `https://rivet.dev/docs/agent-os/sandbox`
- `https://rivet.dev/docs/agent-os/networking`
- `https://rivet.dev/docs/agent-os/software`
- `https://rivet.dev/docs/agent-os/workflows/`
- `https://rivet.dev/docs/agent-os/limitations`
