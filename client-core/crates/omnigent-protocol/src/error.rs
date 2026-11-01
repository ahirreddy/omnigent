//! Decode errors shared by every wire model in this crate.

use std::fmt;

use serde_json::Value;

/// Why a wire payload could not be decoded.
///
/// Unknown discriminators are not errors (they decode to an `Unknown` variant); this is only for
/// payloads that are not JSON, have the wrong shape, or break a field contract of a known type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// The bytes are not valid JSON.
    Syntax {
        /// The parser's message.
        message: String,
    },
    /// A value that must be a JSON object is something else.
    NotAnObject {
        /// What was being decoded, for example `item` or `event`.
        context: String,
    },
    /// A required field is missing, empty, blank or not a string.
    MissingField {
        /// What was being decoded, for example ``item `error` ``.
        context: String,
        /// The field name.
        field: String,
    },
    /// A known shape failed to decode.
    Invalid {
        /// What was being decoded, for example ``event `session.status` ``.
        context: String,
        /// The decoder's message.
        message: String,
    },
}

impl DecodeError {
    pub(crate) fn missing(context: impl Into<String>, field: &str) -> Self {
        Self::MissingField {
            context: context.into(),
            field: field.to_owned(),
        }
    }

    pub(crate) fn invalid(context: impl Into<String>, error: &impl fmt::Display) -> Self {
        Self::Invalid {
            context: context.into(),
            message: error.to_string(),
        }
    }
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Syntax { message } => write!(f, "not valid JSON: {message}"),
            Self::NotAnObject { context } => write!(f, "{context} is not a JSON object"),
            Self::MissingField { context, field } => {
                write!(f, "{context} has no usable `{field}`")
            }
            Self::Invalid { context, message } => write!(f, "invalid {context}: {message}"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// A wire model decoded from a JSON value, with typed errors.
pub trait FromWire: Sized {
    /// Decodes an already-parsed JSON value.
    ///
    /// # Errors
    ///
    /// The value does not have this model's shape.
    fn from_value(value: Value) -> Result<Self, DecodeError>;

    /// Decodes a JSON body.
    ///
    /// # Errors
    ///
    /// The bytes are not JSON, or do not have this model's shape.
    fn from_json(bytes: &[u8]) -> Result<Self, DecodeError> {
        let value = serde_json::from_slice(bytes).map_err(|error| DecodeError::Syntax {
            message: error.to_string(),
        })?;
        Self::from_value(value)
    }
}

/// Decodes a serde-derived model, labelling failures with `context`.
pub(crate) fn decode_as<T: serde::de::DeserializeOwned>(
    value: Value,
    context: impl FnOnce() -> String,
) -> Result<T, DecodeError> {
    serde_json::from_value(value).map_err(|error| DecodeError::invalid(context(), &error))
}
