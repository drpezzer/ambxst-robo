// `ambxst-robo --migrate-from-coucou [--dry-run]`: brings a user of the
// coucou-core port over to Ambxst Robo's own names.
//
// Everything is copied, never moved or deleted: the coucou-core port and the
// upstream Coucou app share ~/.config/coucou, ~/.local/share/coucou, the relay
// ~/.local/share/coucou/bin/coucou-hook and the Secret Service entries of
// `fr.louisraille.coucou` on Linux, and Coucou must keep working if it is
// installed. Running it again does nothing new: a file already at its new
// place is left as it is (Robo's own changes win), a secret Robo already has
// is not replaced, a hook already pointing at Robo's relay is not added twice.
//
// What it does:
//   * config  ~/.config/coucou → ~/.config/ambxst-robo (settings.json, sounds/)
//   * data    ~/.local/share/coucou → ~/.local/share/ambxst-robo (saved chats,
//             recap, inbox, trash, the chat's work folder, the saved status
//             line), not the log nor the coucou-hook binary;
//   * the Claude Code sessions of Coucou's chat folder, into the CLI's project
//     folder for Robo's (history.rs then lists only our copies);
//   * the Secret Service keys of `fr.louisraille.coucou` → `ambxst-robo`;
//   * Robo's relay into ~/.local/share/ambxst-robo/bin;
//   * Claude Code (~/.claude/settings.json) and Codex (~/.codex/hooks.json)
//     hook entries that run ~/.local/share/coucou/bin/coucou-hook: rewritten to
//     Robo's relay — or, when the upstream Coucou app is installed, Robo's
//     entries are added beside them so Coucou keeps its hooks. These two files
//     go through config_file.rs (strict read, dated backup, atomic write).
//
// `--dry-run` reads only and prints what would happen.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::config_file::{self, FileEdit};
use crate::{history, hooks, platform, secrets, settings};

/// How hook entries that run Coucou's relay become Robo's.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum HookMode {
    /// The entry now runs Robo's relay (Coucou is not installed).
    Replace,
    /// Coucou's entry stays and Robo's is added next to it.
    Beside,
}

/// What a hook rewrite did, for the report.
#[derive(Default, Debug, PartialEq)]
pub struct HookCounts {
    pub rewritten: usize,
    pub added: usize,
    /// Coucou entries dropped because Robo's own was already there (Replace).
    pub dropped: usize,
    /// Events where Robo's relay was already set up (Beside).
    pub already: usize,
    pub status_line: Option<&'static str>,
}

impl HookCounts {
    fn changed(&self) -> bool {
        self.rewritten + self.added + self.dropped > 0 || matches!(self.status_line, Some("rewritten"))
    }

    fn describe(&self) -> String {
        let mut parts = Vec::new();
        if self.rewritten > 0 {
            parts.push(format!("{} entr{} rewritten to Robo's relay", self.rewritten, plural_y(self.rewritten)));
        }
        if self.added > 0 {
            parts.push(format!("{} Robo entr{} added beside Coucou's", self.added, plural_y(self.added)));
        }
        if self.dropped > 0 {
            parts.push(format!("{} Coucou entr{} dropped (Robo's already there)", self.dropped, plural_y(self.dropped)));
        }
        if self.already > 0 {
            parts.push(format!("{} event{} already on Robo's relay", self.already, if self.already == 1 { "" } else { "s" }));
        }
        match self.status_line {
            Some("rewritten") => parts.push("status line moved to Robo's relay".into()),
            Some("kept") => parts.push("status line left to Coucou (one only; switch it in Robo's settings)".into()),
            _ => {}
        }
        if parts.is_empty() {
            "no Coucou relay entries".into()
        } else {
            parts.join(", ")
        }
    }
}

fn plural_y(n: usize) -> &'static str {
    if n == 1 { "y" } else { "ies" }
}

/// Codex shows this while it waits; the old text names Coucou.
const CODEX_WAITING_OLD: &str = "Waiting for your answer in the island (Coucou)";
const CODEX_WAITING_NEW: &str = "Waiting for your answer in the island (Robo)";

/// Coucou's relay and Robo's, each as the ways a hook command may spell it
/// (absolute, `~/…`, `$HOME/…`, `${HOME}/…`), the same way at the same index.
pub struct Relays {
    pairs: Vec<(String, String)>,
}

impl Relays {
    /// `old` and `new` are absolute paths; spellings relative to `home` are
    /// added for both when they live under it.
    pub fn new(old: &str, new: &str, home: &str) -> Self {
        let mut pairs = vec![(old.to_string(), new.to_string())];
        let home = home.trim_end_matches('/');
        if !home.is_empty() {
            if let (Some(o), Some(n)) = (old.strip_prefix(home), new.strip_prefix(home)) {
                if o.starts_with('/') && n.starts_with('/') {
                    for h in ["~", "$HOME", "${HOME}"] {
                        pairs.push((format!("{h}{o}"), format!("{h}{n}")));
                    }
                }
            }
        }
        Self { pairs }
    }

    fn has_old(&self, c: &str) -> bool {
        self.pairs.iter().any(|(o, _)| c.contains(o.as_str()))
    }

    fn has_new(&self, c: &str) -> bool {
        self.pairs.iter().any(|(_, n)| c.contains(n.as_str()))
    }

    fn swap(&self, c: &str) -> String {
        let mut c = c.to_string();
        for (o, n) in &self.pairs {
            c = c.replace(o.as_str(), n.as_str());
        }
        c
    }
}

/// A hook (`{"type":"command","command":…}`) moved from Coucou's relay to Robo's.
fn rewritten_hook(hook: &Value, r: &Relays) -> Value {
    let mut hook = hook.clone();
    if let Some(obj) = hook.as_object_mut() {
        if let Some(Value::String(c)) = obj.get("command") {
            let c = r.swap(c);
            obj.insert("command".into(), Value::String(c));
        }
        if obj.get("statusMessage").and_then(Value::as_str) == Some(CODEX_WAITING_OLD) {
            obj.insert("statusMessage".into(), json!(CODEX_WAITING_NEW));
        }
    }
    hook
}

fn runs_old(hook: &Value, r: &Relays) -> bool {
    hook.get("command").and_then(Value::as_str).is_some_and(|c| r.has_old(c))
}

fn runs_new(hook: &Value, r: &Relays) -> bool {
    hook.get("command").and_then(Value::as_str).is_some_and(|c| r.has_new(c))
}

/// Hook commands that mention `coucou-hook` without being Coucou's relay at
/// its usual place: reported, never touched.
pub fn other_coucou_hooks(root: &Value, r: &Relays) -> usize {
    let mut n = 0;
    if let Some(hooks) = root.get("hooks").and_then(Value::as_object) {
        for list in hooks.values().filter_map(Value::as_array) {
            for g in list {
                for h in group_hooks(g).into_iter().flatten() {
                    if let Some(c) = h.get("command").and_then(Value::as_str) {
                        if c.contains(platform::LEGACY_HOOK_EXE) && !r.has_old(c) {
                            n += 1;
                        }
                    }
                }
            }
        }
    }
    n
}

fn group_hooks(group: &Value) -> Option<&Vec<Value>> {
    group.get("hooks").and_then(Value::as_array)
}

/// `root` (Claude Code's settings.json or Codex's hooks.json) with every hook
/// that runs `old` (Coucou's relay path) moved to `new` (Robo's), as `mode`
/// says. Only those entries change; anything of an unexpected shape is left
/// exactly as it is.
pub fn rewrite_hooks(root: &Value, r: &Relays, mode: HookMode) -> (Value, HookCounts) {
    let mut counts = HookCounts::default();
    let mut root = root.clone();
    let Some(obj) = root.as_object_mut() else { return (root, counts) };

    if let Some(Value::Object(hooks)) = obj.get_mut("hooks") {
        let mut emptied = Vec::new();
        for (event, list) in hooks.iter_mut() {
            let Some(list) = list.as_array_mut() else { continue };
            if list.is_empty() {
                continue;
            }
            let mut has_new = list.iter().any(|g| group_hooks(g).is_some_and(|h| h.iter().any(|h| runs_new(h, r))));
            let mut out: Vec<Value> = Vec::with_capacity(list.len());
            let mut extra: Vec<Value> = Vec::new();
            let mut counted_already = false;
            for group in list.iter() {
                let Some(hs) = group_hooks(group) else {
                    out.push(group.clone());
                    continue;
                };
                if !hs.iter().any(|h| runs_old(h, r)) {
                    out.push(group.clone());
                    continue;
                }
                match mode {
                    HookMode::Replace if has_new => {
                        // Robo's entry is there already: Coucou's relay goes.
                        let kept: Vec<Value> = hs.iter().filter(|h| !runs_old(h, r)).cloned().collect();
                        counts.dropped += hs.len() - kept.len();
                        if !kept.is_empty() {
                            let mut g = group.clone();
                            g["hooks"] = Value::Array(kept);
                            out.push(g);
                        }
                    }
                    HookMode::Replace => {
                        let mut g = group.clone();
                        let new_hooks: Vec<Value> = hs
                            .iter()
                            .map(|h| {
                                if runs_old(h, r) {
                                    counts.rewritten += 1;
                                    rewritten_hook(h, r)
                                } else {
                                    h.clone()
                                }
                            })
                            .collect();
                        g["hooks"] = Value::Array(new_hooks);
                        out.push(g);
                    }
                    HookMode::Beside => {
                        out.push(group.clone());
                        if has_new {
                            if !counted_already {
                                counts.already += 1;
                                counted_already = true;
                            }
                            continue;
                        }
                        let mut g = group.clone();
                        let ours: Vec<Value> =
                            hs.iter().filter(|h| runs_old(h, r)).map(|h| rewritten_hook(h, r)).collect();
                        counts.added += ours.len();
                        g["hooks"] = Value::Array(ours);
                        extra.push(g);
                        has_new = true;
                    }
                }
            }
            out.extend(extra);
            if out.is_empty() {
                emptied.push(event.clone());
            }
            *list = out;
        }
        // An event left with nothing in it by us goes, as uninstalling does.
        for event in emptied {
            hooks.remove(&event);
        }
    }

    // Claude Code's status line: one command only.
    if let Some(sl) = obj.get_mut("statusLine") {
        if sl.get("command").and_then(Value::as_str).is_some_and(|c| r.has_old(c)) {
            match mode {
                HookMode::Replace => {
                    *sl = rewritten_hook(sl, r);
                    counts.status_line = Some("rewritten");
                }
                HookMode::Beside => counts.status_line = Some("kept"),
            }
        }
    }
    (root, counts)
}

/// Strings that are `from` or a path under it become the same under `to`.
pub fn rewrite_paths(v: &mut Value, from: &str, to: &str) -> usize {
    match v {
        Value::String(s) => {
            if s == from || s.strip_prefix(from).is_some_and(|rest| rest.starts_with('/')) {
                *s = format!("{to}{}", &s[from.len()..]);
                1
            } else {
                0
            }
        }
        Value::Array(a) => a.iter_mut().map(|x| rewrite_paths(x, from, to)).sum(),
        Value::Object(o) => o.values_mut().map(|x| rewrite_paths(x, from, to)).sum(),
        _ => 0,
    }
}

// ── The upstream Coucou app ───────────────────────────────────────────────────

/// Where the upstream Coucou app is installed, if it is: a `coucou` program on
/// $PATH, a coucou .desktop entry, or /opt/coucou. Its hooks then stay.
pub fn upstream_coucou() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            let exe = dir.join("coucou");
            if exe.is_file() {
                return Some(exe);
            }
        }
    }
    let home = platform::home_dir();
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(".local/share"));
    let data_dirs = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    let mut app_dirs = vec![data_home.join("applications")];
    app_dirs.extend(data_dirs.split(':').filter(|s| !s.is_empty()).map(|d| PathBuf::from(d).join("applications")));
    for dir in app_dirs {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_lowercase();
            if name.ends_with(".desktop") && name.contains("coucou") && !name.contains("robo") {
                return Some(e.path());
            }
        }
    }
    let opt = PathBuf::from("/opt/coucou");
    opt.exists().then_some(opt)
}

// ── Copying files ─────────────────────────────────────────────────────────────

#[derive(Default)]
struct CopyStats {
    copied: usize,
    already: usize,
    skipped: Vec<String>,
    errors: Vec<String>,
    /// Relative paths of copied files, for the session record.
    files: Vec<PathBuf>,
}

/// Copies every regular file under `src` to the same place under `dst`, unless
/// one is already there. `skip(rel)` leaves a file or folder out. A `.json`
/// file `rewrite(rel)` names goes through `rewrite_paths` on the way.
fn copy_tree(
    src: &Path,
    dst: &Path,
    rel: &Path,
    dry: bool,
    skip: &dyn Fn(&Path) -> bool,
    rewrite: &dyn Fn(&Path) -> Option<(String, String)>,
    stats: &mut CopyStats,
) {
    let from = src.join(rel);
    let Ok(entries) = std::fs::read_dir(&from) else {
        if from.exists() {
            stats.errors.push(format!("cannot read {}", from.display()));
        }
        return;
    };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let r = rel.join(e.file_name());
        if skip(&r) {
            stats.skipped.push(r.display().to_string());
            continue;
        }
        let Ok(ft) = e.file_type() else { continue };
        let to = dst.join(&r);
        if ft.is_dir() {
            if !dry {
                if let Err(err) = make_dir(&to) {
                    stats.errors.push(format!("{}: {err}", to.display()));
                    continue;
                }
            }
            copy_tree(src, dst, &r, dry, skip, rewrite, stats);
        } else if ft.is_file() {
            if to.symlink_metadata().is_ok() {
                stats.already += 1;
                continue;
            }
            stats.files.push(r.clone());
            stats.copied += 1;
            if dry {
                continue;
            }
            let result = match rewrite(&r) {
                Some((old, new)) => copy_json_rewritten(&e.path(), &to, &old, &new),
                None => std::fs::copy(e.path(), &to).map(|_| ()),
            };
            if let Err(err) = result {
                stats.copied -= 1;
                stats.files.pop();
                stats.errors.push(format!("{}: {err}", to.display()));
            }
        } else {
            stats.skipped.push(format!("{} (not a regular file)", r.display()));
        }
    }
}

fn make_dir(dir: &Path) -> std::io::Result<()> {
    let mut b = std::fs::DirBuilder::new();
    b.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        b.mode(0o700);
    }
    b.create(dir)
}

/// A JSON file copied with its paths moved; one that does not parse is copied
/// as it is.
fn copy_json_rewritten(from: &Path, to: &Path, old: &str, new: &str) -> std::io::Result<()> {
    let bytes = std::fs::read(from)?;
    let Ok(mut v) = serde_json::from_slice::<Value>(&bytes) else {
        std::fs::copy(from, to)?;
        return Ok(());
    };
    if rewrite_paths(&mut v, old, new) == 0 {
        std::fs::copy(from, to)?;
        return Ok(());
    }
    let mut text = serde_json::to_string_pretty(&v).unwrap_or_default();
    text.push('\n');
    std::fs::write(to, text)?;
    if let Ok(meta) = std::fs::metadata(from) {
        let _ = std::fs::set_permissions(to, meta.permissions());
    }
    Ok(())
}

fn tilde(p: &Path) -> String {
    let home = platform::home_dir();
    match p.strip_prefix(&home) {
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => p.display().to_string(),
    }
}

fn summary(stats: &CopyStats, dry: bool) -> String {
    let mut s = format!(
        "{} file{} {}, {} already there",
        stats.copied,
        if stats.copied == 1 { "" } else { "s" },
        if dry { "to copy" } else { "copied" },
        stats.already
    );
    if !stats.skipped.is_empty() {
        s.push_str(&format!("; left out: {}", stats.skipped.join(", ")));
    }
    s
}

// ── The run ───────────────────────────────────────────────────────────────────

pub struct Options {
    pub dry_run: bool,
    /// None: decided by whether Coucou is installed.
    pub hook_mode: Option<HookMode>,
}

pub fn options_from_args(args: &[String]) -> Result<Options, String> {
    let mut o = Options { dry_run: false, hook_mode: None };
    for a in args.iter().skip(1) {
        match a.as_str() {
            "--migrate-from-coucou" => {}
            "--dry-run" | "-n" => o.dry_run = true,
            "--keep-coucou-hooks" => o.hook_mode = Some(HookMode::Beside),
            "--replace-coucou-hooks" => o.hook_mode = Some(HookMode::Replace),
            other => return Err(format!("unknown option {other}")),
        }
    }
    Ok(o)
}

/// Runs the migration and prints what it does. 0: done (or nothing to do),
/// 1: something failed (everything else still ran).
pub fn run(o: &Options) -> i32 {
    let dry = o.dry_run;
    let mut failed = false;
    let out = |line: String| println!("{line}");
    out(format!(
        "Ambxst Robo: migrating from Coucou{}",
        if dry { " — dry run, nothing is written" } else { " — copying, nothing of Coucou's is removed" }
    ));

    let old_config = platform::legacy_config_dir();
    let new_config = settings::config_dir();
    let old_data = platform::legacy_local_dir();
    let new_data = settings::local_dir();
    if !old_config.exists() && !old_data.exists() {
        out(format!("  nothing to migrate: neither {} nor {} exists", tilde(&old_config), tilde(&old_data)));
    }
    let old_data_s = old_data.display().to_string();
    let new_data_s = new_data.display().to_string();

    // ── Config ──
    if old_config.is_dir() {
        if !dry {
            if let Err(e) = platform::ensure_private_dir(&new_config) {
                out(format!("  config   cannot create {}: {e}", tilde(&new_config)));
                failed = true;
            }
        }
        let mut stats = CopyStats::default();
        let (od, nd) = (old_data_s.clone(), new_data_s.clone());
        let rewrite = move |r: &Path| (r == Path::new("settings.json")).then(|| (od.clone(), nd.clone()));
        copy_tree(&old_config, &new_config, Path::new(""), dry, &|_| false, &rewrite, &mut stats);
        out(format!("  config   {} → {}: {}", tilde(&old_config), tilde(&new_config), summary(&stats, dry)));
        for e in &stats.errors {
            out(format!("           error: {e}"));
            failed = true;
        }
    }

    // ── Data ──
    if old_data.is_dir() {
        if !dry {
            if let Err(e) = platform::ensure_private_dir(&new_data) {
                out(format!("  data     cannot create {}: {e}", tilde(&new_data)));
                failed = true;
            }
        }
        let mut stats = CopyStats::default();
        // The relay binary is Robo's own (installed below); the log stays Coucou's.
        let skip = |r: &Path| {
            r == Path::new("bin").join(platform::LEGACY_HOOK_EXE)
                || r == Path::new("coucou.log")
                || r.extension().is_some_and(|e| e == "sock")
        };
        let (od, nd) = (old_data_s.clone(), new_data_s.clone());
        let rewrite = move |r: &Path| {
            let json = r.extension().is_some_and(|e| e == "json");
            let wanted = r == Path::new("current-chat.json") || (r.starts_with("chats") && json);
            wanted.then(|| (od.clone(), nd.clone()))
        };
        copy_tree(&old_data, &new_data, Path::new(""), dry, &skip, &rewrite, &mut stats);
        let chats = stats.files.iter().filter(|r| r.starts_with("chats")).count();
        out(format!(
            "  data     {} → {}: {} (saved chats among them: {chats})",
            tilde(&old_data),
            tilde(&new_data),
            summary(&stats, dry)
        ));
        for e in &stats.errors {
            out(format!("           error: {e}"));
            failed = true;
        }
    }

    // ── Claude Code sessions of Coucou's chat folder ──
    {
        let old_proj = history::project_dir_for(&history::legacy_cli_dir());
        let new_proj = history::project_dir_for(&history::own_cli_dir());
        if old_proj.is_dir() {
            if !dry {
                if let Err(e) = std::fs::create_dir_all(&new_proj) {
                    out(format!("  sessions cannot create {}: {e}", tilde(&new_proj)));
                    failed = true;
                }
            }
            let mut stats = CopyStats::default();
            copy_tree(&old_proj, &new_proj, Path::new(""), dry, &|_| false, &|_| None, &mut stats);
            // Every session now in both folders is ours to list (history.rs).
            let ids: BTreeSet<String> = std::fs::read_dir(&old_proj)
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|e| {
                    let p = e.path();
                    (p.extension().is_some_and(|x| x == "jsonl")).then(|| p.file_stem()?.to_str().map(str::to_string)).flatten()
                })
                .filter(|sid| dry || new_proj.join(format!("{sid}.jsonl")).is_file())
                .collect();
            out(format!(
                "  sessions Claude Code chat sessions {} → {}: {} ({} session{})",
                tilde(&old_proj),
                tilde(&new_proj),
                summary(&stats, dry),
                ids.len(),
                if ids.len() == 1 { "" } else { "s" }
            ));
            for e in &stats.errors {
                out(format!("           error: {e}"));
                failed = true;
            }
            if !dry && !ids.is_empty() {
                let mut all: BTreeSet<String> = history::migrated_sessions().into_iter().collect();
                all.extend(ids);
                let record = json!({
                    "from": old_proj.display().to_string(),
                    "sessions": all.into_iter().collect::<Vec<_>>(),
                });
                let path = history::migrated_record_path();
                if let Err(e) = std::fs::write(&path, format!("{}\n", config_file::pretty(&record))) {
                    out(format!("           error: {}: {e}", path.display()));
                    failed = true;
                }
            }
        } else {
            out("  sessions no Claude Code sessions in Coucou's chat folder".into());
        }
    }

    // ── Keyring ──
    {
        let mut to_copy = Vec::new();
        let mut already = Vec::new();
        let mut problems = Vec::new();
        for key in secrets::KNOWN_KEYS {
            match secrets::legacy_get(key) {
                Ok(Some(value)) => {
                    if secrets::get(key).is_some() {
                        already.push(*key);
                        continue;
                    }
                    if !dry {
                        if let Err(e) = secrets::set(key, &value) {
                            problems.push(format!("{key}: {e}"));
                            continue;
                        }
                    }
                    to_copy.push(*key);
                }
                Ok(None) => {}
                Err(e) => {
                    problems.push(format!("{key}: {e}"));
                    // The Secret Service is not there: no point asking for the rest.
                    break;
                }
            }
        }
        out(format!(
            "  keyring  {} → {}: {} {} {}{}",
            secrets::LEGACY_SERVICE,
            secrets::SERVICE,
            to_copy.len(),
            if to_copy.len() == 1 { "secret" } else { "secrets" },
            if dry { "to copy" } else { "copied" },
            if to_copy.is_empty() { String::new() } else { format!(" ({})", to_copy.join(", ")) }
        ));
        if !already.is_empty() {
            out(format!("           already in Robo's keyring: {}", already.join(", ")));
        }
        for p in problems {
            out(format!("           error: {p}"));
            failed = true;
        }
    }

    // ── Relay ──
    let new_relay = settings::hook_exe_path();
    let relay_ok = if new_relay.is_file() {
        out(format!("  relay    {} is already installed", tilde(&new_relay)));
        true
    } else {
        match hooks::relay_source() {
            Some(src) if dry => {
                out(format!("  relay    would install {} → {}", src.display(), tilde(&new_relay)));
                true
            }
            Some(src) => match hooks::install_relay_checked(&src, &new_relay) {
                Ok(()) => {
                    out(format!("  relay    installed {} → {}", src.display(), tilde(&new_relay)));
                    true
                }
                Err(e) => {
                    out(format!("  relay    {e}"));
                    failed = true;
                    false
                }
            },
            None => {
                out(format!(
                    "  relay    {} not found next to this binary: build it (`cargo build --release`) and run this again; hooks are not touched until it is there",
                    platform::HOOK_EXE
                ));
                false
            }
        }
    };

    // ── Hooks ──
    let upstream = upstream_coucou();
    let mode = o.hook_mode.unwrap_or(if upstream.is_some() { HookMode::Beside } else { HookMode::Replace });
    match &upstream {
        Some(p) => out(format!("  coucou   the Coucou app is installed ({}): its hooks are kept", tilde(p))),
        None => out("  coucou   the Coucou app is not installed".into()),
    }
    out(format!(
        "  hooks    mode: {}",
        match mode {
            HookMode::Replace => "rewrite Coucou relay entries to Robo's relay",
            HookMode::Beside => "add Robo's entries beside Coucou's",
        }
    ));
    let old_relay = old_data.join("bin").join(platform::LEGACY_HOOK_EXE).display().to_string();
    let new_relay_s = new_relay.display().to_string();
    let home = platform::home_dir();
    let relays = Relays::new(&old_relay, &new_relay_s, &home.display().to_string());
    for (label, path) in [
        ("Claude Code", hooks::settings_path()),
        ("Codex", home.join(".codex").join("hooks.json")),
    ] {
        let line = |s: String| format!("  hooks    {label} ({}): {s}", tilde(&path));
        let current = match config_file::read(&path).and_then(|b| match b {
            None => Ok(None),
            Some(b) => config_file::parse_json(Some(&b), &path.display().to_string()).map(Some),
        }) {
            Ok(Some(v)) => v,
            Ok(None) => {
                out(line("no such file".into()));
                continue;
            }
            Err(e) => {
                out(line(format!("left alone: {e}")));
                failed = true;
                continue;
            }
        };
        let (_, counts) = rewrite_hooks(&current, &relays, mode);
        let others = other_coucou_hooks(&current, &relays);
        if others > 0 {
            out(line(format!("{others} other command{} mention coucou-hook elsewhere: left alone", if others == 1 { "" } else { "s" })));
        }
        if !counts.changed() {
            out(line(counts.describe()));
            continue;
        }
        if dry {
            out(line(format!("would change: {}", counts.describe())));
            continue;
        }
        if !relay_ok {
            out(line(format!("not changed (no relay yet): {}", counts.describe())));
            continue;
        }
        let r2 = Relays::new(&old_relay, &new_relay_s, &home.display().to_string());
        let edits = vec![FileEdit {
            path: path.clone(),
            edit: config_file::json_edit(path.display().to_string(), move |v| Ok(Some(rewrite_hooks(v, &r2, mode).0))),
        }];
        match config_file::preview(&edits).and_then(|plan| config_file::apply(&edits, &plan.fingerprint)) {
            Ok(backups) => {
                let b = backups.first().map(|p| format!(" (backup: {})", tilde(p))).unwrap_or_default();
                out(line(format!("{}{b}", counts.describe())));
                if label == "Codex" {
                    out("           Codex runs changed hooks only once you trust them again: start Codex and review them with /hooks.".into());
                }
            }
            Err(e) => {
                out(line(format!("not changed: {e}")));
                failed = true;
            }
        }
    }

    // ── What is not migrated ──
    let others: Vec<&str> = [
        ("Gemini CLI", home.join(".gemini/settings.json")),
        ("Antigravity", home.join(".gemini/config/hooks.json")),
        ("Cursor", home.join(".cursor/hooks.json")),
        ("Copilot CLI", home.join(".copilot/hooks/coucou.json")),
        ("Muse", home.join(".config/muse/settings.json")),
        ("OpenCode", home.join(".config/opencode/plugins/coucou.js")),
        ("Amp", home.join(".config/amp/plugins/coucou.ts")),
        ("Hermes", home.join(".hermes/plugins/coucou/__init__.py")),
    ]
    .into_iter()
    .filter(|(_, p)| std::fs::read_to_string(p).is_ok_and(|t| t.contains(platform::LEGACY_HOOK_EXE)))
    .map(|(n, _)| n)
    .collect();
    if !others.is_empty() {
        out(format!(
            "  agents   Coucou entries left as they are for: {} — turn them on for Robo in Settings → Agents",
            others.join(", ")
        ));
    }
    let unit = home.join(".config/systemd/user/coucou-core.service");
    if unit.exists() {
        out("  service  coucou-core.service is still there: once Robo runs, `systemctl --user disable --now coucou-core.service`".into());
    }
    if failed {
        out("Some steps failed (above); the rest was done. Run it again once fixed: it only does what is missing.".into());
        1
    } else {
        out(if dry { "Dry run done: run without --dry-run to migrate.".into() } else { "Done.".into() });
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OLD: &str = "/home/me/.local/share/coucou/bin/coucou-hook";
    const NEW: &str = "/home/me/.local/share/ambxst-robo/bin/ambxst-robo-hook";

    fn relays() -> Relays {
        Relays::new(OLD, NEW, "/home/me")
    }

    #[test]
    fn home_relative_spellings_move_too_and_others_are_counted() {
        let v = json!({ "hooks": { "Stop": [
            { "hooks": [{ "command": "$HOME/.local/share/coucou/bin/coucou-hook Stop" }] },
            { "hooks": [{ "command": "~/.local/share/coucou/bin/coucou-hook --agent x" }] },
            { "hooks": [{ "command": "/opt/elsewhere/coucou-hook Stop" }] }
        ] } });
        let (after, c) = rewrite_hooks(&v, &relays(), HookMode::Replace);
        assert_eq!(c.rewritten, 2);
        assert_eq!(after["hooks"]["Stop"][0]["hooks"][0]["command"], "$HOME/.local/share/ambxst-robo/bin/ambxst-robo-hook Stop");
        assert_eq!(after["hooks"]["Stop"][1]["hooks"][0]["command"], "~/.local/share/ambxst-robo/bin/ambxst-robo-hook --agent x");
        assert_eq!(after["hooks"]["Stop"][2], v["hooks"]["Stop"][2]);
        assert_eq!(other_coucou_hooks(&v, &relays()), 1);
    }

    fn settings() -> Value {
        json!({
            "model": "opus",
            "hooks": {
                "Stop": [
                    { "hooks": [{ "type": "command", "command": "/usr/bin/notify" }] },
                    { "hooks": [{ "type": "command", "command": format!("'{OLD}' Stop"), "timeout": 10 }] }
                ],
                "PreToolUse": [
                    { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/bin/guard" }] }
                ],
                "PermissionRequest": [
                    { "hooks": [{ "type": "command", "command": format!("'{OLD}' --agent codex"), "timeout": 120,
                                  "statusMessage": CODEX_WAITING_OLD }] }
                ]
            },
            "statusLine": { "type": "command", "command": format!("'{OLD}' --statusline"), "padding": 1 }
        })
    }

    #[test]
    fn replace_rewrites_only_coucous_relay_and_is_idempotent() {
        let (after, c) = rewrite_hooks(&settings(), &relays(), HookMode::Replace);
        assert_eq!(c.rewritten, 2);
        assert_eq!(c.status_line, Some("rewritten"));
        assert_eq!(after["hooks"]["Stop"][0]["hooks"][0]["command"], "/usr/bin/notify");
        assert_eq!(after["hooks"]["Stop"][1]["hooks"][0]["command"], format!("'{NEW}' Stop"));
        assert_eq!(after["hooks"]["Stop"][1]["hooks"][0]["timeout"], 10);
        assert_eq!(after["hooks"]["PreToolUse"], settings()["hooks"]["PreToolUse"]);
        assert_eq!(after["hooks"]["PermissionRequest"][0]["hooks"][0]["statusMessage"], CODEX_WAITING_NEW);
        assert_eq!(after["statusLine"]["command"], format!("'{NEW}' --statusline"));
        assert_eq!(after["statusLine"]["padding"], 1);
        assert_eq!(after["model"], "opus");
        let (again, c2) = rewrite_hooks(&after, &relays(), HookMode::Replace);
        assert_eq!(again, after);
        assert!(!c2.changed());
    }

    #[test]
    fn beside_keeps_coucous_entries_and_adds_robos_once() {
        let (after, c) = rewrite_hooks(&settings(), &relays(), HookMode::Beside);
        assert_eq!(c.added, 2);
        assert_eq!(c.status_line, Some("kept"));
        let stop = after["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop.len(), 3);
        assert_eq!(stop[1]["hooks"][0]["command"], format!("'{OLD}' Stop"));
        assert_eq!(stop[2]["hooks"][0]["command"], format!("'{NEW}' Stop"));
        assert_eq!(after["statusLine"], settings()["statusLine"]);
        let (again, c2) = rewrite_hooks(&after, &relays(), HookMode::Beside);
        assert_eq!(again, after);
        assert!(!c2.changed());
        assert_eq!(c2.already, 2);
    }

    #[test]
    fn replace_after_robo_is_installed_drops_the_duplicate() {
        let (beside, _) = rewrite_hooks(&settings(), &relays(), HookMode::Beside);
        let (after, c) = rewrite_hooks(&beside, &relays(), HookMode::Replace);
        assert_eq!(c.dropped, 2);
        let stop = after["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop.len(), 2);
        assert_eq!(stop[1]["hooks"][0]["command"], format!("'{NEW}' Stop"));
    }

    #[test]
    fn other_shapes_and_other_relays_are_left_alone() {
        let odd = json!({ "hooks": { "Stop": "not-a-list", "X": [1, { "hooks": "nope" }] }, "statusLine": "x" });
        let (after, c) = rewrite_hooks(&odd, &relays(), HookMode::Replace);
        assert_eq!(after, odd);
        assert!(!c.changed());
        // Somebody else's coucou-hook (another path) is not Coucou's relay here.
        let elsewhere = json!({ "hooks": { "Stop": [{ "hooks": [{ "command": "/opt/x/coucou-hook Stop" }] }] } });
        assert_eq!(rewrite_hooks(&elsewhere, &relays(), HookMode::Replace).0, elsewhere);
    }

    #[test]
    fn paths_under_the_old_data_dir_move_and_nothing_else() {
        let mut v = json!({
            "a": "/home/me/.local/share/coucou/chat-claudecode",
            "b": ["/home/me/.local/share/coucou/inbox/x.png", "/home/me/.local/share/coucoux"],
            "c": { "d": "text mentioning /home/me/.local/share/coucou in a sentence" }
        });
        let n = rewrite_paths(&mut v, "/home/me/.local/share/coucou", "/home/me/.local/share/ambxst-robo");
        assert_eq!(n, 2);
        assert_eq!(v["a"], "/home/me/.local/share/ambxst-robo/chat-claudecode");
        assert_eq!(v["b"][0], "/home/me/.local/share/ambxst-robo/inbox/x.png");
        assert_eq!(v["b"][1], "/home/me/.local/share/coucoux");
    }

    #[test]
    fn copying_a_tree_never_overwrites_and_runs_twice_the_same() {
        let base = std::env::temp_dir().join(format!("robo-migrate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let (src, dst) = (base.join("src"), base.join("dst"));
        std::fs::create_dir_all(src.join("chats")).unwrap();
        std::fs::create_dir_all(src.join("bin")).unwrap();
        std::fs::write(src.join("chats/a.json"), r#"{"workDir":"/old/x"}"#).unwrap();
        std::fs::write(src.join("bin/coucou-hook"), "elf").unwrap();
        std::fs::write(src.join("keep.txt"), "old").unwrap();
        std::fs::create_dir_all(&dst).unwrap();
        std::fs::write(dst.join("keep.txt"), "robo's own").unwrap();
        let skip = |r: &Path| r == Path::new("bin/coucou-hook");
        let rw = |r: &Path| r.starts_with("chats").then(|| ("/old".to_string(), "/new".to_string()));

        let mut dry = CopyStats::default();
        copy_tree(&src, &dst, Path::new(""), true, &skip, &rw, &mut dry);
        assert_eq!((dry.copied, dry.already), (1, 1));
        assert!(!dst.join("chats").exists(), "a dry run writes nothing");

        let mut real = CopyStats::default();
        copy_tree(&src, &dst, Path::new(""), false, &skip, &rw, &mut real);
        assert_eq!((real.copied, real.already), (1, 1));
        assert_eq!(std::fs::read_to_string(dst.join("keep.txt")).unwrap(), "robo's own");
        assert!(!dst.join("bin/coucou-hook").exists());
        let chat: Value = serde_json::from_slice(&std::fs::read(dst.join("chats/a.json")).unwrap()).unwrap();
        assert_eq!(chat["workDir"], "/new/x");
        assert!(src.join("chats/a.json").exists() && src.join("bin/coucou-hook").exists(), "nothing is moved");

        let mut again = CopyStats::default();
        copy_tree(&src, &dst, Path::new(""), false, &skip, &rw, &mut again);
        assert_eq!((again.copied, again.already), (0, 2));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn options() {
        let a = |v: &[&str]| options_from_args(&v.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        let o = a(&["robo", "--migrate-from-coucou", "--dry-run"]).unwrap();
        assert!(o.dry_run && o.hook_mode.is_none());
        assert_eq!(a(&["robo", "--migrate-from-coucou", "--keep-coucou-hooks"]).unwrap().hook_mode, Some(HookMode::Beside));
        assert!(a(&["robo", "--migrate-from-coucou", "--bogus"]).is_err());
    }
}
