//! Granular change operations for the UI.
//!
//! Every reducer call returns a [`ChangeSet`]: row operations keyed by stable row id plus
//! wholesale replacements of the small parts (header, decisions, session sections) that changed.
//! Applying the row operations in order to the previously published rows yields the new rows
//! exactly (see [`apply_row_ops`]), so a Swift `@Observable` store can patch its array in place and
//! `SwiftUI` only diffs the rows that changed.

use std::collections::{BTreeSet, HashMap, HashSet};

use super::presentation::EventSection;
use super::state::{Decision, Row, SessionHeader};

/// One edit to the row list. Apply in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowOp {
    /// Insert `row` at `index` (indexes are positions after every earlier op of the set).
    Insert {
        /// Position.
        index: u32,
        /// The new row.
        row: Row,
    },
    /// Replace the row at `index`, which has the same id as `row`.
    Update {
        /// Position.
        index: u32,
        /// The new content.
        row: Row,
    },
    /// Remove the row with `id`.
    Remove {
        /// The row id.
        id: String,
    },
}

/// Everything one reducer call changed.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChangeSet {
    /// Row edits, in order.
    pub rows: Vec<RowOp>,
    /// The new header, when it changed.
    pub header: Option<SessionHeader>,
    /// The new decision list, when it changed.
    pub decisions: Option<Vec<Decision>>,
    /// The new session sections, when they changed.
    pub sections: Option<Vec<EventSection>>,
}

impl ChangeSet {
    /// True when nothing changed.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.rows.is_empty()
            && self.header.is_none()
            && self.decisions.is_none()
            && self.sections.is_none()
    }

    /// Appends a later change set: row ops concatenate, wholesale parts take the later value.
    pub fn extend(&mut self, later: Self) {
        self.rows.extend(later.rows);
        if later.header.is_some() {
            self.header = later.header;
        }
        if later.decisions.is_some() {
            self.decisions = later.decisions;
        }
        if later.sections.is_some() {
            self.sections = later.sections;
        }
    }
}

/// Why [`apply_row_ops`] could not apply an op.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RowOpError {
    /// An insert or update position is past the end.
    #[error("row op index {index} is out of bounds for {len} rows")]
    OutOfBounds {
        /// The index.
        index: u32,
        /// The row count.
        len: usize,
    },
    /// An update targets a row with a different id.
    #[error("update at {index} targets `{found}`, not `{expected}`")]
    IdMismatch {
        /// The index.
        index: u32,
        /// The op's row id.
        expected: String,
        /// The id at that index.
        found: String,
    },
    /// A remove names a row that is not there.
    #[error("no row `{id}` to remove")]
    MissingRow {
        /// The id.
        id: String,
    },
}

fn position(index: u32) -> usize {
    usize::try_from(index).unwrap_or(usize::MAX)
}

fn index_of(position: usize) -> u32 {
    u32::try_from(position).unwrap_or(u32::MAX)
}

/// Applies `ops` to `rows` in order: the reference semantics a host store must follow.
///
/// # Errors
///
/// An op that does not fit `rows`; `rows` keeps the ops applied before it.
pub fn apply_row_ops(rows: &mut Vec<Row>, ops: &[RowOp]) -> Result<(), RowOpError> {
    for op in ops {
        match op {
            RowOp::Insert { index, row } => {
                let at = position(*index);
                if at > rows.len() {
                    return Err(RowOpError::OutOfBounds {
                        index: *index,
                        len: rows.len(),
                    });
                }
                rows.insert(at, row.clone());
            }
            RowOp::Update { index, row } => {
                let len = rows.len();
                let slot = rows
                    .get_mut(position(*index))
                    .ok_or(RowOpError::OutOfBounds { index: *index, len })?;
                if slot.id != row.id {
                    return Err(RowOpError::IdMismatch {
                        index: *index,
                        expected: row.id.clone(),
                        found: slot.id.clone(),
                    });
                }
                *slot = row.clone();
            }
            RowOp::Remove { id } => {
                let at = rows
                    .iter()
                    .position(|row| row.id == *id)
                    .ok_or_else(|| RowOpError::MissingRow { id: id.clone() })?;
                rows.remove(at);
            }
        }
    }
    Ok(())
}

/// The ops that turn rows with ids `old_ids` into `new`. `changed` says whether a surviving row's
/// content changed.
pub(super) fn diff_ids(
    old_ids: &[String],
    new: &[Row],
    changed: &dyn Fn(&Row) -> bool,
) -> Vec<RowOp> {
    let new_ids: HashSet<&str> = new.iter().map(|row| row.id.as_str()).collect();
    let mut ops = Vec::new();
    let mut working: Vec<&str> = Vec::with_capacity(old_ids.len());
    for id in old_ids {
        if new_ids.contains(id.as_str()) {
            working.push(id);
        } else {
            ops.push(RowOp::Remove { id: id.clone() });
        }
    }
    for (at, row) in new.iter().enumerate() {
        if working.get(at).copied() == Some(row.id.as_str()) {
            if changed(row) {
                ops.push(RowOp::Update {
                    index: index_of(at),
                    row: row.clone(),
                });
            }
            continue;
        }
        let later = working
            .iter()
            .skip(at)
            .position(|id| *id == row.id)
            .map(|offset| offset + at);
        if let Some(from) = later {
            working.remove(from);
            ops.push(RowOp::Remove { id: row.id.clone() });
        }
        working.insert(at, row.id.as_str());
        ops.push(RowOp::Insert {
            index: index_of(at),
            row: row.clone(),
        });
    }
    ops
}

/// The ops that turn `old` into `new`, comparing row content.
#[must_use]
pub fn diff_rows(old: &[Row], new: &[Row]) -> Vec<RowOp> {
    let ids: Vec<String> = old.iter().map(|row| row.id.clone()).collect();
    let previous: HashMap<&str, &Row> = old.iter().map(|row| (row.id.as_str(), row)).collect();
    diff_ids(&ids, new, &|row| {
        previous.get(row.id.as_str()) != Some(&row)
    })
}

/// Records row mutations during one reducer call so the call can report ops without copying
/// every row.
#[derive(Debug, Clone, Default)]
pub(super) struct Journal {
    /// The row ids before the first structural change of the call.
    old_ids: Option<Vec<String>>,
    /// Ids whose content may have changed.
    touched: BTreeSet<String>,
}

impl Journal {
    /// Notes a structural change (insert, remove, reorder) about to happen to `rows`.
    pub(super) fn structural(&mut self, rows: &[Row]) {
        if self.old_ids.is_none() {
            self.old_ids = Some(rows.iter().map(|row| row.id.clone()).collect());
        }
    }

    /// Notes that the row with `id` may change.
    pub(super) fn touch(&mut self, id: &str) {
        if !self.touched.contains(id) {
            self.touched.insert(id.to_owned());
        }
    }

    /// The ops for the call, given the rows now; resets the journal.
    pub(super) fn finish(&mut self, rows: &[Row]) -> Vec<RowOp> {
        let touched = std::mem::take(&mut self.touched);
        if let Some(old_ids) = self.old_ids.take() {
            return diff_ids(&old_ids, rows, &|row| touched.contains(&row.id));
        }
        rows.iter()
            .enumerate()
            .filter(|(_, row)| touched.contains(&row.id))
            .map(|(at, row)| RowOp::Update {
                index: index_of(at),
                row: row.clone(),
            })
            .collect()
    }
}
