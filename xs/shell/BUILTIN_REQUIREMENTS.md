# Shell Commands Builtin Requirements

POSIXシェルコマンドを実装するために必要なビルトイン関数のリストです。

## ファイルシステム操作

### 基本的なファイル操作
```haskell
-- ファイルの読み込み
readFile :: String -> IO (Result String String)

-- ファイルの書き込み
writeFile :: String -> String -> IO (Result () String)

-- ファイルの存在確認
fileExists :: String -> IO Bool

-- ファイル情報の取得（サイズ、権限、更新日時など）
fileInfo :: String -> IO (Result FileInfo String)
```

### ディレクトリ操作
```haskell
-- 現在のディレクトリを取得
getCwd :: () -> IO String

-- ディレクトリを変更
setCwd :: String -> IO (Result () String)

-- ホームディレクトリを取得
getHomeDir :: () -> IO String

-- ディレクトリの内容を一覧表示
listDir :: String -> IO (Result (List String) String)

-- ディレクトリの作成
mkDir :: String -> IO (Result () String)

-- ディレクトリの削除
rmDir :: String -> IO (Result () String)
```

### パス操作
```haskell
-- パスの結合
pathJoin :: String -> String -> String

-- パスの正規化
pathNormalize :: String -> String

-- 絶対パスかどうかの判定
isAbsolutePath :: String -> Bool

-- パスが存在するかの確認
pathExists :: String -> IO Bool
```

## 標準入出力

```haskell
-- 標準入力から1行読み込み
readLine :: () -> IO String

-- 標準入力から全て読み込み
readStdin :: () -> IO String

-- 標準出力に出力（改行なし）
printNoNewline :: String -> IO ()

-- 標準エラー出力に出力
printErr :: String -> IO ()
```

## プロセス管理

```haskell
-- 環境変数の取得
getEnv :: String -> IO (Maybe String)

-- 環境変数の設定
setEnv :: String -> String -> IO ()

-- コマンドライン引数の取得
getArgs :: () -> IO (List String)
```

## 実装優先度

1. **高優先度**（基本的なシェル機能に必須）
   - getCwd, setCwd
   - readFile, writeFile
   - listDir
   - getHomeDir
   - printNoNewline

2. **中優先度**（より高度な機能のため）
   - fileExists, pathExists
   - fileInfo
   - pathJoin, pathNormalize
   - readLine, readStdin
   - getEnv, setEnv

3. **低優先度**（拡張機能）
   - mkDir, rmDir
   - isAbsolutePath
   - printErr
   - getArgs

## Effect System との統合

これらのビルトイン関数は全てIO効果を持つため、XSのEffect Systemと適切に統合する必要があります。

```haskell
-- 例: readFileの型
readFile :: String -> IO (Result String String)
-- または
readFile :: String -> {IO, Exception} String
```