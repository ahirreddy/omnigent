use std::cmp::Ordering;

use super::*;
use crate::workspace::WorkspacePath;

fn table(text: &str, path: &str) -> DataTable {
    parse_data_table(text, path, UTF8).expect("a table")
}

fn strings(rows: &[&[&str]]) -> Vec<Vec<String>> {
    rows.iter()
        .map(|row| row.iter().map(|cell| (*cell).to_owned()).collect())
        .collect()
}

fn sorted<'a>(values: &[&'a str], column_type: DataColumnType) -> Vec<&'a str> {
    let mut values = values.to_vec();
    values.sort_by(|a, b| compare_cells(a, b, column_type));
    values
}

#[test]
fn data_files_are_csv_and_tsv_by_extension() {
    for (path, expected) in [
        ("results.csv", true),
        ("out/DATA.TSV", true),
        ("notes.csv.md", false),
        ("data.json", false),
        ("csv", false),
        (".csv", false),
    ] {
        assert_eq!(is_data_table_path(path), expected, "{path}");
    }
}

#[test]
fn quoted_fields_hold_the_delimiter_newlines_and_doubled_quotes() {
    let parsed = table(
        "name,note\r\n\"Smith, J\",\"said \"\"hi\"\"\nthen left\"\r\nLee,ok\r\n",
        "people.csv",
    );
    assert_eq!(parsed.header, ["name", "note"]);
    assert_eq!(
        parsed.rows,
        strings(&[&["Smith, J", "said \"hi\"\nthen left"], &["Lee", "ok"]])
    );
    assert_eq!(parsed.total_rows, 2);
}

#[test]
fn blank_lines_are_skipped_and_short_rows_padded_under_named_columns() {
    let parsed = table("a,b\n1\n\n2,3,4\n", "x.csv");
    assert_eq!(parsed.header, ["a", "b", "column 3"]);
    assert_eq!(parsed.rows, strings(&[&["1", "", ""], &["2", "3", "4"]]));
}

#[test]
fn a_sparse_wide_file_is_bounded_by_columns_and_cells_and_still_counted() {
    // One row of delimiters would otherwise widen every row: 1,000 rows × 2,000 columns.
    let text = format!("h\n{}{}\n", "x\n".repeat(999), ",".repeat(1999));
    let parsed = table(&text, "sparse.csv");
    assert_eq!(parsed.header.len(), DATA_TABLE_MAX_COLUMNS);
    assert_eq!(parsed.total_columns, 2000);
    assert_eq!(parsed.total_rows, 1000);
    assert!((parsed.rows.len() + 1) * parsed.header.len() <= DATA_TABLE_MAX_CELLS);
    assert!(
        parsed
            .rows
            .iter()
            .all(|row| row.len() == DATA_TABLE_MAX_COLUMNS)
    );
}

#[test]
fn an_oversized_header_keeps_only_the_column_cap() {
    let parsed = table(&format!("{}c\n1\n", "c,".repeat(3000)), "wide.csv");
    assert_eq!(parsed.header.len(), DATA_TABLE_MAX_COLUMNS);
    assert_eq!(parsed.total_columns, 3001);
    assert_eq!(parsed.rows.len(), 1);
}

#[test]
fn an_empty_file_has_no_table() {
    assert_eq!(parse_data_table("", "empty.csv", UTF8), None);
    assert_eq!(parse_data_table("\n\n", "empty.csv", UTF8), None);
}

#[test]
fn the_first_rows_are_kept_and_every_row_and_column_counted() {
    let mut lines = vec!["id,value".to_owned()];
    lines.extend((0..DATA_TABLE_MAX_ROWS + 500).map(|index| format!("{index},x")));
    // A row past the kept ones is wider than any kept row.
    lines.push("a,b,c".to_owned());
    let parsed = table(&lines.join("\n"), "big.csv");
    assert_eq!(parsed.rows.len(), DATA_TABLE_MAX_ROWS);
    assert_eq!(
        parsed.rows.last().unwrap(),
        &[(DATA_TABLE_MAX_ROWS - 1).to_string(), "x".to_owned()]
    );
    assert_eq!(parsed.total_rows, DATA_TABLE_MAX_ROWS + 501);
    assert_eq!(parsed.header, ["id", "value"]);
    assert_eq!(parsed.total_columns, 3);
}

#[test]
fn rows_stop_being_kept_at_the_first_that_overflows_the_text_budget() {
    // The kept rows stay a prefix of the file, though later rows still count.
    for (wide, path, delimiter) in [
        ("x".repeat(DATA_TABLE_MAX_CHARS), "wide.csv", ","),
        ("x".repeat(DATA_TABLE_MAX_CHARS * 2), "wide.csv", ","),
        ("x".repeat(DATA_TABLE_MAX_CHARS * 2), "wide.tsv", "\t"),
    ] {
        let text = format!(
            "col\nshort\n{}\nlater\n",
            [wide.as_str(), "y", "z"].join(delimiter)
        );
        let parsed = table(&text, path);
        assert_eq!(parsed.rows, strings(&[&["short"]]), "{path}");
        assert_eq!(parsed.total_rows, 3);
        assert_eq!(parsed.total_columns, 3);
    }
}

#[test]
fn an_oversized_header_stays_the_header_cut_at_the_budget() {
    let wide = "h".repeat(DATA_TABLE_MAX_CHARS + 1);
    let parsed = table(&format!("{wide},b\n1,2\n"), "wide.csv");
    let lengths: Vec<usize> = parsed.header.iter().map(String::len).collect();
    assert_eq!(lengths, [DATA_TABLE_MAX_CHARS, 0]);
    // The header spent the budget, so no row is kept, though every row is counted.
    assert_eq!(parsed.rows, Vec::<Vec<String>>::new());
    assert_eq!(parsed.total_rows, 1);
}

#[test]
fn each_column_has_an_inferred_type() {
    let parsed = table(
        "id,when,amount,label\n1,2026-01-02,\"1,234.5\",a\n2,2026-02-03T10:00:00Z,7%,b\n",
        "t.csv",
    );
    assert_eq!(
        parsed.column_types,
        [
            DataColumnType::Number,
            DataColumnType::Date,
            DataColumnType::Number,
            DataColumnType::Text,
        ]
    );
}

#[test]
fn the_delimiter_is_the_one_most_of_the_first_records_agree_on() {
    for (text, path, expected) in [
        ("a;b;c\n1;2;3\n", "x.csv", ';'),
        ("a|b\n1|2\n", "x.csv", '|'),
        ("a\tb\n1\t2\n", "x.csv", '\t'),
        ("a,b\n1,2\n", "x.tsv", '\t'),
        ("only\none\n", "x.csv", ','),
        ("a;b;c\n1;2;3\n4;5\n", "x.csv", ';'),
        // The commas sit inside quoted fields only.
        ("a;b\n\"1,5\";\"2,5\"\n\"3,1\";\"4,0\"\n", "eu.csv", ';'),
    ] {
        assert_eq!(detect_delimiter(text, path), expected, "{text:?}");
    }
}

#[test]
fn sniffing_reads_every_sampled_record_however_long_a_cell() {
    // The third record alone fills the table's text budget; the rest still count.
    let text = format!(
        "left,right;value\nhello,world;1\n{};2\n{}",
        "x".repeat(DATA_TABLE_MAX_CHARS),
        "y;3\n".repeat(17)
    );
    assert_eq!(detect_delimiter(&text, "report.csv"), ';');
    let parsed = table(&text, "report.csv");
    assert_eq!(parsed.header, ["left,right", "value"]);
    assert_eq!(parsed.rows.first().unwrap(), &["hello,world", "1"]);
}

#[test]
fn sniffing_reads_only_the_first_records() {
    let head: Vec<String> = (0..20).map(|index| format!("{index};x")).collect();
    let tail = vec!["a,b,c,d"; 100].join("\n");
    assert_eq!(
        detect_delimiter(&format!("{}\n{tail}", head.join("\n")), "x.csv"),
        ';'
    );
    // A row far wider than the column cap is still read.
    assert_eq!(
        detect_delimiter(&format!("{}\n", ";".repeat(1_000_000)), "x.csv"),
        ';'
    );
}

#[test]
fn files_decode_as_utf16_by_their_mark_else_utf8_else_windows_1252() {
    // "café" in Windows-1252: é is 0xE9, which is not valid UTF-8.
    assert_eq!(
        decode_data_file(&[0x63, 0x61, 0x66, 0xE9]),
        ("café".to_owned(), "windows-1252")
    );
    assert_eq!(
        decode_data_file(&[0x80, 0x9D]),
        ("\u{20ac}\u{9d}".to_owned(), "windows-1252")
    );
    assert_eq!(
        decode_data_file(&[0xFF, 0xFE, 0x61, 0x00, 0x2C, 0x00, 0x62, 0x00]),
        ("a,b".to_owned(), "utf-16le")
    );
    assert_eq!(
        decode_data_file(&[0xFE, 0xFF, 0x00, 0x61, 0x00, 0x2C, 0x00, 0x62]),
        ("a,b".to_owned(), "utf-16be")
    );
    assert_eq!(
        decode_data_file("\u{feff}naïve".as_bytes()),
        ("naïve".to_owned(), "utf-8")
    );
}

#[test]
fn a_read_data_file_becomes_a_table_in_its_own_encoding() {
    let content = |body: FileBody, truncated: bool| FileContent {
        path: WorkspacePath::parse("exports/people.csv").unwrap(),
        content_type: None,
        byte_count: 0,
        truncated,
        body,
    };
    let latin = file_data_table(&content(
        FileBody::Binary(b"name\ncaf\xE9\n".to_vec()),
        true,
    ))
    .unwrap();
    assert_eq!(latin.rows, strings(&[&["café"]]));
    assert_eq!(latin.encoding, "windows-1252");
    assert_eq!(
        latin.description, "windows-1252",
        "a non-UTF-8 encoding is named"
    );
    assert!(latin.truncated);
    let text = file_data_table(&content(FileBody::Text("\u{feff}a\n1\n".into()), false)).unwrap();
    assert_eq!(
        (text.header.as_slice(), text.encoding.as_str()),
        (&["a".to_owned()][..], UTF8)
    );
    assert_eq!(text.description, "");
    let mut other = content(FileBody::Text("a\n1\n".into()), false);
    other.path = WorkspacePath::parse("notes.txt").unwrap();
    assert_eq!(file_data_table(&other), None);
}

#[test]
fn column_types_follow_the_non_empty_cells() {
    for (values, expected) in [
        (&["1", "-2.5", "1e3", ""][..], DataColumnType::Number),
        (&["2026-01-02", "2026-12-31 08:30"], DataColumnType::Date),
        (&["1", "two"], DataColumnType::Text),
        (&["", " "], DataColumnType::Text),
        (&["2026-02-30"], DataColumnType::Text),
        (&["12,34"], DataColumnType::Text),
    ] {
        assert_eq!(
            infer_column_type(values.iter().copied()),
            expected,
            "{values:?}"
        );
    }
}

#[test]
fn numbers_order_by_value_and_empty_cells_last() {
    use DataColumnType::Number;
    assert_eq!(
        sorted(&["10", "", "2", "1,000"], Number),
        ["2", "10", "1,000", ""]
    );
    // A percentage is a fraction: 25% is less than a half.
    assert_eq!(
        sorted(&["1", "25%", "0.5", "150%"], Number),
        ["25%", "0.5", "1", "150%"]
    );
    // Integers past a float's precision keep their exact order, beside decimals too.
    assert_eq!(
        sorted(
            &[
                "9007199254740993",
                "-9007199254740992",
                "9,007,199,254,740,992",
                "9007199254740992.5",
                "-9007199254740993",
            ],
            Number
        ),
        [
            "-9007199254740993",
            "-9007199254740992",
            "9,007,199,254,740,992",
            "9007199254740992.5",
            "9007199254740993",
        ]
    );
    let equal = |a: &str, b: &str| compare_cells(a, b, Number);
    assert_eq!(
        equal("9.007199254740993e15", "9007199254740993"),
        Ordering::Equal
    );
    assert_eq!(
        equal("900719925474099300%", "9007199254740993"),
        Ordering::Equal
    );
    assert_eq!(equal("-0.0", "0"), Ordering::Equal);
    assert_eq!(
        sorted(
            &["0.5", "007", "1.50", ".05", "+1", "1e2%", "1e-400", "0"],
            Number
        ),
        ["0", "1e-400", ".05", "0.5", "+1", "1e2%", "1.50", "007"]
    );
    // A long run of zeros inside a cell still compares.
    let zeros = "0".repeat(200_000);
    assert_eq!(
        equal(&format!("1{zeros}2"), &format!("1{zeros}1")),
        Ordering::Greater
    );
    assert_eq!(equal("1e999", "1e999"), Ordering::Equal);
    assert_eq!(equal("2e999", "1e999"), Ordering::Greater);
    assert_eq!(equal("1e999", "-1e999"), Ordering::Greater);
    assert_eq!(equal("5", "1e999"), Ordering::Less);
}

#[test]
fn text_orders_naturally_and_dates_as_utc() {
    assert_eq!(
        sorted(&["item10", "item2", "Item1"], DataColumnType::Text),
        ["Item1", "item2", "item10"]
    );
    assert_eq!(
        compare_cells("Apple", "apple", DataColumnType::Text),
        Ordering::Equal
    );
    assert_eq!(
        sorted(
            &["2026-03-01", "", "2025-12-31T23:00:00Z", "2026-01-15"],
            DataColumnType::Date
        ),
        ["2025-12-31T23:00:00Z", "2026-01-15", "2026-03-01", ""]
    );
    // A date comes before a time later that day, whatever the viewer's time zone.
    assert_eq!(
        sorted(
            &[
                "2024-01-01 05:00",
                "2024-01-01",
                "2024-01-01T04:00:00+09:00"
            ],
            DataColumnType::Date
        ),
        [
            "2024-01-01T04:00:00+09:00",
            "2024-01-01",
            "2024-01-01 05:00"
        ]
    );
    assert_eq!(
        cell_date("2024-01-01T04:00:00.250+0900"),
        cell_date("2023-12-31T19:00:00.25Z")
    );
}

#[test]
fn ranks_share_equal_cells_and_leave_empty_ones_at_zero() {
    let parsed = table("n,t\n10,b\n,a\n2,B\n10,\n", "r.csv");
    assert_eq!(parsed.column_ranks(0), [2, 0, 1, 2]);
    assert_eq!(parsed.column_ranks(1), [2, 1, 2, 0]);
    assert_eq!(parsed.column_ranks(9), [0, 0, 0, 0]);
}

#[test]
fn workbooks_and_parquet_files_are_spreadsheets_by_extension() {
    for (path, expected) in [
        ("out/budget.xlsx", Some(SpreadsheetFormat::Xlsx)),
        ("DATA.PARQUET", Some(SpreadsheetFormat::Parquet)),
        ("old.xls", None),
        (".parquet", None),
        ("report.csv", None),
    ] {
        assert_eq!(spreadsheet_format(path), expected, "{path}");
    }
}

#[test]
fn records_become_a_table_with_labeled_names_and_inferred_types() {
    let parsed = table_from_records(
        strings(&[&["id", " ", "when"], &["1", "a", "2026-01-02"], &["2", "b"]]),
        5,
        2,
        "Parquet",
        false,
    )
    .unwrap();
    assert_eq!(parsed.header, ["id", "column 2", "when"]);
    assert_eq!(
        parsed.rows,
        strings(&[&["1", "a", "2026-01-02"], &["2", "b", ""]])
    );
    assert_eq!(
        parsed.column_types,
        [
            DataColumnType::Number,
            DataColumnType::Text,
            DataColumnType::Date
        ]
    );
    assert_eq!((parsed.total_rows, parsed.total_columns), (5, 3));
    assert_eq!(parsed.description, "Parquet");
    assert!(!parsed.text_cut);
    assert_eq!(table_from_records(Vec::new(), 0, 0, "", false), None);
}

#[test]
fn records_keep_a_prefix_within_the_text_budget_and_cut_long_names() {
    let long_name = "n".repeat(DATA_TABLE_MAX_NAME_CHARS + 5);
    let wide = "x".repeat(DATA_TABLE_MAX_CHARS);
    let parsed = table_from_records(
        vec![
            vec![long_name, "b".to_owned()],
            vec![wide.clone(), "after".to_owned()],
            vec!["later".to_owned(), "row".to_owned()],
        ],
        2,
        2,
        "Excel workbook",
        false,
    )
    .unwrap();
    assert_eq!(parsed.header[0].chars().count(), DATA_TABLE_MAX_NAME_CHARS);
    assert!(parsed.text_cut, "a cut name or row says so");
    // The oversized first row is kept, cut short with an ellipsis; nothing after it is.
    assert_eq!(parsed.rows.len(), 1);
    let first = &parsed.rows[0];
    assert!(first[0].ends_with('\u{2026}'));
    assert_eq!(
        first[0].chars().count(),
        DATA_TABLE_MAX_CHARS - DATA_TABLE_MAX_NAME_CHARS - 1
    );
    assert_eq!(first[1], "");
    // A row past the budget after a kept one ends the table there.
    let parsed = table_from_records(
        vec![vec!["h".to_owned()], vec!["short".to_owned()], vec![wide]],
        2,
        1,
        "",
        true,
    )
    .unwrap();
    assert_eq!(parsed.rows, strings(&[&["short"]]));
    assert!(parsed.text_cut, "a reader's own cut is kept");
}

#[test]
fn excel_phantom_leap_day_sorts_between_february_28_and_march_1() {
    assert_eq!(
        infer_column_type(["1900-02-29", "1900-03-01"]),
        DataColumnType::Date
    );
    assert_eq!(
        sorted(
            &[
                "1900-03-01",
                "1900-02-29 12:00:00",
                "1900-02-28",
                "1900-02-29"
            ],
            DataColumnType::Date
        ),
        [
            "1900-02-28",
            "1900-02-29",
            "1900-02-29 12:00:00",
            "1900-03-01"
        ]
    );
}
