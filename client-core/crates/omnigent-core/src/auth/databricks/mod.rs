//! Databricks workspace OAuth, token management, and org routing.
//!
//! Port of the web/ios Databricks sign-in (`web/ios/Omnigent/Databricks*.swift`, documented in
//! `web/ios/docs/databricks-oauth.md`) and the `NativeLab` org-routing tests. Everything here is sans-IO:
//! requests are [`crate::http::HttpRequest`]s for the host transport, secure storage goes through
//! the shared [`crate::auth::SecureStore`] key/record contract, randomness comes from
//! [`crate::auth::EntropySource`], and time arrives as `now_ms`.
//!
//! The host keeps the OS pieces: presenting the sign-in browser (`ASWebAuthenticationSession`),
//! Keychain item attributes, `WebKit` cookie stores, and persisting the sign-out marker list.
pub mod attempt;
pub mod bootstrap;
pub mod client;
pub mod config;
pub mod error;
pub mod issuer;
pub mod login;
mod query;
pub mod scope;
#[cfg(test)]
mod test_support;
pub mod token_manager;
pub mod tokens;
pub mod web_context;

pub use attempt::{AuthorizationResponse, OAUTH_SCOPE, OAuthAttempt};
pub use client::OAuthClient;
pub use config::OAuthConfiguration;
pub use error::{DatabricksError, WorkspaceFailure, workspace_error_message};
pub use issuer::OAuthIssuer;
pub use login::LoginManager;
pub use scope::CredentialScope;
pub use token_manager::TokenManager;
pub use tokens::DatabricksTokens;
pub use web_context::{WebContext, WorkspaceSession};
