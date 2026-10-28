//! Errors returned to Swift.

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum JellyfinError {
    #[error("network error: {0}")]
    Network(String),
    #[error("server unreachable: {0}")]
    ServerUnreachable(String),
    #[error("you must sign in first")]
    NotLoggedIn,
    #[error("incorrect credentials or expired session")]
    Unauthorized,
    #[error("access denied: {0}")]
    Forbidden(String),
    #[error("server error ({code}): {message}")]
    ServerError { code: u16, message: String },
    #[error("resource not found: {0}")]
    NotFound(String),
    #[error("unsupported server version ({0}, minimum required: 10.9)")]
    UnsupportedServerVersion(String),
    #[error("data decoding error: {0}")]
    Decode(String),
    #[error("cache error: {0}")]
    Cache(String),
    #[error("invalid parameter: {0}")]
    InvalidInput(String),
    #[error("the server identifier does not match the expected server: {0}")]
    ServerMismatch(String),
    #[error("storage error: {0}")]
    Storage(String),
}

impl From<reqwest::Error> for JellyfinError {
    fn from(err: reqwest::Error) -> Self {
        if err.is_timeout() || err.is_connect() {
            Self::ServerUnreachable(err.to_string())
        } else if let Some(status) = err.status() {
            if status == reqwest::StatusCode::NOT_FOUND {
                Self::NotFound(err.to_string())
            } else if status == reqwest::StatusCode::FORBIDDEN {
                Self::Forbidden(err.to_string())
            } else if status == reqwest::StatusCode::UNAUTHORIZED {
                Self::Unauthorized
            } else if status.is_server_error() {
                Self::ServerError {
                    code: status.as_u16(),
                    message: err.to_string(),
                }
            } else {
                Self::Network(err.to_string())
            }
        } else {
            Self::Network(err.to_string())
        }
    }
}
