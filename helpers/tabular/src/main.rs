use calamine::{Data, DataRef, DataType, Reader, Xls, Xlsx};
use rust_xlsxwriter::{Format, Workbook};
use std::collections::HashSet;
use std::error::Error;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};
use std::path::Path;
#[path = "../../bounded_heap.rs"]
mod bounded_heap;

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const HEAP_LIMIT: usize = 256 * 1024 * 1024;
const INPUT_LIMIT: u64 = 64 * 1024 * 1024;
const EXPANDED_LIMIT: u64 = 256 * 1024 * 1024;
const CELL_LIMIT: u64 = 10_000_000;
const ROW_LIMIT: u32 = 1_048_576;
const COLUMN_LIMIT: u32 = 16_384;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() == 2 && args[1] == "--version" {
        println!("tabular 0.1.0");
        return Ok(());
    }
    if args.len() != 7 {
        return Err("Usage: tabular INPUT OUTPUT FROM TO SHEET_INDEX CSV_DELIMITER_CODE".into());
    }
    let text = |index: usize| args[index].to_str().ok_or("Invalid argument text");
    let input = Path::new(&args[1]);
    let output = Path::new(&args[2]);
    let from = text(3)?;
    let to = text(4)?;
    let sheet = text(5)?.parse::<usize>()?;
    let delimiter = text(6)?.parse::<u8>()?;
    if ![b',', b';', b'\t', b'|'].contains(&delimiter) {
        return Err("Invalid spreadsheet delimiter.".into());
    }
    if !["csv", "tsv", "xls", "xlsx", "rows"].contains(&from) || !["csv", "tsv", "xlsx", "rows"].contains(&to) {
        return Err("Unsupported spreadsheet conversion.".into());
    }
    let metadata = std::fs::symlink_metadata(input)?;
    if !metadata.is_file() || metadata.len() > INPUT_LIMIT {
        return Err("Spreadsheet inputs must be regular files no larger than 64 MiB.".into());
    }
    let destination = OpenOptions::new().write(true).create_new(true).open(output)?;
    let result = convert(input, destination, from, to, sheet, delimiter, output);
    if result.is_err() { let _ = std::fs::remove_file(output); }
    result
}

fn csv_reader(path: &Path, delimiter: u8) -> Result<csv::Reader<File>> {
    let mut file = BufReader::new(File::open(path)?);
    if file.fill_buf()?.starts_with(b"\xef\xbb\xbf") { file.consume(3); }
    // The CSV library accepts incomplete quotes. Reject those before normalizing the data.
    let mut state = 0;
    loop {
        let bytes = file.fill_buf()?;
        if bytes.is_empty() { break; }
        for &byte in bytes {
            state = match (state, byte) {
                (0, b'"') => 2,
                (2, b'"') => 3,
                (2, _) => 2,
                (3, b'"') => 2,
                (_, value) if value == delimiter || value == b'\r' || value == b'\n' => 0,
                (3, _) | (1, b'"') => return Err("The CSV file has invalid quoting.".into()),
                _ => 1,
            };
        }
        let length = bytes.len();
        file.consume(length);
    }
    if state == 2 { return Err("The CSV file ends inside a quoted field.".into()); }
    Ok(csv::ReaderBuilder::new().has_headers(false).flexible(true).delimiter(delimiter).from_path(path)?)
}

fn convert(input: &Path, destination: File, from: &str, to: &str, sheet: usize,
           delimiter: u8, output: &Path) -> Result<()> {
    let parent = output.parent().ok_or("Missing output directory")?;
    let expected = tempfile::NamedTempFile::new_in(parent)?;
    let mut record_writer = csv::WriterBuilder::new().flexible(true).from_writer(expected.reopen()?);
    let mut count = 0u64;
    let mut cell_count = 0u64;
    let mut byte_count = 0u64;
    let mut remember = |row: &[String]| -> Result<()> {
        count += 1;
        cell_count += row.len() as u64;
        byte_count += row.iter().map(|value| value.len() as u64).sum::<u64>();
        if count > ROW_LIMIT as u64 || row.len() > COLUMN_LIMIT as usize || cell_count > CELL_LIMIT
            || byte_count > EXPANDED_LIMIT {
            return Err("The spreadsheet exceeds its row, column, cell, or expanded text limit.".into());
        }
        record_writer.write_record(row)?;
        Ok(())
    };
    if to == "xlsx" {
        let mut width = 0;
        if ["csv", "tsv", "rows"].contains(&from) {
            rows(input, from, sheet, delimiter, &mut |row| {
                width = width.max(row.len());
                if width > COLUMN_LIMIT as usize { return Err("Too many spreadsheet columns.".into()); }
                Ok(())
            })?;
        }
        let mut workbook = Workbook::new();
        workbook.set_tempdir(parent)?;
        let worksheet = workbook.add_worksheet_with_constant_memory();
        let blank = Format::new().set_num_format("@");
        let mut index = 0;
        rows(input, from, sheet, delimiter, &mut |values| {
            let mut values = values.to_vec();
            values.resize(values.len().max(width), String::new());
            remember(&values)?;
            for (column, value) in values.iter().enumerate() {
                if value.is_empty() { worksheet.write_blank(index, column as u16, &blank)?; }
                else { worksheet.write_string(index, column as u16, value)?; }
            }
            index += 1;
            Ok(())
        })?;
        workbook.save_to_writer(destination)?;
    } else if to == "rows" {
        let mut writer = BufWriter::new(destination);
        writer.write_all(b"[")?;
        let mut first = true;
        rows(input, from, sheet, delimiter, &mut |row| {
            remember(row)?;
            if !first { writer.write_all(b",")?; }
            first = false;
            serde_json::to_writer(&mut writer, row)?;
            Ok(())
        })?;
        writer.write_all(b"]")?;
        writer.flush()?;
    } else {
        let mut writer = csv::WriterBuilder::new().flexible(true)
            .delimiter(if to == "tsv" { b'\t' } else { delimiter }).from_writer(destination);
        rows(input, from, sheet, delimiter, &mut |row| {
            remember(row)?;
            writer.write_record(row)?;
            Ok(())
        })?;
        writer.flush()?;
    }
    record_writer.flush()?;
    let mut expected_reader = csv_reader(expected.path(), b',')?;
    let mut records = expected_reader.records();
    rows(output, to, 0, delimiter, &mut |actual| {
        let expected = records.next().ok_or("The spreadsheet output added a row.")??;
        if !expected.iter().eq(actual.iter().map(String::as_str)) {
            return Err("The spreadsheet output changed a cell value or position.".into());
        }
        Ok(())
    })?;
    if records.next().is_some() { return Err("The spreadsheet output lost a row.".into()); }
    Ok(())
}

fn rows(path: &Path, format: &str, sheet: usize, delimiter: u8,
        emit: &mut dyn FnMut(&[String]) -> Result<()>) -> Result<()> {
    match format {
        "rows" => {
            let values: Vec<Vec<String>> = serde_json::from_reader(BufReader::new(File::open(path)?))?;
            for row in values { emit(&row)?; }
        }
        "csv" | "tsv" => {
            for record in csv_reader(path, if format == "tsv" { b'\t' } else { delimiter })?.records() {
                emit(&record?.iter().map(str::to_owned).collect::<Vec<_>>())?;
            }
        }
        "xlsx" => xlsx_rows(path, sheet, emit)?,
        "xls" => {
            let mut workbook = Xls::new(BufReader::new(File::open(path)?))?;
            let name = workbook.sheet_names().get(sheet).ok_or("The selected sheet does not exist.")?.clone();
            let range = workbook.worksheet_range(&name)?;
            let formulas = workbook.worksheet_formula(&name)?;
            if let Some((last_row, last_column)) = range.end() {
                check_dimensions(last_row, last_column)?;
                for row in 0..=last_row {
                    let mut values = Vec::with_capacity(last_column as usize + 1);
                    for column in 0..=last_column {
                        let value = range.get_value((row, column)).unwrap_or(&Data::Empty);
                        if value.is_empty() && formulas.get_value((row, column)).is_some_and(|v| !v.is_empty()) {
                            return Err("A formula has no saved result. Recalculate and save the workbook first.".into());
                        }
                        values.push(cell_text(value)?);
                    }
                    emit(&values)?;
                }
            }
        }
        _ => return Err("Unknown spreadsheet format.".into()),
    }
    Ok(())
}

fn check_dimensions(row: u32, column: u32) -> Result<()> {
    if row >= ROW_LIMIT || column >= COLUMN_LIMIT || (row as u64 + 1) * (column as u64 + 1) > CELL_LIMIT {
        return Err("The sheet exceeds 1,048,576 rows, 16,384 columns, or 10 million cells.".into());
    }
    Ok(())
}

fn check_zip(path: &Path) -> Result<()> {
    let mut archive = zip::ZipArchive::new(File::open(path)?)?;
    if archive.len() > 10_000 { return Err("The workbook has too many archive entries.".into()); }
    let mut total = 0;
    let mut names = HashSet::new();
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        if !names.insert(entry.name().to_owned()) { return Err("The workbook has duplicate archive entries.".into()); }
        if entry.encrypted() || entry.size() > EXPANDED_LIMIT - total {
            return Err("The workbook is encrypted or expands beyond 256 MiB.".into());
        }
        let expected = entry.size();
        let xml = entry.name().ends_with(".xml") || entry.name().ends_with(".rels");
        let limit = EXPANDED_LIMIT - total + 1;
        let mut limited = entry.by_ref().take(limit);
        if xml { check_xml(&mut limited)?; }
        else { io::copy(&mut limited, &mut io::sink())?; }
        let actual = limit - limited.limit();
        if actual != expected { return Err("A workbook archive entry has an invalid size.".into()); }
        total += actual;
    }
    Ok(())
}

fn check_xml(input: &mut impl Read) -> Result<()> {
    use quick_xml::events::Event;
    let mut reader = quick_xml::Reader::from_reader(BufReader::new(input));
    let mut buffer = Vec::new();
    let mut depth = 0u32;
    let mut roots = 0;
    loop {
        match reader.read_event_into(&mut buffer)? {
            Event::Start(_) => {
                if depth == 0 { roots += 1; }
                depth += 1;
                if depth > 64 { return Err("Workbook XML exceeds the nesting limit.".into()); }
            }
            Event::End(_) => depth = depth.checked_sub(1).ok_or("Unbalanced workbook XML")?,
            Event::Empty(_) if depth == 0 => roots += 1,
            Event::DocType(_) => return Err("Workbook XML document type declarations are unsupported.".into()),
            Event::Text(text) if depth == 0 && !text.decode()?.trim().is_empty() => {
                return Err("Unexpected text outside the workbook XML root.".into());
            }
            Event::CData(_) | Event::GeneralRef(_) if depth == 0 => return Err("Invalid workbook XML content.".into()),
            Event::Eof => break,
            _ => (),
        }
        buffer.clear();
    }
    if roots != 1 || depth != 0 { return Err("Workbook XML must have one complete root element.".into()); }
    Ok(())
}

fn xlsx_rows(path: &Path, sheet: usize, emit: &mut dyn FnMut(&[String]) -> Result<()>) -> Result<()> {
    check_zip(path)?;
    let mut workbook = Xlsx::new(BufReader::new(File::open(path)?))?;
    let name = workbook.sheet_names().get(sheet).ok_or("The selected sheet does not exist.")?.clone();
    let mut end: Option<(u32, u32)> = None;
    let mut reader = workbook.worksheet_cells_reader(&name)?;
    let mut previous = None;
    while let Some(cell) = reader.next_cell_with_formula_metadata()? {
        if previous.is_some_and(|pos| pos >= cell.pos) {
            return Err("Worksheet cells must have unique positions in row order.".into());
        }
        previous = Some(cell.pos);
        if cell.formula.is_some() && matches!(cell.value, DataRef::Empty) {
            return Err("A formula has no saved result. Recalculate and save the workbook first.".into());
        }
        let (row, column) = end.unwrap_or((0, 0));
        let extent = (row.max(cell.pos.0), column.max(cell.pos.1));
        check_dimensions(extent.0, extent.1)?;
        end = Some(extent);
    }
    drop(reader);
    let Some((last_row, last_column)) = end else { return Ok(()); };
    let mut reader = workbook.worksheet_cells_reader(&name)?;
    let mut cell = reader.next_cell()?;
    for row in 0..=last_row {
        let mut values = vec![String::new(); last_column as usize + 1];
        while let Some(current) = &cell {
            let position = current.get_position();
            if position.0 != row { break; }
            values[position.1 as usize] = cell_text(current.get_value())?;
            cell = reader.next_cell()?;
        }
        emit(&values)?;
    }
    Ok(())
}

fn cell_text(value: &impl DataType) -> Result<String> {
    if let Some(text) = value.get_string() { return Ok(text.to_owned()); }
    if let Some(number) = value.get_int() { return Ok(number.to_string()); }
    if let Some(number) = value.get_float() {
        if !number.is_finite() { return Err("A cell contains a non-finite number.".into()); }
        return Ok(number.to_string());
    }
    if let Some(boolean) = value.get_bool() { return Ok(boolean.to_string()); }
    if let Some(date) = value.get_datetime() {
        if date.is_duration() {
            let milliseconds = date.as_duration().ok_or("Invalid cell duration")?.num_milliseconds();
            let seconds = milliseconds as f64 / 1000.0;
            return Ok(format!("{}PT{}S", if seconds < 0.0 { "-" } else { "" }, seconds.abs()));
        }
        let (year, month, day, hour, minute, second, milliseconds) = date.to_ymd_hms_milli();
        return Ok(format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{milliseconds:03}"));
    }
    if let Some(text) = value.get_datetime_iso().or_else(|| value.get_duration_iso()) { return Ok(text.to_owned()); }
    if let Some(error) = value.get_error() { return Ok(error.to_string()); }
    if value.is_empty() { return Ok(String::new()); }
    Err("The spreadsheet contains an unsupported cell value.".into())
}
