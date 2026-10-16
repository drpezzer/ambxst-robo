// Dropped files are copied into %LOCALAPPDATA%\Coucou\inbox so the original is
// never touched and the copy survives the drag source going away.
// The inbox is swept of anything older than a week, as on macOS.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::Serialize;

use crate::settings;

const KEEP_FOR: Duration = Duration::from_secs(7 * 24 * 60 * 60);

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DroppedFile {
    pub name: String,
    pub path: String,
    pub size: u64,
}

pub fn inbox_dir() -> PathBuf {
    settings::local_dir().join("inbox")
}

// ── Paths a real drop delivered ─────────────────────────────────────────────
//
// `ingest_file` is callable from the page, so on its own it would copy any file
// the user can read (a script injected into the page could pull in ~/.ssh).
// Only paths the OS just delivered through a real drop are accepted: WebView2's
// drop objects on Windows (webview_drop.rs), Tauri's drag-drop window event
// elsewhere (lib.rs). Each is good once, for a couple of minutes.

const DROP_VALID_FOR: Duration = Duration::from_secs(120);
const DROP_MAX_PENDING: usize = 64;

static DROPPED: std::sync::Mutex<Vec<(String, std::time::Instant)>> = std::sync::Mutex::new(Vec::new());

/// Records paths that came from a real drop.
pub fn allow_dropped<I: IntoIterator<Item = String>>(paths: I) {
    let mut list = DROPPED.lock().unwrap_or_else(|e| e.into_inner());
    let now = std::time::Instant::now();
    list.retain(|(_, at)| now.duration_since(*at) < DROP_VALID_FOR);
    for p in paths {
        list.push((p, now));
    }
    let excess = list.len().saturating_sub(DROP_MAX_PENDING);
    list.drain(..excess);
}

/// True (once) when `path` was delivered by a drop in the last couple of minutes.
fn take_dropped(path: &str) -> bool {
    let mut list = DROPPED.lock().unwrap_or_else(|e| e.into_inner());
    let now = std::time::Instant::now();
    list.retain(|(_, at)| now.duration_since(*at) < DROP_VALID_FOR);
    match list.iter().position(|(p, _)| p == path) {
        Some(i) => {
            list.remove(i);
            true
        }
        None => false,
    }
}

pub fn ingest(source: &str) -> Result<DroppedFile, String> {
    if !take_dropped(source) {
        return Err(crate::i18n::t("Only files dropped on the island can be added."));
    }
    let src = Path::new(source);
    let meta = std::fs::metadata(src)
        .map_err(|e| crate::i18n::tf("Cannot read {path}: {error}", &[("path", source), ("error", &e.to_string())]))?;
    let dir = inbox_dir();
    crate::platform::ensure_private_dir(&settings::local_dir()).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

    // Port (his ask): a folder is copied whole (within limits, without the
    // usual build and VCS clutter), so the chat can look through it.
    if meta.is_dir() {
        return ingest_folder(src, &dir);
    }

    let name = src
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".into());

    let mut dest = dir.join(&name);
    if dest.exists() {
        let stem = src.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let ext = src.extension().map(|s| format!(".{}", s.to_string_lossy())).unwrap_or_default();
        for i in 2..1000 {
            let candidate = dir.join(format!("{stem} ({i}){ext}"));
            if !candidate.exists() {
                dest = candidate;
                break;
            }
        }
    }

    std::fs::copy(src, &dest).map_err(|e| crate::i18n::tf("Cannot copy: {error}", &[("error", &e.to_string())]))?;
    // CopyFileEx carries the source's timestamps across, so a file last edited
    // three years ago would arrive already older than the sweep window and be
    // deleted on the spot. The inbox ages from when *we* copied it.
    if let Ok(file) = std::fs::File::options().write(true).open(&dest) {
        let _ = file.set_modified(SystemTime::now());
    }
    sweep(&dir);

    Ok(DroppedFile {
        name,
        path: dest.to_string_lossy().to_string(),
        size: meta.len(),
    })
}

/// Folders bigger than this are refused (files, bytes).
const FOLDER_MAX_FILES: usize = 2_000;
const FOLDER_MAX_BYTES: u64 = 200 * 1024 * 1024;
/// Not copied out of a dropped folder: version control, dependencies, build output.
const FOLDER_SKIP: [&str; 9] = [".git", "node_modules", "target", ".venv", "venv", "__pycache__", ".cache", "dist", "build"];

fn ingest_folder(src: &Path, inbox: &Path) -> Result<DroppedFile, String> {
    let name = src.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "folder".into());
    // What would be copied: every regular file, symlinks not followed.
    let mut files: Vec<(PathBuf, PathBuf)> = Vec::new();
    let mut bytes = 0u64;
    let mut stack = vec![(src.to_path_buf(), PathBuf::new())];
    while let Some((at, rel)) = stack.pop() {
        let entries = std::fs::read_dir(&at).map_err(|e| e.to_string())?;
        for entry in entries.flatten() {
            let Ok(ft) = entry.file_type() else { continue };
            let fname = entry.file_name();
            let r = rel.join(&fname);
            if ft.is_dir() {
                if !FOLDER_SKIP.contains(&fname.to_string_lossy().as_ref()) {
                    stack.push((entry.path(), r));
                }
            } else if ft.is_file() {
                bytes += entry.metadata().map(|m| m.len()).unwrap_or(0);
                files.push((entry.path(), r));
                if files.len() > FOLDER_MAX_FILES || bytes > FOLDER_MAX_BYTES {
                    return Err(crate::i18n::t("That folder is too big to drop (over 2,000 files or 200 MB)."));
                }
            }
        }
    }
    let mut dest = inbox.join(&name);
    for i in 2..1000 {
        if !dest.exists() {
            break;
        }
        dest = inbox.join(format!("{name} ({i})"));
    }
    for (from, rel) in &files {
        let to = dest.join(rel);
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        std::fs::copy(from, &to).map_err(|e| crate::i18n::tf("Cannot copy: {error}", &[("error", &e.to_string())]))?;
        if let Ok(file) = std::fs::File::options().write(true).open(&to) {
            let _ = file.set_modified(SystemTime::now());
        }
    }
    std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
    let _ = std::fs::File::options().read(true).open(&dest).and_then(|f| f.set_modified(SystemTime::now()));
    sweep(inbox);
    Ok(DroppedFile { name, path: dest.to_string_lossy().to_string(), size: bytes })
}

/// A dropped folder as text for a chat that can't open files itself: its tree,
/// then the text files' contents, up to `budget` characters.
pub fn folder_text(path: &Path, budget: usize) -> String {
    let mut list: Vec<PathBuf> = Vec::new();
    let mut stack = vec![path.to_path_buf()];
    while let Some(at) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&at) else { continue };
        let mut entries: Vec<_> = rd.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            match e.file_type() {
                Ok(t) if t.is_dir() => stack.push(e.path()),
                Ok(t) if t.is_file() => list.push(e.path()),
                _ => {}
            }
        }
    }
    list.sort();
    let rel = |p: &Path| p.strip_prefix(path).unwrap_or(p).display().to_string();
    let mut out = String::from("Folder contents:\n");
    for p in &list {
        out.push_str(&format!("  {}\n", rel(p)));
    }
    for p in &list {
        if out.len() >= budget {
            out.push_str("\n[more files not shown]");
            break;
        }
        let Ok(text) = std::fs::read_to_string(p) else { continue };
        let room = budget.saturating_sub(out.len());
        let body: String = text.chars().take(room).collect();
        out.push_str(&format!("\n--- {} ---\n{}", rel(p), body));
        if body.len() < text.len() {
            out.push_str("\n[truncated]");
        }
    }
    out
}

/// Drops anything copied here more than a week ago. `ingest` stamps every copy
/// with the time it landed, so this really is the age of the copy and not the
/// age of whatever the user happened to drag in.
fn sweep(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(copied) = meta.modified() else { continue };
        if now.duration_since(copied).map(|age| age > KEEP_FOR).unwrap_or(false) {
            if meta.is_dir() {
                let _ = std::fs::remove_dir_all(entry.path());
            } else {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_folder_is_copied_without_its_clutter_and_read_as_text() {
        let tmp = std::env::temp_dir().join(format!("robo-folder-{}", std::process::id()));
        let src = tmp.join("proj");
        std::fs::create_dir_all(src.join("src")).unwrap();
        std::fs::create_dir_all(src.join("node_modules/x")).unwrap();
        std::fs::write(src.join("src/main.rs"), b"fn main() {}").unwrap();
        std::fs::write(src.join("node_modules/x/big.js"), b"junk").unwrap();
        let inbox = tmp.join("inbox");
        std::fs::create_dir_all(&inbox).unwrap();
        let got = ingest_folder(&src, &inbox).unwrap();
        let dest = Path::new(&got.path);
        assert!(dest.join("src/main.rs").is_file());
        assert!(!dest.join("node_modules").exists());
        let text = folder_text(dest, 10_000);
        assert!(text.contains("src/main.rs") && text.contains("fn main() {}"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn ingest_copies_and_never_overwrites() {
        let tmp = std::env::temp_dir().join(format!("robo-test-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let source = tmp.join("note.txt");
        std::fs::write(&source, b"hello").unwrap();

        let drop = |p: &Path| allow_dropped([p.to_string_lossy().to_string()]);
        drop(&source);
        let first = ingest(source.to_str().unwrap()).unwrap();
        assert_eq!(first.name, "note.txt");
        assert_eq!(std::fs::read(&first.path).unwrap(), b"hello");

        // A second drop of the same name must not clobber the first copy.
        std::fs::write(&source, b"second").unwrap();
        drop(&source);
        let second = ingest(source.to_str().unwrap()).unwrap();
        assert_ne!(first.path, second.path);
        assert_eq!(std::fs::read(&first.path).unwrap(), b"hello");
        assert_eq!(std::fs::read(&second.path).unwrap(), b"second");

        // (Port: folders are accepted now, a_folder_is_copied_… covers them;
        // one never dropped is still refused.)
        assert!(ingest(tmp.to_str().unwrap()).is_err());

        // An ancient source must not arrive already older than the sweep window.
        let old_source = tmp.join("ancient.txt");
        std::fs::write(&old_source, b"old").unwrap();
        let long_ago = SystemTime::now() - KEEP_FOR - Duration::from_secs(60 * 60);
        std::fs::File::options()
            .write(true)
            .open(&old_source)
            .unwrap()
            .set_modified(long_ago)
            .unwrap();
        drop(&old_source);
        let aged = ingest(old_source.to_str().unwrap()).unwrap();
        assert!(
            Path::new(&aged.path).exists(),
            "a file copied just now was swept as if it were a week old"
        );
        let _ = std::fs::remove_file(&aged.path);

        let _ = std::fs::remove_file(&first.path);
        let _ = std::fs::remove_file(&second.path);
        let _ = std::fs::remove_dir_all(&tmp);
    }
}

#[cfg(test)]
mod drop_tests {
    use super::*;

    // One test: the list is process-wide and tests run in parallel.
    #[test]
    fn only_a_dropped_path_is_ingested_once_and_the_list_stays_bounded() {
        let p = "/tmp/coucou-test-not-dropped.txt".to_string();
        assert!(ingest(&p).is_err(), "never dropped");
        allow_dropped([p.clone()]);
        assert!(take_dropped(&p));
        assert!(!take_dropped(&p), "good once");

        allow_dropped((0..200).map(|i| format!("/tmp/bounded-{i}")));
        assert!(DROPPED.lock().unwrap().len() <= DROP_MAX_PENDING);
        assert!(take_dropped("/tmp/bounded-199"));
        assert!(!take_dropped("/tmp/bounded-0"));
    }
}
