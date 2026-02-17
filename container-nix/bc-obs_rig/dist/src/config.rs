use std::env;

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub port: u16,
    pub surreal_url: String,
    pub surreal_pass: String,
    pub heal_interval_secs: u64,
    pub docker_socket: String,
}

impl AppConfig {
    pub fn from_env() -> Self {
        Self {
            port: env::var("RIG_PORT")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(8090),
            surreal_url: env::var("SURREAL_URL")
                .unwrap_or_else(|_| "http://host.docker.internal:8001".into()),
            surreal_pass: env::var("SURREAL_ROOT_PASSWORD")
                .unwrap_or_else(|_| "root".into()),
            heal_interval_secs: env::var("HEAL_INTERVAL_SECS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(300), // 5 minutes
            docker_socket: env::var("DOCKER_HOST")
                .unwrap_or_else(|_| "unix:///var/run/docker.sock".into()),
        }
    }
}
