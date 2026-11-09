//! Event conversions a recorded session does not produce.

use super::core;
use super::*;

#[test]
fn the_rarer_states_convert() {
    assert_eq!(
        ChangedFilesUpdate::from(core::events::ChangedFilesUpdate::Unavailable(
            "no git".into()
        )),
        ChangedFilesUpdate::Unavailable {
            message: "no git".into()
        }
    );
    assert_eq!(
        LinkState::from(core::realtime::ConnectionState::Idle),
        LinkState::Idle
    );
    assert_eq!(
        AuthenticationMode::from(core::auth::mode::AuthenticationMode::Unsupported {
            mode: "kerberos".into()
        }),
        AuthenticationMode::Unsupported {
            mode: "kerberos".into()
        }
    );
    assert_eq!(
        NotificationKind::from(core::notifications::route::NotificationKind::Failed),
        NotificationKind::Failed
    );
}
