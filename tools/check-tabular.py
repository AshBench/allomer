#!/usr/bin/env python3
"""Check spreadsheet values with independent CSV and XLSX readers."""

import csv
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / ".tools/tabular/bin/tabular"
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def main():
    with tempfile.TemporaryDirectory(prefix="tabular-check-") as temporary:
        work = Path(temporary)
        sequence = 0
        def run(source, to, sheet=0, delimiter=44, succeeds=True):
            nonlocal sequence
            sequence += 1
            output = work / f"output-{sequence}.{to}"
            result = subprocess.run([TOOL, source, output, source.suffix[1:], to, str(sheet), str(delimiter)],
                cwd=work, env={"PATH": "/usr/bin:/bin", "TMPDIR": str(work)}, capture_output=True, text=True, timeout=30)
            assert (result.returncode == 0) == succeeds, f"{source.name} -> {to}: {result.stderr}"
            if not succeeds:
                assert not output.exists()
            return output
        def read(path, delimiter=","):
            with path.open(newline="") as stream:
                return list(csv.reader(stream, delimiter=delimiter))
        values = [["Name", "Code", "Text", ""], ["Café 東京", "00123", "=SUM(A1:A2)", "true"],
                  ["line\none", "a\tb,c", 'He said "hello"', ""], ["", "", "", ""]]
        source = work / "source.csv"
        with source.open("w", newline="") as stream:
            csv.writer(stream).writerows(values)
        for to in ("csv", "tsv", "xlsx"):
            output = run(source, to)
            if to == "xlsx":
                with zipfile.ZipFile(output) as archive:
                    sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
                    assert not sheet.findall(f".//{NS}f"), "Text became a formula"
                    row = sheet.find(f"{NS}sheetData/{NS}row[@r='2']")
                    assert [node.text for node in row.findall(f".//{NS}t")] == values[1]
            restored = run(output, "csv")
            assert read(restored) == values, read(restored)
        for text, expected in [("", []), ('""\n', [[""]]), ("a,b\nc\n", [["a", "b"], ["c", ""]])]:
            source.write_text(text)
            restored = run(run(source, "xlsx"), "csv")
            assert read(restored) == expected, read(restored)
        source.write_text('name;value\n"Café;東京";00123\n')
        assert read(run(source, "tsv", delimiter=59), "\t") == [["name", "value"], ["Café;東京", "00123"]]
        legacy = ROOT / "Tests/Fixtures/sheet-values.xls"
        assert read(run(legacy, "csv")) == [["Name", "Code", "Value"], ["Café 東京", "00123", "true"],
            ["line\none", "=SUM(A1:A2)", "12.5"]]
        assert read(run(legacy, "csv", sheet=1)) == [["", "", ""], ["", "", ""], ["", "offset", ""],
            ["", "", "2024-02-29T12:34:56.000"]]
        run(legacy, "csv", sheet=2, succeeds=False)
        source.write_text("a,b\n1,2\n")
        workbook = run(source, "xlsx")
        with zipfile.ZipFile(workbook) as archive:
            parts = {name: archive.read(name) for name in archive.namelist()}
        def changed(name, xml):
            file = work / f"{name}.xlsx"
            with zipfile.ZipFile(file, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for key, value in parts.items():
                    archive.writestr(key, xml if key == "xl/worksheets/sheet1.xml" else value)
            return file
        def worksheet(data):
            return f'<worksheet xmlns="{NS[1:-1]}"><sheetData>{data}</sheetData></worksheet>'
        sparse = changed("sparse", worksheet('<row r="3"><c r="B3" t="inlineStr"><is><t>offset</t></is></c></row>'))
        assert read(run(sparse, "csv")) == [["", ""], ["", ""], ["", "offset"]]
        formula = changed("formula", worksheet('<row r="1"><c r="A1"><f>1+1</f><v>2</v></c></row>'))
        assert read(run(formula, "csv")) == [["2"]]
        uncached = changed("uncached", worksheet('<row r="1"><c r="A1"><f>1+1</f></c></row>'))
        run(uncached, "csv", succeeds=False)
        malformed = changed("malformed", worksheet('<row r="1"><c r="A1"><v>2</wrong></c></row>'))
        run(malformed, "csv", succeeds=False)
        dtd = changed("dtd", '<!DOCTYPE worksheet []>' + worksheet('<row r="1"><c r="A1"><v>2</v></c></row>'))
        run(dtd, "csv", succeeds=False)
        duplicate = changed("duplicate", worksheet('<row r="1"><c r="A1"><v>1</v></c><c r="A1"><v>2</v></c></row>'))
        run(duplicate, "csv", succeeds=False)
        huge = changed("huge", worksheet('<row r="1048576"><c r="XFD1048576"><v>1</v></c></row>'))
        run(huge, "csv", succeeds=False)
        broken = work / "broken.xlsx"
        broken.write_bytes(b"not a workbook")
        run(broken, "csv", succeeds=False)
        source.write_bytes(b'a,b\n\xff,1\n')
        run(source, "tsv", succeeds=False)
        for text in ['a,"unclosed', 'a,un"quoted', 'a,"closed"tail']:
            source.write_text(text)
            run(source, "tsv", succeeds=False)
        before = workbook.read_bytes()
        result = subprocess.run([TOOL, legacy, workbook, "xls", "xlsx", "0", "44"], capture_output=True)
        assert result.returncode and workbook.read_bytes() == before
    print("Spreadsheet values, text types, blank cells, offsets, sheet selection, and failure checks passed.")


if __name__ == "__main__":
    main()
