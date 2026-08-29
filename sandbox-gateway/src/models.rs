//! Request/response DTOs for the sandbox-gateway API (spec docs/agent-platform-v1.md §3.6).
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NetworkMode {
    None,
    Proxy,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateSandboxRequest {
    #[serde(rename = "ownerKey")]
    pub owner_key: String,
    pub image: Option<String>,
    pub cpus: Option<f64>,
    #[serde(rename = "memoryMb")]
    pub memory_mb: Option<i64>,
    #[serde(rename = "pidsLimit")]
    pub pids_limit: Option<i64>,
    pub network: NetworkMode,
    #[serde(rename = "ttlSeconds")]
    pub ttl_seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SandboxCreatedResponse {
    pub id: String,
    pub status: String,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct SandboxDetailResponse {
    pub id: String,
    pub status: String,
    #[serde(rename = "ownerKey")]
    pub owner_key: String,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
    #[serde(rename = "lastUsedAt")]
    pub last_used_at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct SandboxListResponse {
    pub sandboxes: Vec<SandboxDetailResponse>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SandboxActionResponse {
    pub id: String,
    pub status: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ExecRequest {
    pub cmd: Vec<String>,
    pub cwd: Option<String>,
    pub env: Option<HashMap<String, String>>,
    #[serde(rename = "timeoutMs")]
    pub timeout_ms: Option<u64>,
    #[serde(rename = "maxOutputBytes")]
    pub max_output_bytes: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ExecResponse {
    #[serde(rename = "exitCode")]
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
    #[serde(rename = "durationMs")]
    pub duration_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WriteFileRequest {
    pub path: String,
    #[serde(rename = "contentBase64")]
    pub content_base64: String,
    pub mode: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WriteFileResponse {
    pub path: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReadFileResponse {
    pub path: String,
    #[serde(rename = "contentBase64")]
    pub content_base64: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FileQuery {
    pub path: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TreeQuery {
    pub path: Option<String>,
    pub depth: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TreeEntry {
    pub path: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct TreeResponse {
    pub entries: Vec<TreeEntry>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BrowserNavigateRequest {
    pub url: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct BrowserNavigateResponse {
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BrowserActionRequest {
    pub kind: String,
    pub selector: Option<String>,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub text: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BrowserActionResponse {
    pub ok: bool,
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ScreenshotQuery {
    #[serde(rename = "maxWidth")]
    pub max_width: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScreenshotResponse {
    #[serde(rename = "imageBase64")]
    pub image_base64: String,
    pub mime: String,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Serialize)]
pub struct HealthzResponse {
    pub ok: bool,
    pub containers: usize,
    pub image: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

impl ErrorResponse {
    pub fn new(msg: impl Into<String>) -> Self {
        Self { error: msg.into() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_sandbox_request_parses_frozen_field_names() {
        let json = r#"{"ownerKey":"agent:1","image":"vibe-sandbox:latest","cpus":1.5,
            "memoryMb":2048,"pidsLimit":128,"network":"proxy","ttlSeconds":600}"#;
        let req: CreateSandboxRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.owner_key, "agent:1");
        assert_eq!(req.network, NetworkMode::Proxy);
        assert_eq!(req.ttl_seconds, Some(600));
    }

    #[test]
    fn create_sandbox_request_allows_omitted_optionals() {
        let json = r#"{"ownerKey":"agent:1","network":"none"}"#;
        let req: CreateSandboxRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.network, NetworkMode::None);
        assert!(req.image.is_none());
        assert!(req.cpus.is_none());
    }

    #[test]
    fn network_mode_serializes_lowercase() {
        assert_eq!(
            serde_json::to_string(&NetworkMode::None).unwrap(),
            "\"none\""
        );
        assert_eq!(
            serde_json::to_string(&NetworkMode::Proxy).unwrap(),
            "\"proxy\""
        );
    }

    #[test]
    fn sandbox_created_response_uses_camel_case() {
        let resp = SandboxCreatedResponse {
            id: "vibe-sb-abc".into(),
            status: "running".into(),
            created_at: 100,
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["createdAt"], 100);
        assert!(v.get("created_at").is_none());
    }

    #[test]
    fn sandbox_detail_response_field_names() {
        let resp = SandboxDetailResponse {
            id: "vibe-sb-abc".into(),
            status: "running".into(),
            owner_key: "agent:1".into(),
            created_at: 100,
            last_used_at: 200,
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["ownerKey"], "agent:1");
        assert_eq!(v["createdAt"], 100);
        assert_eq!(v["lastUsedAt"], 200);
    }

    #[test]
    fn exec_request_parses() {
        let json = r#"{"cmd":["ls","-la"],"cwd":"/home/agent","env":{"A":"B"},
            "timeoutMs":5000,"maxOutputBytes":1000}"#;
        let req: ExecRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.cmd, vec!["ls", "-la"]);
        assert_eq!(req.timeout_ms, Some(5000));
    }

    #[test]
    fn exec_response_omits_error_when_none() {
        let resp = ExecResponse {
            exit_code: 0,
            stdout: "hi".into(),
            stderr: "".into(),
            truncated: false,
            duration_ms: 10,
            error: None,
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["exitCode"], 0);
        assert!(v.get("error").is_none());
    }

    #[test]
    fn exec_response_includes_error_on_timeout() {
        let resp = ExecResponse {
            exit_code: 124,
            stdout: "".into(),
            stderr: "".into(),
            truncated: false,
            duration_ms: 240000,
            error: Some("timeout".into()),
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["error"], "timeout");
    }

    #[test]
    fn write_file_request_parses_frozen_names() {
        let json = r#"{"path":"/home/agent/x.txt","contentBase64":"aGk=","mode":420}"#;
        let req: WriteFileRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.path, "/home/agent/x.txt");
        assert_eq!(req.content_base64, "aGk=");
        assert_eq!(req.mode, Some(420));
    }

    #[test]
    fn tree_entry_serializes_type_field() {
        let entry = TreeEntry {
            path: "/home/agent".into(),
            kind: "dir".into(),
            bytes: 0,
        };
        let v: serde_json::Value = serde_json::to_value(&entry).unwrap();
        assert_eq!(v["type"], "dir");
        assert!(v.get("kind").is_none());
    }

    #[test]
    fn screenshot_query_parses_camel_case() {
        let q: ScreenshotQuery = serde_urlencoded::from_str("maxWidth=800").unwrap();
        assert_eq!(q.max_width, Some(800));
    }

    #[test]
    fn healthz_response_shape() {
        let resp = HealthzResponse {
            ok: true,
            containers: 3,
            image: "vibe-sandbox:latest".into(),
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["containers"], 3);
        assert_eq!(v["image"], "vibe-sandbox:latest");
    }

    #[test]
    fn error_response_shape() {
        let resp = ErrorResponse::new("unauthorized");
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["error"], "unauthorized");
    }
}
