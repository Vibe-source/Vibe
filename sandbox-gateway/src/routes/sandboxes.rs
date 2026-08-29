//! Sandbox lifecycle routes: create/get/list/exec/stop/delete.
use std::sync::Arc;

use axum::extract::{Path, State};
use axum::response::Json;

use crate::error::GatewayError;
use crate::models::{
    CreateSandboxRequest, ExecRequest, ExecResponse, SandboxActionResponse, SandboxCreatedResponse,
    SandboxDetailResponse, SandboxListResponse,
};
use crate::runtime::{containers, exec};
use crate::state::AppState;

pub async fn create(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateSandboxRequest>,
) -> Result<Json<SandboxCreatedResponse>, GatewayError> {
    containers::ensure_sandbox(&state, req).await.map(Json)
}

pub async fn get(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<SandboxDetailResponse>, GatewayError> {
    containers::get_sandbox(&state, &id).await.map(Json)
}

pub async fn list(
    State(state): State<Arc<AppState>>,
) -> Result<Json<SandboxListResponse>, GatewayError> {
    containers::list_sandboxes(&state).await.map(Json)
}

pub async fn exec_cmd(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ExecRequest>,
) -> Result<Json<ExecResponse>, GatewayError> {
    exec::exec(&state, &id, req).await.map(Json)
}

pub async fn stop(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<SandboxActionResponse>, GatewayError> {
    containers::stop_sandbox(&state, &id).await.map(Json)
}

pub async fn delete(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<SandboxActionResponse>, GatewayError> {
    containers::delete_sandbox(&state, &id).await.map(Json)
}
