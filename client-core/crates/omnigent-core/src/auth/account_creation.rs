//! Creating an accounts-mode account.
//!
//! The first administrator uses `POST /auth/setup`, open only while the server has no password
//! account; an invited user uses `POST /auth/register` with the token from the admin's invite
//! link. Both answer like `POST /auth/login` (`{token, expires_in, user: {id}}`), decoded by
//! [`super::accounts::credential_from_login`].

use serde_json::json;
use url::Url;

use super::SecretString;
use super::endpoint::ServerEndpoint;
use super::errors::HostedAuthError;
use super::mode::{check_json_response, error_text};
use crate::http::{HttpHeader, HttpRequest, HttpResponse};

/// The account to create.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountCreation {
    /// The first administrator, on a server that reported `needs_setup`.
    FirstAdmin,
    /// An invited user, with the invite token.
    Invited {
        /// The token from the invite link (`/register?invite=<token>`).
        invite: String,
    },
}

/// `POST /auth/setup` or `POST /auth/register` with the JSON body the server expects.
///
/// # Errors
///
/// See [`ServerEndpoint::request_with`].
pub fn creation_request(
    endpoint: &ServerEndpoint,
    creation: &AccountCreation,
    username: &str,
    password: &SecretString,
) -> Result<HttpRequest, HostedAuthError> {
    let (path, body) = match creation {
        AccountCreation::FirstAdmin => (
            "/auth/setup",
            json!({"username": username, "password": password.expose()}),
        ),
        AccountCreation::Invited { invite } => (
            "/auth/register",
            json!({"invite": invite, "username": username, "password": password.expose()}),
        ),
    };
    let mut request = endpoint.request_with("POST", path, &[], "application/json", None)?;
    request
        .headers
        .push(HttpHeader::new("Content-Type", "application/json"));
    request.body = Some(body.to_string().into_bytes());
    Ok(request)
}

/// Checks a creation response. The server refuses with `400` (an invalid username or invite) or
/// `409` (the name is taken, or setup already happened) and an `error` text the user should see.
///
/// # Errors
///
/// [`HostedAuthError::AccountRefused`] for `400` and `409`, otherwise those of
/// [`check_json_response`].
pub fn check_creation_response(response: &HttpResponse) -> Result<(), HostedAuthError> {
    if matches!(response.status, 400 | 409) {
        return Err(HostedAuthError::AccountRefused {
            status: response.status,
            reason: error_text(&response.body),
        });
    }
    check_json_response(response, false)
}

/// The invite token in what the user pasted: an invite link (`…/register?invite=<token>`) or the
/// bare token. `None` when it is neither.
#[must_use]
pub fn invite_token(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if is_token(trimmed) {
        return Some(trimmed.to_owned());
    }
    let url = Url::parse(trimmed).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    url.query_pairs()
        .find(|(name, _)| name == "invite")
        .map(|(_, value)| value.into_owned())
        .filter(|token| is_token(token))
}

/// The server mints `secrets.token_urlsafe(32)` and accepts up to 128 characters.
fn is_token(text: &str) -> bool {
    (1..=128).contains(&text.len())
        && text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::*;
    use crate::auth::accounts::credential_from_login;
    use crate::auth::testing::{body_text, header};

    const MOUNT: &str = "/omnigent";
    const TOKEN: &str = "fixture-token-not-a-real-credential";

    fn endpoint() -> ServerEndpoint {
        ServerEndpoint::new(&format!("https://h.example.com{MOUNT}")).unwrap()
    }

    fn response(status: u16, body: &str) -> HttpResponse {
        HttpResponse {
            status,
            headers: vec![HttpHeader::new("Content-Type", "application/json")],
            body: body.as_bytes().to_vec(),
        }
    }

    #[test]
    fn first_admin_posts_setup_without_ambient_credentials() {
        let password = SecretString::new("synthetic-password");
        let request = creation_request(
            &endpoint(),
            &AccountCreation::FirstAdmin,
            "admin",
            &password,
        )
        .unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(
            request.url,
            format!("https://h.example.com{MOUNT}/auth/setup")
        );
        assert_eq!(header(&request, "Content-Type"), Some("application/json"));
        assert_eq!(header(&request, "Authorization"), None);
        let body: Value = serde_json::from_str(&body_text(&request)).unwrap();
        assert_eq!(
            body,
            json!({"username": "admin", "password": "synthetic-password"})
        );
    }

    #[test]
    fn invited_user_posts_register_with_the_invite() {
        let creation = AccountCreation::Invited {
            invite: "abc_DEF-1".into(),
        };
        let request =
            creation_request(&endpoint(), &creation, "bob", &SecretString::new("pw")).unwrap();
        assert_eq!(
            request.url,
            format!("https://h.example.com{MOUNT}/auth/register")
        );
        let body: Value = serde_json::from_str(&body_text(&request)).unwrap();
        assert_eq!(
            body,
            json!({"invite": "abc_DEF-1", "username": "bob", "password": "pw"})
        );
    }

    #[test]
    fn refusals_keep_the_server_reason() {
        for (status, reason) in [
            (409, "username already taken"),
            (409, "setup already completed"),
            (400, "invite invalid or expired"),
        ] {
            let body = format!(r#"{{"error":"{reason}"}}"#);
            assert_eq!(
                check_creation_response(&response(status, &body)),
                Err(HostedAuthError::AccountRefused {
                    status,
                    reason: Some(reason.into())
                })
            );
        }
        assert_eq!(
            check_creation_response(&response(500, "{}")),
            Err(HostedAuthError::HttpStatus { status: 500 })
        );
    }

    #[test]
    fn success_decodes_like_a_login() {
        let body = format!(r#"{{"token":"{TOKEN}","expires_in":60,"user":{{"id":"admin"}}}}"#);
        let ok = response(200, &body);
        check_creation_response(&ok).unwrap();
        let credential = credential_from_login(&ok.body, 1_000).unwrap();
        assert_eq!(credential.user_id, "admin");
        assert_eq!(credential.expires_at_ms, 61_000);
    }

    #[test]
    fn invite_tokens_come_from_links_or_bare_tokens() {
        let token = "Zm9v_YmFy-0123456789abcdefghijklmnopqrstuvw";
        assert_eq!(invite_token(token).as_deref(), Some(token));
        assert_eq!(
            invite_token(&format!("  {token}\n")).as_deref(),
            Some(token)
        );
        assert_eq!(
            invite_token(&format!(
                "https://h.example.com/omnigent/register?invite={token}"
            ))
            .as_deref(),
            Some(token)
        );
        assert_eq!(
            invite_token(&format!(
                "http://127.0.0.1:6767/register?x=1&invite={token}"
            ))
            .as_deref(),
            Some(token)
        );
        for rejected in [
            "",
            "   ",
            "https://h.example.com/register",
            "https://h.example.com/register?invite=",
            "https://h.example.com/register?invite=a%20b",
            "javascript:alert(1)?invite=abc",
            "not a token",
            &"a".repeat(129),
        ] {
            assert_eq!(invite_token(rejected), None, "{rejected:?}");
        }
    }
}
