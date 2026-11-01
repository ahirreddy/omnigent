//! A field that distinguishes "not sent" from an explicit `null`.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A wire field whose absence means something different from an explicit `null`.
///
/// Sparse payloads (list rows, WebSocket `changed` frames, older servers) omit fields they do not
/// report; an explicit `null` clears. Use with `#[serde(default, skip_serializing_if =
/// "Field::is_absent")]`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub enum Field<T> {
    /// The key was not in the payload: keep whatever is already known.
    #[default]
    Absent,
    /// The key was sent as `null`: clear the known value.
    Null,
    /// The key was sent with a value.
    Present(T),
}

impl<T> Field<T> {
    /// True when the key was not in the payload.
    #[must_use]
    pub const fn is_absent(&self) -> bool {
        matches!(self, Self::Absent)
    }

    /// True when the key was in the payload, as a value or `null`.
    #[must_use]
    pub const fn is_reported(&self) -> bool {
        !self.is_absent()
    }

    /// The value, if one was sent.
    #[must_use]
    pub const fn value(&self) -> Option<&T> {
        match self {
            Self::Present(value) => Some(value),
            Self::Absent | Self::Null => None,
        }
    }

    /// The value, if one was sent.
    #[must_use]
    pub fn into_value(self) -> Option<T> {
        match self {
            Self::Present(value) => Some(value),
            Self::Absent | Self::Null => None,
        }
    }

    /// Applies this field as a sparse update: absent keeps `target`, `null` clears it, a value
    /// replaces it.
    pub fn apply_to(self, target: &mut Option<T>) {
        match self {
            Self::Absent => {}
            Self::Null => *target = None,
            Self::Present(value) => *target = Some(value),
        }
    }
}

impl<T> From<Option<T>> for Field<T> {
    fn from(value: Option<T>) -> Self {
        value.map_or(Self::Null, Self::Present)
    }
}

impl<T: Serialize> Serialize for Field<T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Present(value) => serializer.serialize_some(value),
            Self::Absent | Self::Null => serializer.serialize_none(),
        }
    }
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Field<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Option::<T>::deserialize(deserializer).map(Self::from)
    }
}

/// Deserializes `null` as the type's default (for server fields with a default value).
pub(crate) fn null_as_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Option::unwrap_or_default)
}

/// For `skip_serializing_if` on boolean flags that the server omits when false.
#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde's skip_serializing_if passes a reference"
)]
pub(crate) const fn is_false(value: &bool) -> bool {
    !*value
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct Row {
        #[serde(default, skip_serializing_if = "Field::is_absent")]
        title: Field<String>,
    }

    #[test]
    fn absent_null_and_value_are_distinct_and_round_trip() {
        for (json, field) in [
            ("{}", Field::Absent),
            (r#"{"title":null}"#, Field::Null),
            (r#"{"title":"x"}"#, Field::Present("x".to_owned())),
        ] {
            let row: Row = serde_json::from_str(json).unwrap();
            assert_eq!(row.title, field, "{json}");
            assert_eq!(serde_json::to_string(&row).unwrap(), json);
        }
    }

    #[test]
    fn apply_to_keeps_clears_or_replaces() {
        let mut target = Some(1);
        Field::Absent.apply_to(&mut target);
        assert_eq!(target, Some(1));
        Field::Present(2).apply_to(&mut target);
        assert_eq!(target, Some(2));
        Field::Null.apply_to(&mut target);
        assert_eq!(target, None);
    }
}
