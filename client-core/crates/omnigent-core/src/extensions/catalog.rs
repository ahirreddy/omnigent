//! `GET /v1/extensions`: the installed extensions a page or sidebar entry can come from.

#![allow(
    clippy::redundant_pub_crate,
    reason = "crate-internal helpers of a private module; `pub` would trip rustc's unreachable_pub"
)]

use serde_json::{Map, Value};

use crate::client::json::{as_object, opt_array, opt_object, opt_str, req_str};

/// One page an extension contributes, at `/extensions/<extension id>/<route>`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExtensionPage {
    /// Id, unique within the extension.
    pub id: String,
    /// Title: the frame's title and the error heading.
    pub title: String,
    /// The one path segment the page is at.
    pub route: String,
    /// The view its bundle renders.
    pub view: String,
}

/// A sidebar entry an extension contributes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExtensionNavigation {
    /// Id.
    pub id: String,
    /// The row's label.
    pub label: String,
    /// The page it opens, by id.
    pub page: String,
    /// The web's icon name (`dashboard`, `panels-top-left`, `puzzle`, `search`), if any.
    pub icon: Option<String>,
    /// Where it sorts among extension entries, ascending.
    pub order: i64,
}

/// An extension's browser bundle: content-addressed asset paths on the server.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExtensionBundle {
    /// The bundle's content digest.
    pub digest: String,
    /// `/v1/extensions/<id>/assets/<digest>/extension.js`.
    pub script_url: String,
    /// The stylesheet, when the bundle has one.
    pub style_url: Option<String>,
}

/// An installed, enabled extension.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Extension {
    /// Id, such as `example.hello-page`; it always contains a dot.
    pub id: String,
    /// Name to show.
    pub display_name: String,
    /// Version.
    pub version: String,
    /// The permissions its manifest declares (`navigation`, `storage.user`...).
    pub permissions: Vec<String>,
    /// Its pages.
    pub pages: Vec<ExtensionPage>,
    /// Its sidebar entries, by `order` then id.
    pub navigation: Vec<ExtensionNavigation>,
    /// Its browser bundle; `None` when it declares none, so its pages cannot start.
    pub bundle: Option<ExtensionBundle>,
}

impl Extension {
    /// The page at `route`.
    #[must_use]
    pub fn page_at(&self, route: &str) -> Option<&ExtensionPage> {
        self.pages.iter().find(|page| page.route == route)
    }
}

/// A sidebar entry with the page it opens.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExtensionNavigationEntry {
    /// The extension.
    pub extension_id: String,
    /// The entry.
    pub navigation: ExtensionNavigation,
    /// The page it opens.
    pub page: ExtensionPage,
}

/// The enabled extensions in a `/v1/extensions` body. Unavailable ones (a declared bundle the
/// server could not resolve) are left out, as the web leaves them out.
///
/// # Errors
///
/// A description of the first field with the wrong shape.
pub fn decode_catalog(value: &Value) -> Result<Vec<Extension>, String> {
    let object = as_object(value, "extension catalog")?;
    if opt_str(object, "object")?.as_deref() != Some("list") {
        return Err("extension catalog is not a list".to_owned());
    }
    let data = opt_array(object, "data")?.ok_or("`data` is missing")?;
    let mut extensions = Vec::new();
    for (index, item) in data.iter().enumerate() {
        let item = as_object(item, "extension")?;
        let decoded =
            decode_extension(item).map_err(|detail| format!("extension {index}: {detail}"))?;
        if let Some(extension) = decoded {
            extensions.push(extension);
        }
    }
    Ok(extensions)
}

fn decode_extension(item: &Map<String, Value>) -> Result<Option<Extension>, String> {
    let id = req_str(item, "id")?;
    if !is_extension_id(&id) {
        return Err(format!("`id` {id:?} is not an extension id"));
    }
    if req_str(item, "status")? != "enabled" {
        return Ok(None);
    }
    let permissions = strings(item, "permissions")?;
    let mut pages = Vec::new();
    for page in opt_array(item, "pages")?.into_iter().flatten() {
        let page = as_object(page, "page")?;
        let route = req_str(page, "route")?;
        if !is_route(&route) {
            return Err(format!("page route {route:?} is not one path segment"));
        }
        pages.push(ExtensionPage {
            id: non_empty(page, "id")?,
            title: req_str(page, "title")?,
            route,
            view: non_empty(page, "view")?,
        });
    }
    let mut navigation = Vec::new();
    for entry in opt_array(item, "primary_navigation")?.into_iter().flatten() {
        let entry = as_object(entry, "navigation entry")?;
        navigation.push(ExtensionNavigation {
            id: non_empty(entry, "id")?,
            label: req_str(entry, "label")?,
            page: non_empty(entry, "page")?,
            icon: opt_str(entry, "icon")?,
            order: match entry.get("order") {
                Some(Value::Number(number)) => {
                    number.as_i64().ok_or("`order` is not an integer")?
                }
                None | Some(Value::Null) => 0,
                Some(_) => return Err("`order` is not a number".to_owned()),
            },
        });
    }
    navigation.sort_by(|left, right| left.order.cmp(&right.order).then(left.id.cmp(&right.id)));
    Ok(Some(Extension {
        display_name: req_str(item, "display_name")?,
        version: opt_str(item, "version")?.unwrap_or_default(),
        bundle: bundle(item, &id)?,
        id,
        permissions,
        pages,
        navigation,
    }))
}

fn bundle(item: &Map<String, Value>, id: &str) -> Result<Option<ExtensionBundle>, String> {
    let Some(browser) = opt_object(item, "browser")? else {
        return Ok(None);
    };
    let (Some(digest), Some(script_url)) =
        (opt_str(browser, "digest")?, opt_str(browser, "script_url")?)
    else {
        return Ok(None);
    };
    let style_url = opt_str(browser, "style_url")?;
    for url in std::iter::once(&script_url).chain(style_url.as_ref()) {
        if asset_path(url, id).is_none() {
            return Err(format!(
                "asset {url:?} is not one of this extension's assets"
            ));
        }
    }
    Ok(Some(ExtensionBundle {
        digest,
        script_url,
        style_url,
    }))
}

/// `url` when it is one of extension `id`'s assets on this server:
/// `/v1/extensions/<id>/assets/<digest>/extension.js` or `extension.css`, nothing else.
#[must_use]
pub(crate) fn asset_path<'a>(url: &'a str, id: &str) -> Option<&'a str> {
    let rest = url
        .strip_prefix("/v1/extensions/")?
        .strip_prefix(id)?
        .strip_prefix("/assets/")?;
    let (digest, name) = rest.split_once('/')?;
    let digest_ok = !digest.is_empty() && digest.bytes().all(|byte| byte.is_ascii_alphanumeric());
    (digest_ok && matches!(name, "extension.js" | "extension.css")).then_some(url)
}

/// The sidebar entries of every extension, by `order` then id across extensions, each with the
/// page it opens; an entry naming no page of its extension is left out.
#[must_use]
pub fn navigation_entries(extensions: &[Extension]) -> Vec<ExtensionNavigationEntry> {
    let mut entries: Vec<ExtensionNavigationEntry> = extensions
        .iter()
        .flat_map(|extension| {
            extension.navigation.iter().filter_map(|navigation| {
                let page = extension
                    .pages
                    .iter()
                    .find(|page| page.id == navigation.page)?;
                Some(ExtensionNavigationEntry {
                    extension_id: extension.id.clone(),
                    navigation: navigation.clone(),
                    page: page.clone(),
                })
            })
        })
        .collect();
    entries.sort_by(|left, right| {
        left.navigation
            .order
            .cmp(&right.navigation.order)
            .then_with(|| left.navigation.id.cmp(&right.navigation.id))
    });
    entries
}

/// Extension `extension_id`'s page at `route`.
#[must_use]
pub fn resolve_page<'a>(
    extensions: &'a [Extension],
    extension_id: &str,
    route: &str,
) -> Option<(&'a Extension, &'a ExtensionPage)> {
    let extension = extensions.iter().find(|item| item.id == extension_id)?;
    Some((extension, extension.page_at(route)?))
}

/// An extension id as the web's routes take it: one non-empty segment with a dot.
fn is_extension_id(id: &str) -> bool {
    id.contains('.') && is_route(id)
}

/// One printable path segment.
fn is_route(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && !segment.contains(['/', '\\', '?', '#', '%'])
        && segment
            .chars()
            .all(|character| !character.is_control() && !character.is_whitespace())
}

fn non_empty(object: &Map<String, Value>, key: &str) -> Result<String, String> {
    let value = req_str(object, key)?;
    if value.is_empty() {
        return Err(format!("`{key}` is empty"));
    }
    Ok(value)
}

fn strings(object: &Map<String, Value>, key: &str) -> Result<Vec<String>, String> {
    opt_array(object, key)?
        .into_iter()
        .flatten()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("`{key}` has a value that is not a string"))
        })
        .collect()
}
