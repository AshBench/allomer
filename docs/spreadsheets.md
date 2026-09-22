---
sidebar_position: 5
---

# Spreadsheet conversion

The app reads CSV, TSV, XLS, and XLSX. It writes CSV, TSV, and XLSX. It also converts JSON and simple XML tables. XLS is an input format only. Workbook exports use one selected sheet.

Change an extension in a watched folder or use the Manual tab. Both paths use the spreadsheet settings. The app bundles the reader and writer. End users do not need Excel, Python, Rust, or a network connection.

## Settings

**CSV delimiter** selects a comma, semicolon, tab, or pipe. It applies when reading or writing CSV. TSV always uses tabs.

**Workbook sheet number** selects the sheet to export. The first sheet is 1. A missing sheet produces an error. CSV and TSV keep every data row. They do not discard the first row as a header.

**Use the first row as JSON column names** controls JSON record output. On, the first row supplies the property names. Off, columns are named `column1`, `column2`, and so on by position, and every row becomes a record. It does not affect CSV, TSV, or workbook output, which always keep every row.

**Include column headers when reading XML tables** controls the first output row for XML table exports.

**Infer table numbers and booleans** converts exact numeric and boolean text when producing JSON records. It also normalizes those values when reading XML tables. It leaves leading-zero codes as text. It does not turn CSV text into XLSX formulas or numeric cells.

## JSON and XML tables

CSV, TSV, or a selected workbook sheet can become a JSON array of records. The first row supplies the property names unless that setting is turned off, in which case columns are named by position and no row is consumed. Headers must be unique and nonempty. Every later row must have the same number of fields. Empty input becomes an empty array. A header without data rows also becomes an empty array. JSON output uses the configuration setting for pretty printing.

JSON table input accepts an object, an array of objects, or an array of row arrays. Object property names become columns in sorted order. Missing properties and null values become empty fields. Nested objects and arrays become compact JSON text within a cell. CSV has no native type information, so a return conversion does not recover every original JSON type automatically.

XML tables use a root container with repeated row elements. Each row can have attributes and simple child fields. Attribute columns start with `@`. Child columns keep their element names. Columns follow their first occurrence. Missing fields become empty cells. Comments and processing instructions do not become cells. Nested fields, duplicate fields, non-whitespace text between fields, and mixed row element names produce an error. DTDs and external entities are rejected by the shared XML reader.

JSON and XML table data currently have a 16 MiB input/intermediate limit and the shared 250,000-value configuration limit. Expanding sparse records into columns is checked before allocating the rectangular table. XML header and inference settings also apply to automatic conversions.

## Values and limits

CSV text stays text in XLSX. Leading zeros, quoted booleans, and text that starts with `=` remain strings. The converter does not create formulas from text. Blank cells have a text format so Excel does not discard trailing blank rows or columns.

Workbook export writes saved cell values. It does not calculate formulas. A formula without a detectable saved result produces an error. Dates use an ISO date and time with milliseconds. Durations use ISO duration text. Number formats, colors, charts, macros, merged-cell presentation, and other workbook layout are not carried into CSV or TSV. Other sheets remain in the recoverable original.

Rows retain their positions from the top left of the sheet. Sparse sheets include leading empty rows and columns. CSV rows with different lengths gain trailing empty cells when written to XLSX. Empty physical lines in CSV are ignored. A quoted empty field is retained as a row.

Inputs must be valid UTF-8 CSV/TSV or supported workbook files. A UTF-8 byte order mark is accepted. Invalid quotes and invalid UTF-8 are rejected. Encrypted workbooks are not supported.

The current limits are 64 MiB per input, 256 MiB of expanded workbook data, 10 million cells, 1,048,576 rows, and 16,384 columns. XLSX cells have Excel's 32,767-character text limit. Sparse dimensions count toward the cell limit. The helper has a 256 MiB Rust heap limit. This limit is separate from total process memory. Inputs that exceed it can terminate the helper; the app keeps the original and removes the temporary output.

XLSX reads and writes rows in sequence. The writer uses temporary disk space instead of retaining the whole worksheet. Shared strings still require memory when reading a workbook. The older XLS reader can hold full sheets in memory. Every output is read again and compared with a temporary record of the converted rows before publication. XLSX ZIP entries receive size and checksum checks.

## Development checks

Build the helper on an Apple Silicon Mac:

```sh
python3 tools/setup-rust.py
python3 tools/build-rust.py tabular
python3 tools/check-tabular.py
swift test
```

The compiler is installed under `.tools/`. Shell profiles and the user's default compiler do not change. Rust 1.98.1 and dependency versions are pinned. The helper targets ARM64 and macOS 14. The build retains dependency notices and the Rust standard library notices for the app bundle.

The independent check uses Python's CSV and XML readers. It covers text values, blanks, offsets, saved formulas, selected sheets, malformed inputs, and overwrite refusal. Swift tests also check automatic replacement and Undo. The original XLS fixture can be regenerated with `python3 tools/make-xls-fixture.py`. That development tool downloads a checksum-pinned xlwt wheel. Neither xlwt nor Python is included in the app.

After packaging, `python3 tools/check-spreadsheet-performance.py` measures a generated 100,000-row CSV-to-XLSX workload. It includes the helper's output validation and checks every restored cell. Results are recorded in `research/spreadsheet-performance.json`. This measures the helper process, not the native app's separate memory use.

On the development Mac, the checked helper converted the 5,127,809-byte fixture in a median 0.79 seconds with 4,358,144 bytes peak RSS. The report records the exact binary hash, system version, and all three samples. It includes workbook XML validation. This small text workload does not predict the memory cost of large shared-string tables or legacy XLS files.

The remaining spreadsheet engine options and complete input fidelity still need work. Format availability does not establish full option parity.
