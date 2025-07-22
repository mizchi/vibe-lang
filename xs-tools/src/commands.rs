use anyhow::Result;
use colored::*;
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    // 基本コマンド
    Help,
    Exit,
    Clear,

    // UCM風のコマンド
    Add(Option<String>), // add [definition] - 定義を追加
    View(String),        // view <name|hash> - 定義を表示
    Edit(String),        // edit <name|hash> - 定義を編集
    Update,              // update - 変更をコミット
    Undo,                // undo - 最後の変更を取り消し

    // 検索・参照
    Find(String),         // find <pattern> - パターンで検索
    Search(String),       // search <query> - 構造化検索
    Ls(Option<String>),   // ls [pattern] - 定義一覧
    Dependencies(String), // dependencies <name> - 依存関係を表示
    Dependents(String),   // dependents <name> - 被依存関係を表示
    
    // パイプライン処理
    Pipeline(Vec<String>), // pipeline commands - パイプライン処理

    // 型情報
    TypeOf(String), // type-of <expr|name> - 型を表示

    // ブランチ管理
    Branch(Option<String>), // branch [name] - ブランチ作成/切り替え
    Branches,               // branches - ブランチ一覧
    Merge(String),          // merge <branch> - ブランチをマージ

    // 履歴
    History(Option<usize>), // history [n] - 評価履歴
    Log(Option<usize>),     // log [n] - コミット履歴

    // デバッグ
    Debug(String), // debug <expr> - デバッグ情報付きで評価
    Trace(String), // trace <expr> - トレース付きで評価

    // LSP相当機能
    References(String), // references <name> - 参照を検索
    Definition(String), // definition <name> - 定義元を表示
    Hover(String),      // hover <name|expr> - ホバー情報を表示

    // 式の評価
    Eval(String), // 通常の式評価
}

impl Command {
    pub fn parse(input: &str) -> Result<Self> {
        let input = input.trim();
        if input.is_empty() {
            return Ok(Command::Eval(String::new()));
        }

        // Check for pipeline syntax
        if input.contains('|') {
            let commands: Vec<String> = input.split('|')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            if commands.len() > 1 {
                return Ok(Command::Pipeline(commands));
            }
        }

        // コマンドのパース
        let parts: Vec<&str> = input.split_whitespace().collect();
        let cmd = parts[0];
        let args = &parts[1..];

        match cmd {
            "help" | "?" => Ok(Command::Help),
            "exit" | "quit" | ":q" => Ok(Command::Exit),
            "clear" | "cls" => Ok(Command::Clear),

            "add" => {
                if args.is_empty() {
                    Ok(Command::Add(None))
                } else {
                    // "add name = expr" 形式の場合、全体をlet式に変換
                    let full_args = args.join(" ");
                    if full_args.contains('=') {
                        // "name = expr" を "(let name expr)" に変換
                        let parts: Vec<&str> = full_args.splitn(2, '=').collect();
                        if parts.len() == 2 {
                            let name = parts[0].trim();
                            let expr = parts[1].trim();
                            Ok(Command::Add(Some(format!("(let {} {})", name, expr))))
                        } else {
                            Ok(Command::Add(Some(full_args)))
                        }
                    } else {
                        Ok(Command::Add(Some(full_args)))
                    }
                }
            }

            "view" => {
                if args.is_empty() {
                    anyhow::bail!("view requires an argument")
                }
                Ok(Command::View(args[0].to_string()))
            }

            "edit" => {
                if args.is_empty() {
                    anyhow::bail!("edit requires an argument")
                }
                Ok(Command::Edit(args[0].to_string()))
            }

            "update" => Ok(Command::Update),
            "undo" => Ok(Command::Undo),

            "find" => {
                if args.is_empty() {
                    anyhow::bail!("find requires a pattern")
                }
                Ok(Command::Find(args.join(" ")))
            }

            "search" => {
                if args.is_empty() {
                    anyhow::bail!("search requires a query")
                }
                Ok(Command::Search(args.join(" ")))
            }

            "ls" | "list" => {
                if args.is_empty() {
                    Ok(Command::Ls(None))
                } else {
                    Ok(Command::Ls(Some(args.join(" "))))
                }
            }

            "dependencies" | "deps" => {
                if args.is_empty() {
                    anyhow::bail!("dependencies requires an argument")
                }
                Ok(Command::Dependencies(args[0].to_string()))
            }

            "dependents" => {
                if args.is_empty() {
                    anyhow::bail!("dependents requires an argument")
                }
                Ok(Command::Dependents(args[0].to_string()))
            }

            "type-of" | "typeof" => {
                if args.is_empty() {
                    anyhow::bail!("type-of requires an expression")
                }
                Ok(Command::TypeOf(args.join(" ")))
            }

            "branch" => {
                if args.is_empty() {
                    Ok(Command::Branch(None))
                } else {
                    Ok(Command::Branch(Some(args[0].to_string())))
                }
            }

            "branches" => Ok(Command::Branches),

            "merge" => {
                if args.is_empty() {
                    anyhow::bail!("merge requires a branch name")
                }
                Ok(Command::Merge(args[0].to_string()))
            }

            "history" => {
                let limit = args.get(0).and_then(|s| s.parse::<usize>().ok());
                Ok(Command::History(limit))
            }

            "log" => {
                let limit = args.get(0).and_then(|s| s.parse::<usize>().ok());
                Ok(Command::Log(limit))
            }

            "debug" => {
                if args.is_empty() {
                    anyhow::bail!("debug requires an expression")
                }
                Ok(Command::Debug(args.join(" ")))
            }

            "trace" => {
                if args.is_empty() {
                    anyhow::bail!("trace requires an expression")
                }
                Ok(Command::Trace(args.join(" ")))
            }

            "references" | "refs" => {
                if args.is_empty() {
                    anyhow::bail!("references requires a name")
                }
                Ok(Command::References(args[0].to_string()))
            }

            "definition" | "def" => {
                if args.is_empty() {
                    anyhow::bail!("definition requires a name")
                }
                Ok(Command::Definition(args[0].to_string()))
            }

            "hover" => {
                if args.is_empty() {
                    anyhow::bail!("hover requires a name or expression")
                }
                Ok(Command::Hover(args.join(" ")))
            }

            _ => {
                // コマンドでない場合は式として評価
                Ok(Command::Eval(input.to_string()))
            }
        }
    }
}

impl fmt::Display for Command {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Command::Help => write!(f, "help"),
            Command::Exit => write!(f, "exit"),
            Command::Clear => write!(f, "clear"),
            Command::Add(None) => write!(f, "add"),
            Command::Add(Some(def)) => write!(f, "add {}", def),
            Command::View(name) => write!(f, "view {}", name),
            Command::Edit(name) => write!(f, "edit {}", name),
            Command::Update => write!(f, "update"),
            Command::Undo => write!(f, "undo"),
            Command::Find(pattern) => write!(f, "find {}", pattern),
            Command::Search(query) => write!(f, "search {}", query),
            Command::Ls(None) => write!(f, "ls"),
            Command::Ls(Some(pattern)) => write!(f, "ls {}", pattern),
            Command::Dependencies(name) => write!(f, "dependencies {}", name),
            Command::Dependents(name) => write!(f, "dependents {}", name),
            Command::Pipeline(cmds) => write!(f, "{}", cmds.join(" | ")),
            Command::TypeOf(expr) => write!(f, "type-of {}", expr),
            Command::Branch(None) => write!(f, "branch"),
            Command::Branch(Some(name)) => write!(f, "branch {}", name),
            Command::Branches => write!(f, "branches"),
            Command::Merge(name) => write!(f, "merge {}", name),
            Command::History(None) => write!(f, "history"),
            Command::History(Some(n)) => write!(f, "history {}", n),
            Command::Log(None) => write!(f, "log"),
            Command::Log(Some(n)) => write!(f, "log {}", n),
            Command::Debug(expr) => write!(f, "debug {}", expr),
            Command::Trace(expr) => write!(f, "trace {}", expr),
            Command::References(name) => write!(f, "references {}", name),
            Command::Definition(name) => write!(f, "definition {}", name),
            Command::Hover(expr) => write!(f, "hover {}", expr),
            Command::Eval(expr) => write!(f, "{}", expr),
        }
    }
}

pub fn print_ucm_help() {
    println!("{}", "XS Shell - UCM-style Commands".bold().cyan());
    println!();

    println!("{}", "Basic Commands:".bold());
    println!("  help, ?              Show this help message");
    println!("  exit, quit, :q       Exit the shell");
    println!("  clear, cls           Clear the screen");
    println!();
    
    println!("{}", "Syntax Modes:".bold());
    println!("  :auto                Auto-detect syntax (default)");
    println!("  :sexpr               S-expression only mode");
    println!("  :shell               Shell syntax only mode");
    println!("  :mixed               Mixed syntax mode");
    println!("  :mode                Show current syntax mode");
    println!();

    println!("{}", "Definition Management:".bold());
    println!("  add [definition]     Add a definition to the codebase");
    println!("  view <name|hash>     View a definition");
    println!("  edit <name|hash>     Edit a definition");
    println!("  update               Commit changes to codebase");
    println!("  undo                 Undo the last change");
    println!();

    println!("{}", "Search and Navigation:".bold());
    println!("  find <pattern>       Search for definitions by name");
    println!("  search <query>       Advanced search (type, AST, dependencies)");
    println!("  ls [pattern]         List definitions");
    println!("  dependencies <name>  Show what <name> depends on");
    println!("  dependents <name>    Show what depends on <name>");
    println!();
    
    println!("{}", "Pipeline Processing:".bold());
    println!("  cmd | filter field value   Filter by field value");
    println!("  cmd | select fields...     Select specific fields");
    println!("  cmd | sort field [desc]    Sort by field");
    println!("  cmd | take n               Take first n items");
    println!("  cmd | group by field       Group by field");
    println!("  cmd | count                Count items");
    println!();

    println!("{}", "Type Information:".bold());
    println!("  type-of <expr>       Show the type of an expression");
    println!();

    println!("{}", "Branch Management:".bold());
    println!("  branch [name]        Create or switch to a branch");
    println!("  branches             List all branches");
    println!("  merge <branch>       Merge a branch");
    println!();

    println!("{}", "History:".bold());
    println!("  history [n]          Show evaluation history");
    println!("  log [n]              Show commit history");
    println!();

    println!("{}", "Debug:".bold());
    println!("  debug <expr>         Evaluate with debug info");
    println!("  trace <expr>         Evaluate with execution trace");
    println!();

    println!("{}", "LSP-like Features:".bold());
    println!("  references <name>    Find references to a definition");
    println!("  definition <name>    Go to definition");
    println!("  hover <name|expr>    Show hover information");
    println!();

    println!("{}", "Examples:".bold());
    println!("  S-expression:");
    println!("    > (let double (fn (x) (* x 2)))");
    println!("    > (double 21)");
    println!();
    println!("  Shell syntax:");
    println!("    > ls | filter kind function");
    println!("    > search type:Int | take 5");
    println!();
    println!("  Mixed:");
    println!("    > add double = fn x -> x * 2");
    println!("    > type-of (double 21)");
}
