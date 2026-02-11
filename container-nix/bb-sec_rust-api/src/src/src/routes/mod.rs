use axum::Router;
use std::sync::Arc;

use crate::AppState;

pub mod health;
pub mod ondemand;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .merge(ondemand::routes())
}
