// What Tauri used to provide, without Tauri: an `AppHandle` that can emit
// events and hold managed state, and an async runtime to spawn on.
//
// Every `emit` / `emit_to` of the Tauri code ends up here and is broadcast to
// every client connected to ambxst-robo-core.sock as one line of JSON:
//   {"event":"<name>","payload":<json>,"target":<window label or null>}
// Nothing is buffered for clients that are not connected: like a webview that
// isn't listening, an event nobody hears is simply gone.

use std::any::{Any, TypeId};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use serde::Serialize;
use serde_json::{json, Value};
use tokio::sync::mpsc::UnboundedSender;

/// The island's window label in the Tauri app. Events Coucou sent to it keep
/// it as their `target`, so the QML side can tell them from broadcasts.
pub const WINDOW_LABEL: &str = "island";

struct Inner {
    clients: Mutex<HashMap<u64, UnboundedSender<String>>>,
    next_client: AtomicU64,
    states: RwLock<HashMap<TypeId, Arc<dyn Any + Send + Sync>>>,
}

#[derive(Clone)]
pub struct AppHandle(Arc<Inner>);

impl AppHandle {
    pub fn new() -> Self {
        Self(Arc::new(Inner {
            clients: Mutex::new(HashMap::new()),
            next_client: AtomicU64::new(1),
            states: RwLock::new(HashMap::new()),
        }))
    }

    // ── Events ────────────────────────────────────────────────────────────────

    pub fn emit<S: Serialize>(&self, event: &str, payload: S) -> Result<(), String> {
        self.broadcast(event, payload, None)
    }

    pub fn emit_to<S: Serialize>(&self, target: &str, event: &str, payload: S) -> Result<(), String> {
        self.broadcast(event, payload, Some(target))
    }

    fn broadcast<S: Serialize>(&self, event: &str, payload: S, target: Option<&str>) -> Result<(), String> {
        let payload = serde_json::to_value(payload).map_err(|e| e.to_string())?;
        self.send_line(event_line(event, payload, target));
        Ok(())
    }

    fn send_line(&self, line: String) {
        let clients = self.0.clients.lock().unwrap();
        for tx in clients.values() {
            let _ = tx.send(line.clone());
        }
    }

    // ── Clients ───────────────────────────────────────────────────────────────

    /// A new client: its id, and every line for it goes into `tx`.
    pub fn add_client(&self, tx: UnboundedSender<String>) -> u64 {
        let id = self.0.next_client.fetch_add(1, Ordering::Relaxed);
        self.0.clients.lock().unwrap().insert(id, tx);
        id
    }

    /// Returns how many clients are left.
    pub fn remove_client(&self, id: u64) -> usize {
        let mut clients = self.0.clients.lock().unwrap();
        clients.remove(&id);
        clients.len()
    }

    pub fn client_count(&self) -> usize {
        self.0.clients.lock().unwrap().len()
    }

    // ── Managed state (Tauri's `manage` / `state` / `try_state`) ──────────────

    pub fn manage<T: Send + Sync + 'static>(&self, value: T) {
        self.0.states.write().unwrap().insert(TypeId::of::<T>(), Arc::new(value));
    }

    pub fn try_state<T: Send + Sync + 'static>(&self) -> Option<Arc<T>> {
        let any = self.0.states.read().unwrap().get(&TypeId::of::<T>())?.clone();
        any.downcast::<T>().ok()
    }

    /// Panics when `T` was never managed, as Tauri does.
    pub fn state<T: Send + Sync + 'static>(&self) -> Arc<T> {
        self.try_state::<T>().unwrap_or_else(|| panic!("state not managed: {}", std::any::type_name::<T>()))
    }
}

pub fn event_line(event: &str, payload: Value, target: Option<&str>) -> String {
    json!({ "event": event, "payload": payload, "target": target }).to_string()
}

/// `tauri::async_runtime`, on the daemon's own Tokio runtime. Usable from any
/// thread, the runtime's or not, like Tauri's.
pub mod async_runtime {
    use std::future::Future;
    use std::sync::OnceLock;

    use tokio::runtime::Handle;
    use tokio::task::JoinHandle;

    static HANDLE: OnceLock<Handle> = OnceLock::new();

    pub fn set(handle: Handle) {
        let _ = HANDLE.set(handle);
    }

    fn handle() -> Handle {
        Handle::try_current().ok().or_else(|| HANDLE.get().cloned()).expect("no Tokio runtime")
    }

    pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        handle().spawn(future)
    }

    pub fn spawn_blocking<F, R>(f: F) -> JoinHandle<R>
    where
        F: FnOnce() -> R + Send + 'static,
        R: Send + 'static,
    {
        handle().spawn_blocking(f)
    }
}
