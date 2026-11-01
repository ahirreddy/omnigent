//! The row-op contract: applying a diff to the old rows always yields the new rows.

use proptest::prelude::*;

use super::{assistant, user};
use crate::reducer::{Row, RowOp, RowOpError, apply_row_ops, diff_rows};

fn rows(spec: &[(u8, bool)]) -> Vec<Row> {
    spec.iter()
        .map(|(id, edited)| {
            let mut row = assistant(&format!("row-{id}"), "text");
            if *edited {
                row.text.push_str(" (edited)");
            }
            row
        })
        .collect()
}

fn unique(spec: Vec<(u8, bool)>) -> Vec<(u8, bool)> {
    let mut seen = std::collections::BTreeSet::new();
    spec.into_iter()
        .filter(|(id, _)| seen.insert(*id))
        .collect()
}

proptest! {
    #[test]
    fn diff_then_apply_reproduces_any_reordering(
        old in prop::collection::vec((0_u8..24, any::<bool>()), 0..16),
        new in prop::collection::vec((0_u8..24, any::<bool>()), 0..16),
    ) {
        let old = rows(&unique(old));
        let new = rows(&unique(new));
        let ops = diff_rows(&old, &new);
        let mut patched = old;
        apply_row_ops(&mut patched, &ops).expect("ops apply");
        prop_assert_eq!(patched, new);
    }
}

#[test]
fn unchanged_rows_produce_no_ops_and_moves_are_remove_then_insert() {
    let first = user("a", "A");
    let second = assistant("b", "B");
    assert_eq!(
        diff_rows(
            &[first.clone(), second.clone()],
            &[first.clone(), second.clone()]
        ),
        []
    );
    let ops = diff_rows(&[first.clone(), second.clone()], &[second.clone(), first]);
    assert_eq!(
        ops,
        [
            RowOp::Remove { id: "b".to_owned() },
            RowOp::Insert {
                index: 0,
                row: second
            },
        ]
    );
}

#[test]
fn malformed_ops_are_errors_not_silent_edits() {
    let mut list = vec![user("a", "A")];
    let wrong = RowOp::Update {
        index: 0,
        row: user("b", "B"),
    };
    assert!(matches!(
        apply_row_ops(&mut list, &[wrong]),
        Err(RowOpError::IdMismatch { .. })
    ));
    let missing = RowOp::Remove {
        id: "zz".to_owned(),
    };
    assert!(matches!(
        apply_row_ops(&mut list, &[missing]),
        Err(RowOpError::MissingRow { .. })
    ));
    let far = RowOp::Insert {
        index: 5,
        row: user("c", "C"),
    };
    assert!(matches!(
        apply_row_ops(&mut list, &[far]),
        Err(RowOpError::OutOfBounds { .. })
    ));
    assert_eq!(list, [user("a", "A")]);
}
