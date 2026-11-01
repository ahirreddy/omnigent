//! PKCE (RFC 7636) and form-encoding helpers shared by every native OAuth flow.
//!
//! Port of `web/ios/Omnigent/OAuthSupport.swift`. Randomness comes from the host's
//! [`EntropySource`], so the core stays deterministic under test and builds for wasm32.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use sha2::{Digest as _, Sha256};

use super::{EntropyError, EntropySource, SecretString};

/// Bytes of entropy behind every verifier and state value: 32 bytes is a 43-character
/// base64url string, the RFC 7636 minimum length.
pub const RANDOM_VALUE_BYTES: usize = 32;

/// The only challenge method the server accepts.
pub const CODE_CHALLENGE_METHOD: &str = "S256";

/// A PKCE code verifier and its S256 challenge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PkcePair {
    /// The secret verifier; sent only on the token exchange or ticket poll.
    pub verifier: SecretString,
    /// `base64url(sha256(verifier))`; safe to put in a URL.
    pub challenge: String,
}

impl PkcePair {
    /// A fresh verifier from `entropy` and its S256 challenge.
    ///
    /// # Errors
    ///
    /// The host could not supply random bytes.
    pub fn generate(entropy: &dyn EntropySource) -> Result<Self, EntropyError> {
        let verifier = random_value(entropy)?;
        Ok(Self::from_verifier(SecretString::new(verifier)))
    }

    /// The pair for an existing verifier.
    #[must_use]
    pub fn from_verifier(verifier: SecretString) -> Self {
        let challenge = code_challenge_s256(verifier.expose());
        Self {
            verifier,
            challenge,
        }
    }
}

/// [`RANDOM_VALUE_BYTES`] random bytes as unpadded base64url: a verifier or an OAuth `state`.
///
/// # Errors
///
/// The host failed, or returned a different number of bytes than asked for.
pub fn random_value(entropy: &dyn EntropySource) -> Result<String, EntropyError> {
    let bytes = entropy.random_bytes(RANDOM_VALUE_BYTES)?;
    if bytes.len() != RANDOM_VALUE_BYTES {
        return Err(EntropyError::ShortRead {
            requested: RANDOM_VALUE_BYTES,
            received: bytes.len(),
        });
    }
    Ok(base64url(&bytes))
}

/// The S256 code challenge for `verifier`.
#[must_use]
pub fn code_challenge_s256(verifier: &str) -> String {
    base64url(&Sha256::digest(verifier.as_bytes()))
}

/// Unpadded base64url (RFC 4648 section 5).
#[must_use]
pub fn base64url(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// An `application/x-www-form-urlencoded` body that percent-escapes everything except the RFC 3986
/// unreserved characters (so a space is `%20`, never `+`).
#[must_use]
pub fn form_body(fields: &[(&str, &str)]) -> Vec<u8> {
    let mut body = String::new();
    for (index, (name, value)) in fields.iter().enumerate() {
        if index > 0 {
            body.push('&');
        }
        percent_encode_into(&mut body, name);
        body.push('=');
        percent_encode_into(&mut body, value);
    }
    body.into_bytes()
}

/// Percent-encodes `value` leaving only RFC 3986 unreserved characters bare.
#[must_use]
pub fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    percent_encode_into(&mut out, value);
    out
}

fn percent_encode_into(out: &mut String, value: &str) {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push('%');
            for nibble in [byte >> 4, byte & 0x0F] {
                if let Some(digit) = HEX.get(usize::from(nibble)) {
                    out.push(char::from(*digit));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::testing::FixedEntropy;

    #[test]
    fn rfc7636_appendix_b_challenge() {
        assert_eq!(
            code_challenge_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn random_value_is_43_base64url_characters() {
        let entropy = FixedEntropy::counting();
        let value = random_value(&entropy).unwrap();
        assert_eq!(value.len(), 43);
        assert!(
            value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        );
        let pair = PkcePair::generate(&entropy).unwrap();
        assert_eq!(pair.challenge, code_challenge_s256(pair.verifier.expose()));
        assert_ne!(pair.verifier.expose(), value, "each draw is fresh");
    }

    #[test]
    fn short_entropy_is_an_error() {
        let entropy = FixedEntropy::short(8);
        assert_eq!(
            random_value(&entropy),
            Err(EntropyError::ShortRead {
                requested: 32,
                received: 8
            })
        );
    }

    #[test]
    fn host_entropy_failure_propagates() {
        let entropy = FixedEntropy::failing();
        assert!(matches!(
            PkcePair::generate(&entropy),
            Err(EntropyError::Unavailable { .. })
        ));
    }

    #[test]
    fn form_body_escapes_all_but_unreserved() {
        let body = form_body(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", "a+b/c=d e&f~g"),
        ]);
        assert_eq!(
            String::from_utf8(body).unwrap(),
            "grant_type=refresh_token&refresh_token=a%2Bb%2Fc%3Dd%20e%26f~g"
        );
        assert_eq!(percent_encode("é"), "%C3%A9");
    }
}
