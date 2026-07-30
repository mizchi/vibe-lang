//! Small CLI exercising the `viberun_client` library.
//!
//! Usage:
//!   viberun_client <wasm-or-cwasm> <case> [<case>...]
//!   viberun_client --runs N <wasm-or-cwasm> <case>
//!
//! Spawns one daemon, sends each case as a `--check <case>` request,
//! prints `req_id\telapsed_us\texit_code` per response. Demonstrates
//! the cold/warm gap (first response includes the ~179ms
//! ensure_builtin_modules cost, subsequent ones don't).

use viberun_client::Client;
use std::process::ExitCode;

fn print_help() {
    eprintln!(
        "viberun_client — daemon protocol exerciser\n\
         \n\
         USAGE:\n\
           viberun_client <wasm|cwasm> <case> [<case>...]\n\
           viberun_client --runs N <wasm|cwasm> <case>\n\
         \n\
         ENV:\n\
           MOONRUN_WT_BIN   path to viberun (default: \n\
                            runtime/viberun/target/release/viberun)\n"
    );
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty()
        || args.first().map(|s| s.as_str()) == Some("--help")
        || args.first().map(|s| s.as_str()) == Some("-h")
    {
        print_help();
        return if args.is_empty() {
            ExitCode::from(2)
        } else {
            ExitCode::SUCCESS
        };
    }

    // Optional `--runs N <wasm> <case>` form.
    let (runs, wasm, cases): (usize, &String, Vec<String>) =
        if args[0] == "--runs" {
            if args.len() < 4 {
                print_help();
                return ExitCode::from(2);
            }
            let n: usize = match args[1].parse() {
                Ok(n) if n > 0 => n,
                _ => {
                    eprintln!("--runs: positive integer required, got {:?}", args[1]);
                    return ExitCode::from(2);
                }
            };
            // One case, repeated N times.
            (n, &args[2], std::iter::repeat(args[3].clone()).take(n).collect())
        } else {
            if args.len() < 2 {
                print_help();
                return ExitCode::from(2);
            }
            // Wasm path + one or more cases.
            let cs: Vec<String> = args.iter().skip(1).cloned().collect();
            (cs.len(), &args[0], cs)
        };

    let mut client = match Client::spawn(wasm) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("viberun_client: {e}");
            return ExitCode::from(1);
        }
    };

    println!("req_id\telapsed_us\texit_code\tcase");
    let mut last_exit = 0i32;
    for case in &cases {
        match client.send(&["--check", case]) {
            Ok(resp) => {
                println!(
                    "{}\t{}\t{}\t{}",
                    resp.req_id, resp.elapsed_us, resp.exit_code, case
                );
                if resp.exit_code != 0 {
                    last_exit = resp.exit_code;
                    eprintln!("(wasm stdout for failing req {}):", resp.req_id);
                    eprintln!("{}", resp.stdout);
                }
            }
            Err(e) => {
                eprintln!("viberun_client: request failed: {e}");
                return ExitCode::from(1);
            }
        }
    }

    let _ = runs; // tracked for the CLI form's intent; not currently used after dispatch
    match client.shutdown_and_wait() {
        Ok(status) => {
            if !status.success() && last_exit == 0 {
                last_exit = 1;
            }
        }
        Err(e) => {
            eprintln!("viberun_client: daemon wait: {e}");
            return ExitCode::from(1);
        }
    }
    if last_exit == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(last_exit.clamp(0, 255) as u8)
    }
}
