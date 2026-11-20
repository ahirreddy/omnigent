//! The read-only table preview of data files: delimited text (`.csv`, `.tsv`) parsed here, and
//! the records the apps read from Excel workbooks and Parquet files.
//!
//! Parsed as the web's `web/src/shell/dataTable.ts` does: the delimiter sniffed from the first
//! records, RFC 4180 quoting, each column's type, and bounds that keep a wide or long file cheap
//! to show. Sorting and filtering apply only to the rows the table keeps.

use std::cmp::Ordering;
use std::iter::Peekable;
use std::str::Chars;

use super::content::{FileBody, FileContent};

/// Rows the preview keeps; the rest are only counted.
pub const DATA_TABLE_MAX_ROWS: usize = 1000;
/// Characters of cell text the preview keeps, so wide rows can't exhaust memory.
pub const DATA_TABLE_MAX_CHARS: usize = 2_000_000;
/// Columns the preview keeps; a row of delimiters can't widen every row past this.
pub const DATA_TABLE_MAX_COLUMNS: usize = 500;
/// Cells the preview keeps, header and padding included, so a wide table keeps fewer rows.
pub const DATA_TABLE_MAX_CELLS: usize = 200_000;
/// Longest a column name is kept; 500 of them stay well within the text budget.
pub const DATA_TABLE_MAX_NAME_CHARS: usize = 1_000;

const CANDIDATE_DELIMITERS: [char; 4] = [',', ';', '\t', '|'];
const SNIFF_RECORDS: usize = 20;
const UTF8: &str = "utf-8";

/// What a column holds, inferred from its non-empty cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DataColumnType {
    /// Every cell is a number, `1,234.5` or `25%` included.
    Number,
    /// Every cell is an ISO date or date and time.
    Date,
    /// Anything else.
    Text,
}

/// A delimited file as the table preview shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DataTable {
    /// Column names: the first record, with `column N` for columns past it.
    pub header: Vec<String>,
    /// The kept rows, each padded to the header's width.
    pub rows: Vec<Vec<String>>,
    /// Data rows in the content, kept or not.
    pub total_rows: usize,
    /// Fields in the content's widest row, kept or not.
    pub total_columns: usize,
    /// Each column's type.
    pub column_types: Vec<DataColumnType>,
    /// The delimiter, for example `,`.
    pub delimiter: char,
    /// How the bytes were decoded, for example `utf-8` or `windows-1252`.
    pub encoding: String,
    /// The format or a non-UTF-8 encoding the summary names, for example `windows-1252` or
    /// `Parquet`; empty for UTF-8 delimited text.
    pub description: String,
    /// Text past the budget was cut from a column name or the first row.
    pub text_cut: bool,
    /// The server sent only the start of the file, so `total_rows` is a lower bound.
    pub truncated: bool,
}

impl DataTable {
    /// Each kept row's place in `column`'s ascending order: 0 for an empty cell, else from 1,
    /// equal cells sharing a rank. Sorting rows by rank, then by file order, sorts them as the
    /// web's table does in either direction, with empty cells last.
    #[must_use]
    pub fn column_ranks(&self, column: usize) -> Vec<u32> {
        let column_type = self
            .column_types
            .get(column)
            .copied()
            .unwrap_or(DataColumnType::Text);
        let cells: Vec<&str> = self
            .rows
            .iter()
            .map(|row| row.get(column).map_or("", String::as_str))
            .collect();
        let at = |index: usize| cells.get(index).copied().unwrap_or_default();
        let mut present: Vec<usize> = (0..cells.len())
            .filter(|&index| !is_empty(at(index)))
            .collect();
        present.sort_by(|&a, &b| compare_cells(at(a), at(b), column_type));
        let mut ranks = vec![0_u32; cells.len()];
        let mut rank = 0_u32;
        let mut previous: Option<&str> = None;
        for index in present {
            let value = at(index);
            if previous.is_none_or(|before| compare_cells(before, value, column_type).is_ne()) {
                rank = rank.saturating_add(1);
            }
            previous = Some(value);
            if let Some(slot) = ranks.get_mut(index) {
                *slot = rank;
            }
        }
        ranks
    }
}

/// A binary data file the apps read into the table preview (web `isSpreadsheetPath`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SpreadsheetFormat {
    /// An Excel workbook (`.xlsx`): a table per visible sheet.
    Xlsx,
    /// A Parquet file: one table.
    Parquet,
}

/// The extension of `path`'s file name, when the name has one after its first character.
fn extension(path: &str) -> Option<&str> {
    let name = path.rsplit('/').next().unwrap_or_default();
    name.rfind('.')
        .filter(|&dot| dot > 0)
        .and_then(|dot| name.get(dot + 1..))
}

/// Whether `path` is delimited text that opens in the table preview, with a source view.
#[must_use]
pub fn is_data_table_path(path: &str) -> bool {
    extension(path).is_some_and(|extension| {
        extension.eq_ignore_ascii_case("csv") || extension.eq_ignore_ascii_case("tsv")
    })
}

/// The workbook or Parquet format of `path`, which opens only as a table.
#[must_use]
pub fn spreadsheet_format(path: &str) -> Option<SpreadsheetFormat> {
    let extension = extension(path)?;
    if extension.eq_ignore_ascii_case("xlsx") {
        Some(SpreadsheetFormat::Xlsx)
    } else if extension.eq_ignore_ascii_case("parquet") {
        Some(SpreadsheetFormat::Parquet)
    } else {
        None
    }
}

/// A data file's bytes as text, and the encoding used: UTF-16 by its byte-order mark, else
/// strict UTF-8, else Windows-1252. The text has no byte-order mark.
#[must_use]
pub fn decode_data_file(bytes: &[u8]) -> (String, &'static str) {
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return (utf16(rest, u16::from_le_bytes), "utf-16le");
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return (utf16(rest, u16::from_be_bytes), "utf-16be");
    }
    std::str::from_utf8(bytes).map_or_else(
        |_| {
            (
                bytes.iter().copied().map(windows_1252).collect(),
                "windows-1252",
            )
        },
        |text| (without_bom(text).to_owned(), UTF8),
    )
}

fn without_bom(text: &str) -> &str {
    text.strip_prefix('\u{feff}').unwrap_or(text)
}

fn utf16(bytes: &[u8], unit: fn([u8; 2]) -> u16) -> String {
    let (pairs, remainder) = bytes.as_chunks::<2>();
    // A trailing odd byte is a broken unit, shown as the replacement character.
    let odd = !remainder.is_empty();
    let units: Vec<u16> = pairs.iter().map(|pair| unit(*pair)).collect();
    let mut text = String::from_utf16_lossy(&units);
    if odd {
        text.push(char::REPLACEMENT_CHARACTER);
    }
    text
}

/// A Windows-1252 byte's character, as the WHATWG decoder maps it.
fn windows_1252(byte: u8) -> char {
    const HIGH: [char; 32] = [
        '\u{20ac}', '\u{81}', '\u{201a}', '\u{192}', '\u{201e}', '\u{2026}', '\u{2020}',
        '\u{2021}', '\u{2c6}', '\u{2030}', '\u{160}', '\u{2039}', '\u{152}', '\u{8d}', '\u{17d}',
        '\u{8f}', '\u{90}', '\u{2018}', '\u{2019}', '\u{201c}', '\u{201d}', '\u{2022}', '\u{2013}',
        '\u{2014}', '\u{2dc}', '\u{2122}', '\u{161}', '\u{203a}', '\u{153}', '\u{9d}', '\u{17e}',
        '\u{178}',
    ];
    match byte {
        0x80..=0x9F => HIGH
            .get(usize::from(byte - 0x80))
            .copied()
            .unwrap_or(char::REPLACEMENT_CHARACTER),
        _ => char::from(byte),
    }
}

/// The delimiter of a delimited file; a `.tsv` file is tab-separated.
///
/// Otherwise each candidate splits the first records; one wins when at least half of them share
/// a field count above one, preferring the most agreement, then the most fields. A single-column
/// file falls back to a comma.
#[must_use]
pub fn detect_delimiter(text: &str, path: &str) -> char {
    if path.to_lowercase().ends_with(".tsv") {
        return '\t';
    }
    let mut best = (',', 0, 1);
    for delimiter in CANDIDATE_DELIMITERS {
        // Only field counts are needed, so a huge cell in the sample can't cut it short.
        let options = RecordOptions {
            keep_records: 0,
            scan_records: SNIFF_RECORDS,
            ..RecordOptions::default()
        };
        let counts = parse_records(text, delimiter, options).field_counts;
        let mut tally: Vec<(usize, usize)> = Vec::new();
        for &fields in &counts {
            match tally.iter_mut().find(|(count, _)| *count == fields) {
                Some((_, agreeing)) => *agreeing += 1,
                None => tally.push((fields, 1)),
            }
        }
        let (field_count, agreement) =
            tally
                .iter()
                .fold((1, 0), |(count, agreement), &(fields, agreeing)| {
                    if agreeing > agreement || (agreeing == agreement && fields > count) {
                        (fields, agreeing)
                    } else {
                        (count, agreement)
                    }
                });
        if field_count < 2 || agreement * 2 < counts.len() {
            continue;
        }
        if agreement > best.1 || (agreement == best.1 && field_count > best.2) {
            best = (delimiter, agreement, field_count);
        }
    }
    best.0
}

/// A delimited file for the table preview, or `None` when it has no header row. The first
/// record is the header; short rows are padded and long ones keep their extra cells under
/// generated column names.
#[must_use]
pub fn parse_data_table(text: &str, path: &str, encoding: &str) -> Option<DataTable> {
    let delimiter = detect_delimiter(text, path);
    let parsed = parse_records(
        text,
        delimiter,
        RecordOptions {
            keep_records: DATA_TABLE_MAX_ROWS + 1,
            keep_chars: DATA_TABLE_MAX_CHARS,
            keep_fields: DATA_TABLE_MAX_COLUMNS,
            ..RecordOptions::default()
        },
    );
    let mut records = parsed.kept.into_iter();
    let header = records.next()?;
    let parsed_rows: Vec<Vec<String>> = records.collect();
    let width = parsed_rows
        .iter()
        .map(Vec::len)
        .fold(header.len(), usize::max)
        .max(1);
    // Padding fills every kept row to the widest one, so wide tables keep fewer rows.
    let keep = (DATA_TABLE_MAX_CELLS / width).saturating_sub(1).max(1);
    let rows: Vec<Vec<String>> = parsed_rows
        .into_iter()
        .take(keep)
        .map(|mut row| {
            row.resize(width, String::new());
            row
        })
        .collect();
    let columns: Vec<String> = (0..width)
        .map(|index| {
            header
                .get(index)
                .cloned()
                .unwrap_or_else(|| format!("column {}", index + 1))
        })
        .collect();
    let column_types = (0..width)
        .map(|index| {
            infer_column_type(
                rows.iter()
                    .map(|row| row.get(index).map_or("", String::as_str)),
            )
        })
        .collect();
    Some(DataTable {
        header: columns,
        rows,
        total_rows: parsed.count.saturating_sub(1),
        total_columns: parsed.widest,
        column_types,
        delimiter,
        encoding: encoding.to_owned(),
        description: if encoding == UTF8 {
            String::new()
        } else {
            encoding.to_owned()
        },
        text_cut: false,
        truncated: false,
    })
}

/// The table of records read from a workbook sheet or a Parquet file (web `tableFromRecords`).
///
/// `None` without a header row. The first record is the header: names are cut at
/// [`DATA_TABLE_MAX_NAME_CHARS`] and blank ones labeled `column N`. One text budget covers the
/// names and the kept rows, which stay a prefix: the first row is kept with its text cut when
/// it alone is past the budget.
#[must_use]
pub fn table_from_records(
    records: Vec<Vec<String>>,
    total_rows: usize,
    total_columns: usize,
    description: &str,
    text_cut_earlier: bool,
) -> Option<DataTable> {
    let mut records = records.into_iter();
    let header = records.next()?;
    let parsed_rows: Vec<Vec<String>> = records.collect();
    let width = parsed_rows
        .iter()
        .map(Vec::len)
        .fold(header.len(), usize::max)
        .min(DATA_TABLE_MAX_COLUMNS);
    let keep = (DATA_TABLE_MAX_CELLS / width.max(1))
        .saturating_sub(1)
        .max(1);
    let mut budget = DATA_TABLE_MAX_CHARS;
    let mut text_cut = text_cut_earlier;
    let columns: Vec<String> = (0..width)
        .map(|index| {
            let name = header.get(index).map_or("", String::as_str);
            let cut: String = name.chars().take(DATA_TABLE_MAX_NAME_CHARS).collect();
            text_cut |= cut.len() < name.len();
            // A blank name still needs a label, which counts against the budget too.
            let label = if cut.trim().is_empty() {
                format!("column {}", index + 1)
            } else {
                cut
            };
            budget = budget.saturating_sub(label.chars().count());
            label
        })
        .collect();
    let mut rows: Vec<Vec<String>> = Vec::new();
    for mut row in parsed_rows.into_iter().take(keep) {
        row.truncate(width);
        let length: usize = row.iter().map(|cell| cell.chars().count()).sum();
        if length > budget {
            if rows.is_empty() && budget > 0 {
                rows.push(cut_to_budget(row, budget));
                text_cut = true;
            }
            break;
        }
        budget -= length;
        rows.push(row);
    }
    for row in &mut rows {
        row.resize(width, String::new());
    }
    let column_types = (0..width)
        .map(|index| {
            infer_column_type(
                rows.iter()
                    .map(|row| row.get(index).map_or("", String::as_str)),
            )
        })
        .collect();
    Some(DataTable {
        header: columns,
        rows,
        total_rows,
        total_columns: total_columns.max(width),
        column_types,
        delimiter: ',',
        encoding: UTF8.to_owned(),
        description: description.to_owned(),
        text_cut,
        truncated: false,
    })
}

/// `cells` fitted to `budget` characters: whole until one doesn't fit, which is cut and ends in
/// `…`; the cells after it are left blank.
fn cut_to_budget(cells: Vec<String>, budget: usize) -> Vec<String> {
    let mut left = budget;
    cells
        .into_iter()
        .map(|cell| {
            let length = cell.chars().count();
            if length <= left {
                left -= length;
                return cell;
            }
            let cut = if left > 0 {
                let mut kept: String = cell.chars().take(left - 1).collect();
                kept.push('\u{2026}');
                kept
            } else {
                String::new()
            };
            left = 0;
            cut
        })
        .collect()
}

#[derive(Debug, Clone, Copy)]
struct RecordOptions {
    keep_records: usize,
    keep_chars: usize,
    scan_records: usize,
    keep_fields: usize,
}

impl Default for RecordOptions {
    fn default() -> Self {
        Self {
            keep_records: 0,
            keep_chars: usize::MAX,
            scan_records: usize::MAX,
            keep_fields: usize::MAX,
        }
    }
}

#[derive(Debug, Default)]
struct Records {
    kept: Vec<Vec<String>>,
    count: usize,
    widest: usize,
    /// The first records' field counts, for sniffing.
    field_counts: Vec<usize>,
}

/// The record being read and what has been kept so far.
#[allow(
    clippy::struct_excessive_bools,
    reason = "the parser's independent flags, as the web's parser keeps them"
)]
#[derive(Debug)]
struct RecordReader {
    options: RecordOptions,
    out: Records,
    field_count: usize,
    kept_chars: usize,
    /// Characters of the current record's kept fields.
    record_chars: usize,
    /// Some of the current record's text was left out for the budget.
    record_overflowed: bool,
    /// Past the kept records, fields are only counted, never built.
    keeping: bool,
    fields: Vec<String>,
    field: String,
    field_chars: usize,
    field_has_chars: bool,
    record_has_content: bool,
}

impl RecordReader {
    fn new(options: RecordOptions) -> Self {
        Self {
            options,
            out: Records::default(),
            field_count: 0,
            kept_chars: 0,
            record_chars: 0,
            record_overflowed: false,
            keeping: options.keep_records > 0,
            fields: Vec::new(),
            field: String::new(),
            field_chars: 0,
            field_has_chars: false,
            record_has_content: false,
        }
    }

    /// Whether the field being read is kept: past `keep_fields`, it is only counted.
    const fn keeping_field(&self) -> bool {
        self.keeping && self.fields.len() < self.options.keep_fields
    }

    /// Appends to the field while the record's text fits what's left of the budget.
    fn append(&mut self, char: char) {
        self.field_has_chars = true;
        if !self.keeping_field() {
            return;
        }
        let left = self.options.keep_chars.saturating_sub(self.kept_chars);
        if self.record_chars + self.field_chars + 1 > left {
            self.record_overflowed = true;
            return;
        }
        self.field.push(char);
        self.field_chars += 1;
    }

    fn end_field(&mut self) {
        if self.keeping_field() {
            self.fields.push(std::mem::take(&mut self.field));
            self.record_chars += self.field_chars;
        }
        self.field_count += 1;
        self.field.clear();
        self.field_chars = 0;
        self.field_has_chars = false;
        self.record_has_content = true;
    }

    fn end_record(&mut self) {
        // A blank line, or the newline that ends the file, is not a record.
        if self.record_has_content || self.field_has_chars {
            self.out.count += 1;
            self.out.widest = self.out.widest.max(self.field_count + 1);
            if self.out.field_counts.len() < SNIFF_RECORDS {
                self.out.field_counts.push(self.field_count + 1);
            }
            if self.keeping {
                if self.fields.len() < self.options.keep_fields {
                    self.fields.push(std::mem::take(&mut self.field));
                }
                // The header is kept even cut short; any later record that overflows ends keeping.
                if self.out.kept.is_empty() || !self.record_overflowed {
                    self.kept_chars += self.record_chars + self.field_chars;
                    self.out.kept.push(std::mem::take(&mut self.fields));
                    self.keeping = self.out.kept.len() < self.options.keep_records;
                } else {
                    self.keeping = false;
                }
            }
        }
        self.fields.clear();
        self.field.clear();
        self.field_count = 0;
        self.field_chars = 0;
        self.record_chars = 0;
        self.record_overflowed = false;
        self.field_has_chars = false;
        self.record_has_content = false;
    }
}

/// Splits delimited text into records (RFC 4180: quoted fields may hold the delimiter, newlines
/// and doubled quotes). Records are counted up to `scan_records`; the first `keep_records` are
/// kept while their text fits in `keep_chars`, so the kept records are always a prefix. The
/// first record is kept, its text cut at the budget. Each kept record keeps at most
/// `keep_fields` fields; `widest` counts every record's fields.
fn parse_records(text: &str, delimiter: char, options: RecordOptions) -> Records {
    let mut reader = RecordReader::new(options);
    let mut chars: Peekable<Chars<'_>> = text.chars().peekable();
    let mut in_quotes = false;
    while let Some(char) = chars.next() {
        if in_quotes {
            if char != '"' {
                reader.append(char);
            } else if chars.next_if_eq(&'"').is_some() {
                reader.append('"');
            } else {
                in_quotes = false;
            }
            continue;
        }
        if char == '"' && !reader.field_has_chars {
            in_quotes = true;
            reader.record_has_content = true;
        } else if char == delimiter {
            reader.end_field();
        } else if char == '\n' || char == '\r' {
            if char == '\r' {
                chars.next_if_eq(&'\n');
            }
            reader.end_record();
            if reader.out.count >= options.scan_records {
                break;
            }
        } else {
            reader.append(char);
        }
    }
    if (reader.field_has_chars || reader.record_has_content)
        && reader.out.count < options.scan_records
    {
        reader.end_record();
    }
    reader.out
}

fn is_empty(value: &str) -> bool {
    value.trim().is_empty()
}

/// A column's type from its cells: number, date, else text, judged by the non-empty ones.
#[must_use]
pub fn infer_column_type<'a>(values: impl IntoIterator<Item = &'a str>) -> DataColumnType {
    let present: Vec<&str> = values
        .into_iter()
        .filter(|value| !is_empty(value))
        .collect();
    if present.is_empty() {
        DataColumnType::Text
    } else if present.iter().all(|value| cell_number(value).is_some()) {
        DataColumnType::Number
    } else if present.iter().all(|value| date_sort_key(value).is_some()) {
        DataColumnType::Date
    } else {
        DataColumnType::Text
    }
}

/// Orders two cells of a column of `column_type`; empty cells sort last.
#[must_use]
pub fn compare_cells(a: &str, b: &str, column_type: DataColumnType) -> Ordering {
    match (is_empty(a), is_empty(b)) {
        (true, true) => return Ordering::Equal,
        (true, false) => return Ordering::Greater,
        (false, true) => return Ordering::Less,
        (false, false) => {}
    }
    match column_type {
        // A cell that isn't a number or date, which inference never leaves there, sorts last.
        DataColumnType::Number => match (cell_number(a), cell_number(b)) {
            (Some(a), Some(b)) => compare_numbers(&a, &b),
            (a, b) => a.is_none().cmp(&b.is_none()),
        },
        DataColumnType::Date => match (date_sort_key(a), date_sort_key(b)) {
            (Some(a), Some(b)) => a.cmp(&b),
            (a, b) => a.is_none().cmp(&b.is_none()),
        },
        DataColumnType::Text => natural_compare(a, b),
    }
}

/// A number cell held exactly, so integers past a float's precision still order: the value is
/// `0.digits × 10^magnitude`, with `digits` free of leading and trailing zeros and empty for zero.
#[derive(Debug, PartialEq, Eq)]
struct CellNumber {
    negative: bool,
    digits: String,
    magnitude: i64,
}

/// The number a cell holds, `25%` as 0.25: an optional sign, digits (grouped by commas in
/// threes, or not), an optional fraction and exponent, and an optional percent sign.
fn cell_number(value: &str) -> Option<CellNumber> {
    let mut rest = value.trim();
    let negative = rest.starts_with('-');
    rest = rest.strip_prefix(['-', '+']).unwrap_or(rest);
    let (lead, after) = split_digits(rest);
    rest = after;
    let mut whole = lead.to_owned();
    if rest.starts_with(',') {
        if !(1..=3).contains(&lead.len()) {
            return None;
        }
        while let Some(after_comma) = rest.strip_prefix(',') {
            let group = after_comma.get(..3).filter(|group| {
                group.len() == 3 && group.bytes().all(|byte| byte.is_ascii_digit())
            })?;
            whole.push_str(group);
            rest = after_comma.get(3..).unwrap_or_default();
        }
        if rest.starts_with(|char: char| char.is_ascii_digit()) {
            return None;
        }
    }
    let mut fraction = "";
    if let Some(after_dot) = rest.strip_prefix('.') {
        (fraction, rest) = split_digits(after_dot);
        if fraction.is_empty() {
            return None;
        }
    }
    let mut exponent = 0_i64;
    if let Some(after_e) = rest.strip_prefix(['e', 'E']) {
        let exponent_negative = after_e.starts_with('-');
        let unsigned = after_e.strip_prefix(['-', '+']).unwrap_or(after_e);
        let (digits, after) = split_digits(unsigned);
        if digits.is_empty() {
            return None;
        }
        // Past this, every exponent orders the same, as a float's infinity does.
        let magnitude = digits.parse::<i64>().unwrap_or(i64::MAX).min(1 << 50);
        exponent = if exponent_negative {
            -magnitude
        } else {
            magnitude
        };
        rest = after;
    }
    let percent = rest.starts_with('%');
    rest = rest.strip_prefix('%').unwrap_or(rest);
    if !rest.is_empty() || (whole.is_empty() && fraction.is_empty()) {
        return None;
    }
    let all_digits = format!("{whole}{fraction}");
    let significant = all_digits.trim_start_matches('0');
    let leading_zeros = all_digits.len() - significant.len();
    let digits = significant.trim_end_matches('0').to_owned();
    let length = |count: usize| i64::try_from(count).unwrap_or(i64::MAX);
    Some(CellNumber {
        negative,
        digits,
        magnitude: length(whole.len()) - length(leading_zeros) + exponent
            - if percent { 2 } else { 0 },
    })
}

/// The leading ASCII digits of `text`, and what follows them.
fn split_digits(text: &str) -> (&str, &str) {
    let end = text
        .find(|char: char| !char.is_ascii_digit())
        .unwrap_or(text.len());
    text.split_at(end)
}

fn compare_numbers(a: &CellNumber, b: &CellNumber) -> Ordering {
    let sign = |number: &CellNumber| match (number.digits.is_empty(), number.negative) {
        (true, _) => 0,
        (false, true) => -1,
        (false, false) => 1,
    };
    let (a_sign, b_sign) = (sign(a), sign(b));
    if a_sign != b_sign {
        return a_sign.cmp(&b_sign);
    }
    if a_sign == 0 {
        return Ordering::Equal;
    }
    let order = a
        .magnitude
        .cmp(&b.magnitude)
        .then_with(|| a.digits.cmp(&b.digits));
    if a_sign < 0 { order.reverse() } else { order }
}

const PHANTOM_LEAP_DAY: &str = "1900-02-29";
/// 1900-03-01, in milliseconds since the epoch.
const MARCH_1_1900: i64 = -2_203_891_200_000;
const DAY_MILLIS: i64 = 86_400_000;

/// A date cell's sort key: its time in milliseconds, then a tie-breaker. Excel's phantom
/// 1900-02-29 takes the last millisecond of Feb 28, its time of day breaking the tie, so it sorts
/// after Feb 28 and before Mar 1.
fn date_sort_key(value: &str) -> Option<(i64, i64)> {
    let text = value.trim();
    if let Some(rest) = text.strip_prefix(PHANTOM_LEAP_DAY) {
        let same_time_on_march_1 = cell_date(&format!("1900-03-01{rest}"))?;
        // Clamped so an offset can't push it past Mar 1 or before Feb 28.
        let time_of_day = (same_time_on_march_1 - MARCH_1_1900).clamp(0, DAY_MILLIS - 1);
        return Some((MARCH_1_1900 - 1, 1 + time_of_day));
    }
    cell_date(text).map(|millis| (millis, 0))
}

/// A date cell's time in milliseconds since the epoch: `YYYY-MM-DD`, optionally with a time
/// (`T` or a space, then `HH:MM`, seconds and a fraction) and an offset. A date or time without
/// an offset reads as UTC, so a date sorts as the midnight starting it in any time zone.
fn cell_date(value: &str) -> Option<i64> {
    let text = value.trim();
    let (date, time) = match text.find(['T', ' ']) {
        Some(at) => (text.get(..at)?, Some(text.get(at + 1..)?)),
        None => (text, None),
    };
    let mut parts = date.split('-');
    let year = fixed_number(parts.next()?, 4)?;
    let month = fixed_number(parts.next()?, 2)?;
    let day = fixed_number(parts.next()?, 2)?;
    if parts.next().is_some() || !(1..=12).contains(&month) || day < 1 {
        return None;
    }
    if day > days_in_month(year, month) {
        return None;
    }
    let (millis, offset_minutes) = match time {
        Some(time) => time_of_day(time)?,
        None => (0, 0),
    };
    let days = days_from_civil(year, month, day);
    Some(days * 86_400_000 + millis - offset_minutes * 60_000)
}

/// Milliseconds into the day and the offset in minutes, from `HH:MM[:SS[.fff]][Z|±HH[:]MM]`.
fn time_of_day(time: &str) -> Option<(i64, i64)> {
    let (hours, rest) = take_digits(time, 2)?;
    let (minutes, mut rest) = take_digits(rest.strip_prefix(':')?, 2)?;
    let (mut seconds, mut millis) = (0, 0);
    if let Some(after) = rest.strip_prefix(':') {
        (seconds, rest) = take_digits(after, 2)?;
        if let Some(after_dot) = rest.strip_prefix('.') {
            let (fraction, after) = split_digits(after_dot);
            if fraction.is_empty() {
                return None;
            }
            // Milliseconds are the fraction's first three digits.
            millis = format!("{fraction:0<3}")
                .get(..3)
                .and_then(|digits| digits.parse::<i64>().ok())
                .unwrap_or(0);
            rest = after;
        }
    }
    if hours > 23 || minutes > 59 || seconds > 59 {
        return None;
    }
    let offset = match rest {
        "" | "Z" => 0,
        _ => {
            let negative = rest.starts_with('-');
            let (zone_hours, after) = take_digits(rest.strip_prefix(['+', '-'])?, 2)?;
            let (zone_minutes, after) = take_digits(after.strip_prefix(':').unwrap_or(after), 2)?;
            if !after.is_empty() || zone_hours > 23 || zone_minutes > 59 {
                return None;
            }
            let total = zone_hours * 60 + zone_minutes;
            if negative { -total } else { total }
        }
    };
    Some((
        ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis,
        offset,
    ))
}

/// The number in the first `width` characters of `text` when they are ASCII digits, and the rest.
fn take_digits(text: &str, width: usize) -> Option<(i64, &str)> {
    Some((fixed_number(text.get(..width)?, width)?, text.get(width..)?))
}

/// `text` as a number when it is exactly `width` ASCII digits.
fn fixed_number(text: &str, width: usize) -> Option<i64> {
    (text.len() == width && text.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| text.parse().ok())
        .flatten()
}

const fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Days from 1970-01-01 to a proleptic Gregorian date.
const fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// Text in natural order, as `localeCompare` with numeric collation and base sensitivity orders
/// it: digit runs by value, letters without regard to case, spaces before punctuation before
/// digits before letters.
fn natural_compare(a: &str, b: &str) -> Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let order = compare_digit_runs(&digit_run(&mut a), &digit_run(&mut b));
                if order.is_ne() {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = collation_key(x).cmp(&collation_key(y));
                if order.is_ne() {
                    return order;
                }
                a.next();
                b.next();
            }
        }
    }
}

fn digit_run(chars: &mut Peekable<Chars<'_>>) -> String {
    let mut run = String::new();
    while let Some(digit) = chars.next_if(char::is_ascii_digit) {
        run.push(digit);
    }
    run
}

fn compare_digit_runs(a: &str, b: &str) -> Ordering {
    let (a, b) = (a.trim_start_matches('0'), b.trim_start_matches('0'));
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

fn collation_key(char: char) -> (u8, char) {
    let class = if char.is_whitespace() {
        0
    } else if char.is_ascii_digit() {
        2
    } else if char.is_alphanumeric() {
        3
    } else {
        1
    };
    (class, char.to_lowercase().next().unwrap_or(char))
}

/// The table `content` shows when it is a data file, decoded as the web decodes it.
#[must_use]
pub fn file_data_table(content: &FileContent) -> Option<DataTable> {
    let path = content.path.as_str();
    if !is_data_table_path(path) {
        return None;
    }
    let mut table = match &content.body {
        FileBody::Text(text) => parse_data_table(without_bom(text), path, UTF8),
        FileBody::Binary(bytes) => {
            let (text, encoding) = decode_data_file(bytes);
            parse_data_table(&text, path, encoding)
        }
    }?;
    table.truncated = content.truncated;
    Some(table)
}

#[cfg(test)]
#[path = "data_table_tests.rs"]
mod tests;
