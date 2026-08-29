//! Shared gateway state: docker client, config, and the in-memory sandbox tracking map.
use std::collections::HashMap;
use std::sync::Mutex;

use bollard::Docker;

use crate::config::Config;

#[derive(Debug, Clone)]
pub struct SandboxEntry {
    pub owner_key: String,
    pub created_at: i64,
    pub last_used_at: i64,
    pub ttl_seconds: Option<u64>,
}

pub struct AppState {
    pub cfg: Config,
    pub docker: Docker,
    pub sandboxes: Mutex<HashMap<String, SandboxEntry>>,
}

impl AppState {
    pub fn new(cfg: Config, docker: Docker) -> Self {
        Self {
            cfg,
            docker,
            sandboxes: Mutex::new(HashMap::new()),
        }
    }

    pub fn touch(&self, id: &str, now: i64) {
        if let Some(entry) = self.sandboxes.lock().unwrap().get_mut(id) {
            entry.last_used_at = now;
        }
    }

    pub fn upsert(&self, id: &str, entry: SandboxEntry) {
        self.sandboxes.lock().unwrap().insert(id.to_string(), entry);
    }

    pub fn remove(&self, id: &str) {
        self.sandboxes.lock().unwrap().remove(id);
    }

    pub fn get(&self, id: &str) -> Option<SandboxEntry> {
        self.sandboxes.lock().unwrap().get(id).cloned()
    }

    pub fn len(&self) -> usize {
        self.sandboxes.lock().unwrap().len()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.sandboxes.lock().unwrap().contains_key(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry() -> SandboxEntry {
        SandboxEntry {
            owner_key: "agent:1".into(),
            created_at: 1,
            last_used_at: 1,
            ttl_seconds: None,
        }
    }

    #[test]
    fn upsert_get_remove_roundtrip() {
        let cfg = crate::config::test_config();
        // HTTP transport builds synchronously (no socket probe), so this needs no live daemon.
        let docker = Docker::connect_with_http_defaults().unwrap();
        let state = AppState::new(cfg, docker);
        assert_eq!(state.len(), 0);
        state.upsert("vibe-sb-abc", entry());
        assert_eq!(state.len(), 1);
        assert!(state.contains("vibe-sb-abc"));
        state.touch("vibe-sb-abc", 42);
        assert_eq!(state.get("vibe-sb-abc").unwrap().last_used_at, 42);
        state.remove("vibe-sb-abc");
        assert!(state.get("vibe-sb-abc").is_none());
    }
}
