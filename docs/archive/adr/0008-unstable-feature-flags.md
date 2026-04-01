# ADR-0008: 不安定機能フラグによるゲーティング

- Date: 2026-02-16
- Status: accepted

## Context

async/await やスレッドなど、仕様が固まっていない実験的機能を早期にユーザーに提供したいが、安定 API として約束はできない状況があった。

## Decision

`--unstable-*` CLI フラグで実験的機能をゲートする:

```bash
vibe run --unstable-async script.vibe
vibe run --unstable-threads script.vibe
```

- フラグは `vibe` コマンドの前後どちらにも配置可能
- フラグなしで不安定機能を使用するとコンパイルエラー
- 安定化後はフラグを外して通常機能に昇格させる

現在のフラグ:
- `--unstable-async` — `sleep()`, `await`, `yield` の実行
- `--unstable-threads` — スレッド API, WASI Threads

## Consequences

- ユーザーが明示的にオプトインするため、破壊的変更の影響範囲が限定される
- フラグの存在がドキュメントの複雑さを増す
- 安定化の判断基準を別途定める必要がある
