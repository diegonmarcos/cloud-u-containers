use axum::Router;
use std::sync::Arc;

use crate::AppState;

pub mod cloudflare;
pub mod containers;
pub mod flex;
pub mod health;
pub mod vm_control;
pub mod vm_status;
pub mod wake;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .merge(health::routes())
        .merge(vm_control::routes())
        .merge(vm_status::routes())
        .merge(wake::routes())
        .merge(containers::routes())
        .merge(flex::routes())
        .merge(cloudflare::routes())
}
