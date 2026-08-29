//! Env-sourced config. All names are frozen by docs/agent-platform-v1.md §4 / task-gateway.md.
use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    pub port: u16,
    pub gateway_token: String,
    pub container_socket: String,
    pub sandbox_image: String,
    pub sandbox_image_allowlist: Vec<String>,
    pub sandbox_network: String,
    pub sandbox_egress_proxy: Option<String>,
    pub max_containers: usize,
    pub default_memory_mb: i64,
    pub default_cpus: f64,
    pub pids_limit: i64,
    pub idle_ttl_seconds: u64,
    pub volume_prefix: String,
    pub exec_max_timeout_ms: u64,
    pub max_output_bytes: usize,
    pub max_file_bytes: usize,
    pub log_format: String,
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("SANDBOX_GATEWAY_TOKEN is required and must be at least 32 characters")]
    TokenTooShort,
    #[error("invalid value for {0}: {1}")]
    InvalidValue(String, String),
}

fn env_string(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_parsed<T: std::str::FromStr>(key: &str, default: T) -> Result<T, ConfigError> {
    match env::var(key) {
        Err(_) => Ok(default),
        Ok(raw) => raw
            .parse::<T>()
            .map_err(|_| ConfigError::InvalidValue(key.to_string(), raw)),
    }
}

/// Fails closed: a missing/short token must never silently start the gateway.
pub fn validate_token(token: &str) -> Result<(), ConfigError> {
    if token.len() < 32 {
        return Err(ConfigError::TokenTooShort);
    }
    Ok(())
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let gateway_token = env::var("SANDBOX_GATEWAY_TOKEN").unwrap_or_default();
        validate_token(&gateway_token)?;

        let sandbox_image = env_string("SANDBOX_IMAGE", "vibe-sandbox:latest");
        let sandbox_image_allowlist = env::var("SANDBOX_IMAGE_ALLOWLIST")
            .ok()
            .map(|raw| {
                raw.split(',')
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
            })
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| vec![sandbox_image.clone()]);

        Ok(Self {
            port: env_parsed("PORT", 8090u16)?,
            gateway_token,
            container_socket: env_string("CONTAINER_SOCKET", "unix:///run/podman/podman.sock"),
            sandbox_image,
            sandbox_image_allowlist,
            sandbox_network: env_string("SANDBOX_NETWORK", "sandbox-net"),
            sandbox_egress_proxy: env::var("SANDBOX_EGRESS_PROXY").ok(),
            max_containers: env_parsed("SANDBOX_MAX_CONTAINERS", 32usize)?,
            default_memory_mb: env_parsed("SANDBOX_DEFAULT_MEMORY_MB", 1024i64)?,
            default_cpus: env_parsed("SANDBOX_DEFAULT_CPUS", 1.0f64)?,
            pids_limit: env_parsed("SANDBOX_PIDS_LIMIT", 256i64)?,
            idle_ttl_seconds: env_parsed("SANDBOX_IDLE_TTL_SECONDS", 1800u64)?,
            volume_prefix: env_string("SANDBOX_VOLUME_PREFIX", "vibe-sandbox-"),
            exec_max_timeout_ms: env_parsed("SANDBOX_EXEC_MAX_TIMEOUT_MS", 240_000u64)?,
            max_output_bytes: env_parsed("SANDBOX_MAX_OUTPUT_BYTES", 1_000_000usize)?,
            max_file_bytes: env_parsed("SANDBOX_MAX_FILE_BYTES", 4_000_000usize)?,
            log_format: env_string("LOG_FORMAT", "text"),
        })
    }
}

#[cfg(test)]
/// Struct-literal config for tests: avoids mutating process env (parallel-test-safe).
pub fn test_config() -> Config {
    Config {
        port: 8090,
        gateway_token: "a".repeat(32),
        container_socket: "unix:///run/podman/podman.sock".into(),
        sandbox_image: "vibe-sandbox:latest".into(),
        sandbox_image_allowlist: vec!["vibe-sandbox:latest".into()],
        sandbox_network: "sandbox-net".into(),
        sandbox_egress_proxy: Some("http://egress-proxy:3128".into()),
        max_containers: 32,
        default_memory_mb: 1024,
        default_cpus: 1.0,
        pids_limit: 256,
        idle_ttl_seconds: 1800,
        volume_prefix: "vibe-sandbox-".into(),
        exec_max_timeout_ms: 240_000,
        max_output_bytes: 1_000_000,
        max_file_bytes: 4_000_000,
        log_format: "text".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_token_rejects_short() {
        assert!(validate_token("short").is_err());
        assert!(validate_token(&"a".repeat(31)).is_err());
    }

    #[test]
    fn validate_token_accepts_32_or_more() {
        assert!(validate_token(&"a".repeat(32)).is_ok());
        assert!(validate_token(&"a".repeat(64)).is_ok());
    }
}
