//! Browser actions run through `node /opt/vibe/browser.js` inside the container (spec §3.6):
//! the gateway never speaks CDP itself, it only execs the script and parses its one JSON line.
use bollard::container::LogOutput;
use bollard::exec::{CreateExecOptions, StartExecOptions, StartExecResults};
use futures_util::StreamExt;
use serde_json::Value;

use crate::error::{from_docker_error, GatewayError};
use crate::models::{
    BrowserActionRequest, BrowserActionResponse, BrowserNavigateResponse, ScreenshotResponse,
};
use crate::state::AppState;

use super::now_unix;

const BROWSER_SCRIPT: &str = "/opt/vibe/browser.js";
const DEFAULT_BROWSER_TIMEOUT_MS: u64 = 90_000;

/// A cold Chromium start on a 1-CPU sandbox can take 30-60 s; SANDBOX_BROWSER_TIMEOUT_MS overrides.
fn browser_timeout_ms() -> u64 {
    std::env::var("SANDBOX_BROWSER_TIMEOUT_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_BROWSER_TIMEOUT_MS)
}

fn parse_first_json_line(stdout: &[u8]) -> Option<Value> {
    let text = String::from_utf8_lossy(stdout);
    text.lines().find_map(|line| {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            None
        } else {
            serde_json::from_str::<Value>(trimmed).ok()
        }
    })
}

async fn run_browser_script(
    state: &AppState,
    container_id: &str,
    request: Value,
) -> Result<Value, GatewayError> {
    let payload =
        serde_json::to_string(&request).map_err(|e| GatewayError::Internal(anyhow::anyhow!(e)))?;
    let cmd = vec!["node".to_string(), BROWSER_SCRIPT.to_string(), payload];

    let create = state
        .docker
        .create_exec(
            container_id,
            CreateExecOptions {
                cmd: Some(cmd),
                attach_stdout: Some(true),
                attach_stderr: Some(true),
                ..Default::default()
            },
        )
        .await
        .map_err(from_docker_error)?;

    let started = state
        .docker
        .start_exec(&create.id, None::<StartExecOptions>)
        .await
        .map_err(from_docker_error)?;
    let StartExecResults::Attached { mut output, .. } = started else {
        return Err(GatewayError::Internal(anyhow::anyhow!(
            "browser exec started detached unexpectedly"
        )));
    };

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let drain = async {
        while let Some(chunk) = output.next().await {
            match chunk {
                Ok(LogOutput::StdOut { message }) => stdout.extend_from_slice(&message),
                Ok(LogOutput::StdErr { message }) => stderr.extend_from_slice(&message),
                Ok(_) => {}
                Err(e) => return Err(from_docker_error(e)),
            }
        }
        Ok::<(), GatewayError>(())
    };

    tokio::time::timeout(std::time::Duration::from_millis(browser_timeout_ms()), drain)
        .await
        .map_err(|_| GatewayError::Internal(anyhow::anyhow!("browser script timed out")))??;

    state.touch(container_id, now_unix());

    parse_first_json_line(&stdout).ok_or_else(|| {
        tracing::warn!(stderr = %String::from_utf8_lossy(&stderr), "browser.js produced no parseable JSON line");
        GatewayError::Internal(anyhow::anyhow!("browser.js produced no parseable JSON line"))
    })
}

pub async fn navigate(
    state: &AppState,
    container_id: &str,
    url: &str,
) -> Result<BrowserNavigateResponse, GatewayError> {
    let req = serde_json::json!({"kind": "navigate", "url": url});
    let v = run_browser_script(state, container_id, req).await?;
    Ok(BrowserNavigateResponse {
        url: v
            .get("url")
            .and_then(|s| s.as_str())
            .unwrap_or(url)
            .to_string(),
        title: v
            .get("title")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string(),
    })
}

pub async fn action(
    state: &AppState,
    container_id: &str,
    req: BrowserActionRequest,
) -> Result<BrowserActionResponse, GatewayError> {
    let mut action = serde_json::Map::new();
    action.insert("kind".to_string(), Value::String(req.kind));
    if let Some(v) = req.selector {
        action.insert("selector".to_string(), Value::String(v));
    }
    if let Some(v) = req.x {
        action.insert("x".to_string(), serde_json::json!(v));
    }
    if let Some(v) = req.y {
        action.insert("y".to_string(), serde_json::json!(v));
    }
    if let Some(v) = req.text {
        action.insert("text".to_string(), Value::String(v));
    }

    let request = serde_json::json!({"kind": "action", "action": Value::Object(action)});
    let v = run_browser_script(state, container_id, request).await?;
    Ok(BrowserActionResponse {
        ok: v.get("ok").and_then(|b| b.as_bool()).unwrap_or(false),
        url: v
            .get("url")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string(),
        title: v
            .get("title")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string(),
    })
}

pub async fn screenshot(
    state: &AppState,
    container_id: &str,
    max_width: u32,
) -> Result<ScreenshotResponse, GatewayError> {
    let req = serde_json::json!({"kind": "screenshot", "maxWidth": max_width});
    let v = run_browser_script(state, container_id, req).await?;
    Ok(ScreenshotResponse {
        image_base64: v
            .get("imageBase64")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string(),
        mime: v
            .get("mime")
            .and_then(|s| s.as_str())
            .unwrap_or("image/jpeg")
            .to_string(),
        width: v.get("width").and_then(|n| n.as_u64()).unwrap_or(0) as u32,
        height: v.get("height").and_then(|n| n.as_u64()).unwrap_or(0) as u32,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_single_json_line() {
        let v = parse_first_json_line(b"{\"ok\":true}\n").unwrap();
        assert_eq!(v["ok"], true);
    }

    #[test]
    fn skips_leading_blank_lines() {
        let v = parse_first_json_line(b"\n\n{\"url\":\"https://a.example\"}\n").unwrap();
        assert_eq!(v["url"], "https://a.example");
    }

    #[test]
    fn returns_none_for_no_json() {
        assert!(parse_first_json_line(b"not json at all").is_none());
    }

    #[test]
    fn returns_none_for_empty_output() {
        assert!(parse_first_json_line(b"").is_none());
    }
}
