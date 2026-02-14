use axum::Router;
use std::sync::Arc;

use crate::AppState;

pub mod health;
pub mod ondemand;
pub mod profiling;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .merge(ondemand::routes())
        .merge(profiling::routes())
}
