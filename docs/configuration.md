---
sidebar_position: 2
---

# Configuration files

The current adapter converts JSON, YAML, TOML, plist, and XML. It runs inside the native app. It needs no helper download or network connection.

The generated shared fixture passes all 25 input and output pairs. This covers nested objects, arrays, empty objects, Unicode, quoted numbers, booleans, and signed 64-bit integer limits. The automatic replacement and Undo check restores the exact source bytes.

## Settings

Pretty printing controls JSON, YAML, and generated configuration XML layout. TOML keeps one assignment per line. Plist uses Apple's standard layout or binary encoding.

YAML uses indented blocks when pretty printing is on. When it is off, objects use braces and arrays use brackets, including nested values. Long output can still wrap across lines. Both forms keep the same parsed values.

Type inference is off by default. When enabled, it converts the strings `true` and `false` to booleans. It also converts canonical integer strings and decimal strings that retain their value. A string such as `00123` remains text. Object keys remain strings.

Binary plist output is optional. Both XML and binary plist inputs are accepted.

## Value limits

Output is decoded again and compared with the parsed source before saving. A failed comparison keeps the source unchanged. Formatting, comments in configuration syntax, and key order are not retained.

| Value | Current behavior |
| --- | --- |
| Strings, booleans, arrays, objects | Supported across all five formats. TOML requires an object at the root. |
| Integers | Signed 64-bit values work across all five formats. Unsigned 64-bit values work except in TOML. Larger integers are rejected. |
| Decimal numbers | Finite 64-bit floating-point values. JSON and YAML decimal spellings that would change on output are rejected. |
| Null | JSON, YAML, and generated configuration XML support it. TOML and plist reject it. |
| Plist binary data and dates | Kept as typed values. JSON and the current TOML path reject them. YAML and generated configuration XML can represent them, subject to the output comparison. |
| TOML dates and times | Not yet mapped to other formats. Conversion returns an error. |
| YAML aliases and merges | Bounded aliases and ordinary merge keys are supported. Recursive aliases, complex keys, custom tags, and multiple documents are rejected. |

Configuration input is limited to 16 MiB. Expanded output is limited to 64 MiB. Parsers also limit nesting and node counts. These limits can reject a valid but unusually large file. The app reports the error before replacing its contents.

## XML mapping

XML has attributes and ordered mixed text. A simple object cannot represent those directly. Ordinary XML therefore converts to an explicit tree under the reserved `$xml` key:

```json
{
  "$xml": [{
    "name": "message",
    "attributes": {"language": "en"},
    "children": [{"text": "Hello"}]
  }]
}
```

Elements, attributes, namespace declarations, text order, comments, and processing instructions are retained in this tree. Converting the tree back to XML restores those values. CDATA becomes equivalent text. Attribute order and the XML declaration's original spelling can change.

Other configuration objects produce typed XML in the `urn:ashbench:allomer:config:1` namespace. This keeps numbers, strings, booleans, arrays, and null distinct. It does not claim to follow an application's existing XML schema.

The adapter accepts UTF-8 and UTF-16 XML, plus UTF-32 with a byte-order mark. It rejects document type declarations and entity declarations. External entities are never fetched.

These checks cover basic value conversion. Complete format and option parity remains in progress.

## Measured workload

Run `python3 tools/check-config-performance.py` after packaging the app. It converts a generated 10,000-object JSON file to TOML three times. Each output is converted back and compared with the original values.

On this development Mac, the 902,791-byte fixture took a median 0.44 seconds and peaked at 51,478,528 bytes of resident memory. The first version took 1.17 seconds and peaked at 384,647,168 bytes. Both measurements include command startup. Results are in `research/config-performance.json` and `research/config-performance-before.json`.

The improvement came from reading parser events directly and releasing temporary Foundation objects after quoting each string. This is one generated workload, not a limit for all configuration files.
