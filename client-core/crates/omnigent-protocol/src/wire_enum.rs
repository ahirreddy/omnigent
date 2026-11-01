//! String enums whose unrecognised values are kept verbatim instead of failing or mapping onto a
//! known value.

/// Declares a string wire enum with an `Unknown { value }` variant, plus `parse`, `as_str`,
/// `Display`, `Serialize` and `Deserialize`.
macro_rules! wire_enum {
    (
        $(#[$meta:meta])*
        pub enum $name:ident {
            $( $(#[$variant_meta:meta])* $variant:ident = $wire:literal, )+
        }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, PartialEq, Eq, Hash)]
        pub enum $name {
            $( $(#[$variant_meta])* $variant, )+
            /// A value newer than this client, kept verbatim.
            Unknown {
                /// The value as sent.
                value: String,
            },
        }

        impl $name {
            /// Maps a wire value; anything unrecognised becomes `Unknown`.
            #[must_use]
            pub fn parse(value: &str) -> Self {
                match value {
                    $( $wire => Self::$variant, )+
                    other => Self::Unknown { value: other.to_owned() },
                }
            }

            /// The wire value.
            #[must_use]
            pub fn as_str(&self) -> &str {
                match self {
                    $( Self::$variant => $wire, )+
                    Self::Unknown { value } => value,
                }
            }

            /// True for a value this client does not know.
            #[must_use]
            pub const fn is_unknown(&self) -> bool {
                matches!(self, Self::Unknown { .. })
            }
        }

        impl ::std::fmt::Display for $name {
            fn fmt(&self, f: &mut ::std::fmt::Formatter<'_>) -> ::std::fmt::Result {
                f.write_str(self.as_str())
            }
        }

        impl ::serde::Serialize for $name {
            fn serialize<S: ::serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(self.as_str())
            }
        }

        impl<'de> ::serde::Deserialize<'de> for $name {
            fn deserialize<D: ::serde::Deserializer<'de>>(
                deserializer: D,
            ) -> Result<Self, D::Error> {
                let value = <String as ::serde::Deserialize>::deserialize(deserializer)?;
                Ok(Self::parse(&value))
            }
        }
    };
}

pub(crate) use wire_enum;
