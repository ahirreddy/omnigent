//! Creating accounts-mode accounts: the first administrator of a new server and invited users.

use omnigent_core::auth::account_creation::{self, AccountCreation};
use omnigent_core::auth::mode::AuthenticationMode as CoreMode;

use crate::client::{ClientCore, PasswordFlow};
use crate::engine::lock;
use crate::errors::CoreError;
use crate::events::ConnectedServer;

/// The invite token in a pasted invite link (`…/register?invite=<token>`) or bare token; `None`
/// when the text is neither.
#[uniffi::export]
pub fn invite_token_from_link(text: String) -> Option<String> {
    account_creation::invite_token(&text)
}

#[uniffi::export]
impl ClientCore {
    /// Whether the server being signed in to uses accounts and has no administrator yet, so the
    /// first person to sign in creates one with [`Self::create_first_admin`].
    pub fn needs_account_setup(&self) -> bool {
        lock(&self.inner.auth)
            .resolved
            .as_ref()
            .is_some_and(|resolved| resolved.mode == CoreMode::Accounts && resolved.needs_setup)
    }

    /// Creates the server's first administrator (`POST /auth/setup`), saves the credential and
    /// connects.
    ///
    /// # Errors
    ///
    /// [`CoreError::Auth`] with kind `AccountRefused` when the server refuses (setup already
    /// happened, or an invalid name), then the sign-in and connect failures.
    pub async fn create_first_admin(
        &self,
        username: String,
        password: String,
    ) -> Result<ConnectedServer, CoreError> {
        self.password_flow(
            PasswordFlow::Create(AccountCreation::FirstAdmin),
            username,
            password,
        )
        .await
    }

    /// Creates an invited account (`POST /auth/register`), saves the credential and connects.
    ///
    /// # Errors
    ///
    /// [`CoreError::Auth`] with kind `AccountRefused` for an invalid or used invite or a taken
    /// name, then the sign-in and connect failures.
    pub async fn register_account(
        &self,
        invite: String,
        username: String,
        password: String,
    ) -> Result<ConnectedServer, CoreError> {
        self.password_flow(
            PasswordFlow::Create(AccountCreation::Invited { invite }),
            username,
            password,
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use crate::connection::UrlPolicy;
    use crate::engine::lock;
    use crate::errors::{AuthErrorKind, CoreError};
    use crate::events::ConnectionPhase;
    use crate::test_support::{Harness, json};

    /// An accounts server with no administrator yet, after `connect` asked for a sign-in.
    fn unclaimed_server() -> Harness {
        let mut harness = Harness::new(UrlPolicy::Development);
        harness.http.route(
            "/.well-known/omnigent.json",
            json(200, r#"{"manifest_version":1,"auth":{"mode":"accounts"}}"#),
        );
        harness.http.route(
            "/v1/info",
            json(
                200,
                r#"{"single_user":false,"accounts_enabled":true,"needs_setup":true}"#,
            ),
        );
        let core = Arc::clone(&harness.core);
        let phase = harness
            .run(async move {
                core.connect("https://omnigent.example.com".into(), None)
                    .await
            })
            .unwrap();
        assert!(
            matches!(phase, ConnectionPhase::SignInRequired { .. }),
            "{phase:?}"
        );
        harness
    }

    #[test]
    fn first_admin_is_created_and_connected() {
        let mut harness = unclaimed_server();
        assert!(harness.core.needs_account_setup());
        harness.http.route(
            "/auth/setup",
            json(
                200,
                r#"{"token":"tok-admin","expires_in":3600,"user":{"id":"admin"}}"#,
            ),
        );
        harness
            .http
            .route("/v1/me", json(200, r#"{"user_id":"admin"}"#));
        harness.http.route(
            "/v1/sessions",
            json(200, r#"{"object":"list","data":[],"has_more":false}"#),
        );
        let core = Arc::clone(&harness.core);
        let server = harness
            .run(async move { core.create_first_admin("admin".into(), "pw".into()).await })
            .unwrap();
        assert_eq!(server.user_id, "admin");
        assert!(
            lock(&harness.http.requests)
                .iter()
                .any(|request| request.url.ends_with("/auth/setup") && request.method == "POST")
        );
    }

    #[test]
    fn a_refused_registration_keeps_the_server_reason() {
        let mut harness = unclaimed_server();
        harness.http.route(
            "/auth/register",
            json(400, r#"{"error":"invite invalid or expired"}"#),
        );
        let core = Arc::clone(&harness.core);
        let error = harness
            .run(async move {
                core.register_account("tok".into(), "bob".into(), "pw".into())
                    .await
            })
            .unwrap_err();
        let CoreError::Auth { kind, detail, .. } = error else {
            panic!("{error:?}");
        };
        assert_eq!(kind, AuthErrorKind::AccountRefused);
        assert_eq!(detail.as_deref(), Some("invite invalid or expired"));
    }

    #[test]
    fn invite_links_yield_their_token() {
        assert_eq!(
            super::invite_token_from_link("https://h.example.com/register?invite=abc".into())
                .as_deref(),
            Some("abc")
        );
        assert_eq!(super::invite_token_from_link("no good".into()), None);
    }
}
