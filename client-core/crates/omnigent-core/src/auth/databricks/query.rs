//! Query-string items with Foundation `URLComponents.queryItems` semantics: `&`-separated,
//! split at the first `=`, percent-decoded, and **no** `+`-as-space rewriting (OAuth codes and
//! states are opaque, and a literal `+` must survive).

/// One query item. `value` is `None` when the item has no `=` at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct QueryItem {
    pub(super) name: String,
    pub(super) value: Option<String>,
}

/// The items of `query`, or `None` when an item is not valid percent-encoded UTF-8.
pub(super) fn items(query: &str) -> Option<Vec<QueryItem>> {
    query
        .split('&')
        .map(|item| {
            let (name, value) = match item.split_once('=') {
                Some((name, value)) => (name, Some(value)),
                None => (item, None),
            };
            Some(QueryItem {
                name: percent_decode(name)?,
                value: match value {
                    Some(value) => Some(percent_decode(value)?),
                    None => None,
                },
            })
        })
        .collect()
}

/// The values of every item named `name` (`None` entries for items without `=`).
pub(super) fn values<'a>(items: &'a [QueryItem], name: &str) -> Vec<Option<&'a str>> {
    items
        .iter()
        .filter(|item| item.name == name)
        .map(|item| item.value.as_deref())
        .collect()
}

pub(super) fn percent_decode(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        if byte == b'%' {
            let high = bytes.get(index + 1).copied().and_then(hex_value)?;
            let low = bytes.get(index + 2).copied().and_then(hex_value)?;
            out.push((high << 4) | low);
            index += 3;
        } else {
            out.push(byte);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

const fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_like_url_components() {
        let parsed = items("code=code%2Bvalue&plus=a+b&bare&empty=&o=1=2").unwrap();
        let pairs: Vec<_> = parsed
            .iter()
            .map(|item| (item.name.as_str(), item.value.as_deref()))
            .collect();
        assert_eq!(
            pairs,
            vec![
                ("code", Some("code+value")),
                ("plus", Some("a+b")),
                ("bare", None),
                ("empty", Some("")),
                ("o", Some("1=2")),
            ]
        );
        assert_eq!(values(&parsed, "bare"), vec![None]);
    }

    #[test]
    fn rejects_bad_escapes() {
        assert_eq!(items("a=%ZZ"), None);
        assert_eq!(items("a=%C3"), None);
        assert_eq!(items("a=%"), None);
    }
}
