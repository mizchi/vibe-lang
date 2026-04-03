# agentOS local PoC

最小の `agentOS` ローカル確認用スクリプト。

やること:

- `AgentOs.create()` で VM を起動
- このリポジトリを `/workspace` に read-only mount
- mount された `README.md` と `js/` を読んで smoke check
- API key がある環境では `pi` session を起動して prompt を 1 回送る

## 依存

このディレクトリで `pnpm install` 済みであること。

## 使い方

### 1. smoke check

```bash
cd tools/agent-os-poc
pnpm start
```

### 2. prompt 実行

```bash
cd tools/agent-os-poc
OPENAI_API_KEY=... pnpm start -- --prompt "Summarize /workspace/README.md in one sentence"
```

対応している環境変数:

- `OPENAI_API_KEY`
- `OPENROUTER_API_KEY`
- `ANTHROPIC_API_KEY`
- `GEMINI_API_KEY`

### 3. event を見たいとき

```bash
pnpm start -- --prompt "List the files in /workspace/js" --verbose-events
```

## メモ

- `pi` adapter を使っているので、session 作成時にはモデル認証が必要
- mount は read-only なので PoC 実行では repo を書き換えない
- `moduleAccessCwd` はこのディレクトリ固定なので、`pi-acp` と `pi` の依存解決はここだけで閉じる
