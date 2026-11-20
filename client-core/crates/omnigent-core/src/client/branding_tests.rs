//! Operator branding: what counts as set, the explicit empty heading, and the logo read.

use futures::executor::block_on;
use serde_json::json;

use super::super::SessionError;
use super::super::test_support::{Reply, RouteTransport, connected};
use super::{Branding, MAX_LOGO_BYTES};

#[test]
fn branding_reads_as_the_web_parses_it() {
    let info = json!({"branding": {
        "app_name": "Acme Agents", "heading": "", "powered_by": false,
        "logos": {"main": "/v1/branding/logo/main", "loading": null, "favicon": 7}
    }});
    assert_eq!(
        Branding::from_info(&info),
        Some(Branding {
            app_name: Some("Acme Agents".into()),
            heading: Some(String::new()),
            logo_main: Some("/v1/branding/logo/main".into()),
            logo_loading: None,
            logo_favicon: None,
            powered_by: false,
        })
    );
    // Nothing set, or the defaults spelled out, is no branding at all.
    assert_eq!(Branding::from_info(&json!({})), None);
    assert_eq!(
        Branding::from_info(&json!({"branding": {"app_name": "  ", "powered_by": true,
                                                  "logos": {"main": null}}})),
        None
    );
    // A logo path outside the logo route is ignored.
    let elsewhere = json!({"branding": {"logos": {"main": "https://example.com/x.png"}}});
    assert_eq!(Branding::from_info(&elsewhere), None);
    let heading = Branding::from_info(&json!({"branding": {"heading": "Ship it"}})).unwrap();
    assert!(heading.powered_by && heading.app_name.is_none());
}

#[test]
fn the_logo_reads_its_bytes_from_the_logo_route_only() {
    let core = connected(RouteTransport::local());
    core.transport().respond(
        None,
        "/v1/branding/logo/main",
        None,
        Reply::Typed {
            status: 200,
            content_type: "image/png".into(),
            body: vec![0x89, b'P', b'N', b'G'],
        },
    );
    assert_eq!(
        block_on(core.branding_logo("/v1/branding/logo/main")).unwrap(),
        [0x89, b'P', b'N', b'G']
    );
    for path in [
        "/v1/sessions",
        "/v1/branding/logo/",
        "/v1/branding/logo/../me",
    ] {
        assert!(
            matches!(
                block_on(core.branding_logo(path)),
                Err(SessionError::InvalidIdentifier { .. })
            ),
            "{path}"
        );
    }
    core.transport().respond(
        None,
        "/v1/branding/logo/main",
        None,
        Reply::Typed {
            status: 200,
            content_type: "image/png".into(),
            body: vec![0; MAX_LOGO_BYTES + 1],
        },
    );
    assert!(matches!(
        block_on(core.branding_logo("/v1/branding/logo/main")),
        Err(SessionError::MalformedResponse { .. })
    ));
}
