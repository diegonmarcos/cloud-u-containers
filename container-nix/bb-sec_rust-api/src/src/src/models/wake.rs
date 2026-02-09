use serde::Serialize;
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Debug, Clone, Serialize)]
pub struct WakeInfo {
    pub status: String,
    pub message: String,
    pub last_trigger: Option<f64>,
}

#[derive(Debug, Clone)]
pub struct WakeState {
    pub inner: Arc<Mutex<WakeInfo>>,
}

impl Default for WakeState {
    fn default() -> Self {
        Self {
            inner: Arc::new(Mutex::new(WakeInfo {
                status: "unknown".into(),
                message: String::new(),
                last_trigger: None,
            })),
        }
    }
}
