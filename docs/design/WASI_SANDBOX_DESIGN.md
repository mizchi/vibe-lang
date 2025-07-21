# WASI Sandbox Permission System Design

## 概要

XS言語のWASIサンドボックスパーミッションシステムは、WebAssemblyモジュールが実行時にアクセスできるシステムリソースを細かく制御するための仕組みです。これにより、安全で予測可能な実行環境を提供します。

## 設計目標

1. **最小権限の原則**: 必要最小限の権限のみを付与
2. **宣言的な権限管理**: コード内で明示的に権限を宣言
3. **静的検証**: コンパイル時に権限の使用を検証
4. **細粒度の制御**: ファイル、ネットワーク、環境変数へのアクセスを個別に制御
5. **AIフレンドリー**: 権限要求が明確で理解しやすい

## パーミッションモデル

### 基本的な権限タイプ

```rust
#[derive(Debug, Clone, PartialEq)]
pub enum Permission {
    // ファイルシステム権限
    FileRead(PathPattern),
    FileWrite(PathPattern),
    FileCreate(PathPattern),
    FileDelete(PathPattern),
    
    // ネットワーク権限
    NetworkConnect(HostPattern, PortRange),
    NetworkListen(PortRange),
    
    // 環境変数権限
    EnvRead(String),
    EnvWrite(String),
    
    // プロセス権限
    ProcessSpawn(String),
    ProcessSignal,
    
    // 時刻権限
    ClockRead,
    ClockSet,
    
    // 乱数権限
    Random,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PathPattern {
    pattern: String,
    recursive: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct HostPattern {
    pattern: String, // e.g., "*.example.com", "192.168.1.*"
}

#[derive(Debug, Clone, PartialEq)]
pub struct PortRange {
    start: u16,
    end: u16,
}
```

## XS言語での権限宣言

### モジュールレベルの権限宣言

```lisp
; permissions.xs
(module FileProcessor
  (permissions
    (file-read "/input/*.txt")
    (file-write "/output/")
    (env-read "LOG_LEVEL"))
  
  (export process-files)
  
  (import WASI)
  
  (define process-files (fn (input-dir output-dir)
    ; ファイル処理ロジック
    ...)))
```

### 関数レベルの権限要求

```lisp
(define read-config 
  (with-permissions ((file-read "/etc/app.conf"))
    (fn ()
      (WASI.read-file "/etc/app.conf"))))
```

### 動的権限リクエスト（オプション）

```lisp
(define connect-to-server (fn (host port)
  (request-permission (network-connect host port))
  (WASI.tcp-connect host port)))
```

## 実装設計

### 1. パーミッションチェッカー

```rust
// xs-wasm/src/permissions.rs
pub struct PermissionChecker {
    granted: HashSet<Permission>,
    denied: HashSet<Permission>,
}

impl PermissionChecker {
    pub fn new(manifest: &PermissionManifest) -> Self {
        // マニフェストから権限を読み込み
    }
    
    pub fn check(&self, perm: &Permission) -> Result<(), PermissionError> {
        if self.denied.contains(perm) {
            return Err(PermissionError::Denied(perm.clone()));
        }
        
        if !self.granted.contains(perm) && !self.matches_pattern(perm) {
            return Err(PermissionError::NotGranted(perm.clone()));
        }
        
        Ok(())
    }
    
    fn matches_pattern(&self, perm: &Permission) -> bool {
        // パターンマッチングロジック
    }
}
```

### 2. WASI実行環境の統合

```rust
// runtime/src/wasi_sandbox.rs
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder};

pub struct SandboxedWasiRuntime {
    engine: Engine,
    permissions: PermissionChecker,
}

impl SandboxedWasiRuntime {
    pub fn new(permissions: PermissionManifest) -> Self {
        let mut config = Config::new();
        config.wasm_component_model(true);
        
        let engine = Engine::new(&config).unwrap();
        let permissions = PermissionChecker::new(&permissions);
        
        Self { engine, permissions }
    }
    
    pub fn create_wasi_context(&self) -> WasiCtx {
        let mut builder = WasiCtxBuilder::new();
        
        // 権限に基づいてWASIコンテキストを構成
        self.configure_filesystem(&mut builder);
        self.configure_network(&mut builder);
        self.configure_environment(&mut builder);
        
        builder.build()
    }
    
    fn configure_filesystem(&self, builder: &mut WasiCtxBuilder) {
        // ファイルシステム権限の設定
        for perm in &self.permissions.granted {
            match perm {
                Permission::FileRead(pattern) => {
                    builder.preopened_dir(
                        pattern.to_dir(),
                        pattern.to_guest_path(),
                        DirPerms::READ,
                        FilePerms::READ,
                    );
                }
                Permission::FileWrite(pattern) => {
                    builder.preopened_dir(
                        pattern.to_dir(),
                        pattern.to_guest_path(),
                        DirPerms::READ | DirPerms::WRITE,
                        FilePerms::READ | FilePerms::WRITE,
                    );
                }
                _ => {}
            }
        }
    }
}
```

### 3. 静的権限解析

```rust
// checker/src/permission_analysis.rs
pub struct PermissionAnalyzer {
    used_permissions: HashSet<Permission>,
    declared_permissions: HashSet<Permission>,
}

impl PermissionAnalyzer {
    pub fn analyze(&mut self, expr: &Expr) -> Result<(), PermissionError> {
        match expr {
            Expr::Apply { func, args, .. } => {
                if let Expr::QualifiedIdent { module_name, name, .. } = func {
                    if module_name.0 == "WASI" {
                        self.check_wasi_call(&name.0, args)?;
                    }
                }
            }
            // 他のケースも処理
            _ => {}
        }
        Ok(())
    }
    
    fn check_wasi_call(&mut self, func_name: &str, args: &[Expr]) -> Result<(), PermissionError> {
        let required_perm = match func_name {
            "read-file" => {
                let path = self.extract_string_literal(&args[0])?;
                Permission::FileRead(PathPattern::new(path))
            }
            "tcp-connect" => {
                let host = self.extract_string_literal(&args[0])?;
                let port = self.extract_int_literal(&args[1])?;
                Permission::NetworkConnect(
                    HostPattern::new(host),
                    PortRange::single(port),
                )
            }
            // 他のWASI関数も同様に処理
            _ => return Ok(()),
        };
        
        self.used_permissions.insert(required_perm);
        Ok(())
    }
}
```

## パーミッションマニフェスト

### TOML形式

```toml
# permissions.toml
[permissions]
name = "my-app"
version = "1.0.0"

[[permissions.filesystem]]
read = ["/input/**/*.txt", "/config/app.conf"]
write = ["/output/"]
create = ["/tmp/"]

[[permissions.network]]
connect = ["api.example.com:443", "*.internal.net:8080-8090"]

[[permissions.environment]]
read = ["LOG_LEVEL", "APP_CONFIG"]

[[permissions.capabilities]]
random = true
clock_read = true
```

### JSON形式（AIツール向け）

```json
{
  "permissions": {
    "name": "my-app",
    "version": "1.0.0",
    "filesystem": {
      "read": ["/input/**/*.txt", "/config/app.conf"],
      "write": ["/output/"],
      "create": ["/tmp/"]
    },
    "network": {
      "connect": ["api.example.com:443", "*.internal.net:8080-8090"]
    },
    "environment": {
      "read": ["LOG_LEVEL", "APP_CONFIG"]
    },
    "capabilities": {
      "random": true,
      "clock_read": true
    }
  }
}
```

## エラー処理

### 権限エラーの種類

```rust
#[derive(Debug, Error)]
pub enum PermissionError {
    #[error("Permission denied: {0:?}")]
    Denied(Permission),
    
    #[error("Permission not granted: {0:?}")]
    NotGranted(Permission),
    
    #[error("Invalid permission pattern: {0}")]
    InvalidPattern(String),
    
    #[error("Permission conflict: {0} conflicts with {1}")]
    Conflict(Permission, Permission),
}
```

### AIフレンドリーなエラーメッセージ

```
ERROR[PERMISSION]: File read permission not granted
Location: line 15, column 8
Code: (WASI.read-file "/etc/passwd")
                      ^^^^^^^^^^^^
Required permission: (file-read "/etc/passwd")

Suggestions:
  1. Add permission to module declaration:
     (permissions
       (file-read "/etc/passwd"))
  
  2. Or use a more general pattern:
     (permissions
       (file-read "/etc/*"))

Security note: Reading system files may expose sensitive information.
Consider if this access is truly necessary.
```

## 統合テスト

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_file_permission_check() {
        let mut checker = PermissionChecker::new();
        checker.grant(Permission::FileRead(PathPattern::new("/app/data/*")));
        
        // 許可されたアクセス
        assert!(checker.check(&Permission::FileRead(
            PathPattern::new("/app/data/file.txt")
        )).is_ok());
        
        // 拒否されたアクセス
        assert!(checker.check(&Permission::FileRead(
            PathPattern::new("/etc/passwd")
        )).is_err());
    }
    
    #[test]
    fn test_network_permission_pattern() {
        let mut checker = PermissionChecker::new();
        checker.grant(Permission::NetworkConnect(
            HostPattern::new("*.example.com"),
            PortRange::new(443, 443),
        ));
        
        // マッチするホスト
        assert!(checker.matches_host_pattern(
            "api.example.com",
            &HostPattern::new("*.example.com")
        ));
    }
}
```

## 実装ロードマップ

### Phase 1: 基本実装（2週間）
- [ ] Permission型の定義
- [ ] PermissionCheckerの基本実装
- [ ] ファイルシステム権限の実装

### Phase 2: WASI統合（3週間）
- [ ] WasmtimeのWASIコンテキストとの統合
- [ ] ネットワーク権限の実装
- [ ] 環境変数権限の実装

### Phase 3: 静的解析（2週間）
- [ ] パーミッション使用の静的解析
- [ ] コンパイル時の権限検証
- [ ] エラーメッセージの改善

### Phase 4: 高度な機能（3週間）
- [ ] 動的権限リクエスト
- [ ] 権限の継承と委譲
- [ ] セキュリティポリシーの実装

## セキュリティ考慮事項

1. **権限エスカレーション防止**: 子プロセスは親以上の権限を持てない
2. **パス正規化**: `../`などを使った権限回避を防ぐ
3. **ホスト名検証**: DNSリバインディング攻撃への対策
4. **監査ログ**: すべての権限チェックをログに記録

## まとめ

このWASIサンドボックスパーミッションシステムにより、XS言語は：

1. 安全なWebAssembly実行環境を提供
2. 細粒度のリソースアクセス制御を実現
3. 静的解析によるセキュリティ保証
4. AIツールとの統合に適した宣言的な権限管理

を実現します。