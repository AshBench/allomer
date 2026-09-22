#!/usr/bin/env python3
"""Regenerate our small XLS test workbook. This tool is not part of the app."""

import datetime
import hashlib
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
wheel = ROOT / ".tools/tabular/fixture-generator/xlwt-1.3.0-py2.py3-none-any.whl"
wheel.parent.mkdir(parents=True, exist_ok=True)
if not wheel.exists():
    urllib.request.urlretrieve("https://files.pythonhosted.org/packages/44/48/def306413b25c3d01753603b1a222a011b8621aed27cd7f89cbc27e6b0f4/xlwt-1.3.0-py2.py3-none-any.whl", wheel)
assert hashlib.sha256(wheel.read_bytes()).hexdigest() == "a082260524678ba48a297d922cc385f58278b8aa68741596a87de01a9c628b2e"
sys.path.insert(0, str(wheel))
import xlwt

workbook = xlwt.Workbook()
first = workbook.add_sheet("Values")
for row, values in enumerate([["Name", "Code", "Value"], ["Café 東京", "00123", True],
                               ["line\none", "=SUM(A1:A2)", 12.5]]):
    for column, value in enumerate(values):
        first.write(row, column, value)
second = workbook.add_sheet("Offset")
second.write(2, 1, "offset")
second.write(3, 2, datetime.datetime(2024, 2, 29, 12, 34, 56), xlwt.easyxf(num_format_str="yyyy-mm-dd hh:mm:ss"))
output = ROOT / "Tests/Fixtures/sheet-values.xls"
output.parent.mkdir(exist_ok=True)
workbook.save(str(output))
print(output)
