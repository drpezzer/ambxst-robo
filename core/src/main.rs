// ambxst-robo: Ambxst Robo's daemon, Coucou's backend headless (see lib.rs).
//
//   ambxst-robo                     run the daemon
//   ambxst-robo --shortcut <id>     hand a shortcut to the running daemon (for compositor binds)
//   ambxst-robo --migrate-from-coucou [--dry-run] [--keep-coucou-hooks | --replace-coucou-hooks]
//                                   copy the coucou-core port's settings, data, chats,
//                                   keys and hooks over to Robo's names (migrate.rs)
//   ambxst-robo --version

use std::io::{BufRead, BufReader, Write};

use ambxst_robo::host::{async_runtime, AppHandle};
use ambxst_robo::server;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("ambxst-robo {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if args.iter().any(|a| a == "--migrate-from-coucou") {
        let code = match ambxst_robo::migrate::options_from_args(&args) {
            Ok(options) => ambxst_robo::migrate::run(&options),
            Err(err) => {
                eprintln!("ambxst-robo: {err}");
                2
            }
        };
        std::process::exit(code);
    }
    if args.iter().any(|a| a == "--shortcut") {
        std::process::exit(send_shortcut(&args));
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("ambxst-robo")
        .enable_all()
        .build()
        .expect("tokio runtime");
    async_runtime::set(runtime.handle().clone());

    let code = runtime.block_on(async {
        // Single instance: the client socket is bound first.
        let (listener, path) = match server::bind() {
            Ok(bound) => bound,
            Err(err) => {
                eprintln!("ambxst-robo: {err}");
                return 1;
            }
        };
        let app = AppHandle::new();
        ambxst_robo::start(&app);
        eprintln!("ambxst-robo: listening on {}", path.display());

        let serving = tokio::spawn(server::serve(app.clone(), listener));
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("SIGTERM");
        tokio::select! {
            _ = server::wait_for_shutdown() => {}
            _ = term.recv() => {}
            _ = tokio::signal::ctrl_c() => {}
        }
        serving.abort();
        let _ = std::fs::remove_file(&path);
        if let Some(relay) = ambxst_robo::relay_socket_if_serving() {
            let _ = std::fs::remove_file(relay);
        }
        ambxst_robo::log_line("ambxst-robo stopped");
        0
    });
    // Blocking tasks (a D-Bus call, a codex probe) are not waited for.
    runtime.shutdown_timeout(std::time::Duration::from_millis(200));
    std::process::exit(code);
}

/// `--shortcut <id>`: one request to the running daemon.
fn send_shortcut(args: &[String]) -> i32 {
    let Some(action) = ambxst_robo::shortcut_from_args(args) else {
        eprintln!("ambxst-robo: --shortcut needs a ported action id");
        return 2;
    };
    let Some(path) = server::socket_path() else { return 1 };
    let Ok(mut stream) = std::os::unix::net::UnixStream::connect(&path) else {
        eprintln!("ambxst-robo: not running");
        return 1;
    };
    let line = serde_json::json!({ "id": 1, "cmd": "shortcut_dispatch", "args": { "action": action } });
    if writeln!(stream, "{line}").is_err() {
        return 1;
    }
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(2)));
    let mut reader = BufReader::new(stream);
    let mut reply = String::new();
    while reader.read_line(&mut reply).is_ok() && !reply.is_empty() {
        // Skip events that arrive before our reply.
        if reply.contains("\"id\":1") {
            return if reply.contains("\"ok\":true") { 0 } else { 1 };
        }
        reply.clear();
    }
    1
}
