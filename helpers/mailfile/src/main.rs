use base64::Engine;
use mail_builder::{MessageBuilder, mime::MimePart};
use mail_parser::{Encoding, MessageParser, MimeHeaders, PartType};
use std::borrow::Cow;
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

#[path = "../../bounded_heap.rs"]
mod bounded_heap;
mod msg;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const HEAP_LIMIT: usize = 256 * 1024 * 1024;
const INPUT_LIMIT: usize = 64 * 1024 * 1024;
const OUTPUT_LIMIT: usize = 128 * 1024 * 1024;

struct LimitedWriter<W> { inner: W, remaining: usize }
impl<W: Write> Write for LimitedWriter<W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > self.remaining { return Err(std::io::Error::other("The email output exceeds 128 MiB.")); }
        let written = self.inner.write(bytes)?;
        self.remaining -= written;
        Ok(written)
    }
    fn flush(&mut self) -> std::io::Result<()> { self.inner.flush() }
}

#[derive(Default)]
struct Mail {
    headers: Vec<(String, String)>,
    text: String,
    html: String,
    rtf: Vec<u8>,
    attachments: Vec<Attachment>,
}

struct Attachment {
    name: String,
    mime: String,
    cid: String,
    location: String,
    inline: bool,
    data: Vec<u8>,
    message: Option<Box<Mail>>,
}

fn main() {
    if let Err(error) = run() { eprintln!("{error}"); std::process::exit(1); }
}

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() == 2 && args[1] == "--version" { println!("mailfile 0.1.0"); return Ok(()); }
    if args.len() != 6 { return Err("Usage: mailfile INPUT OUTPUT FROM TO INCLUDE_HEADERS".into()); }
    let from = args[3].to_str().ok_or("Invalid source format.")?;
    let to = args[4].to_str().ok_or("Invalid target format.")?;
    let include_headers = match args[5].to_str() {
        Some("true") => true, Some("false") => false, _ => return Err("Invalid header option.".into()),
    };
    if !matches!((from, to), ("eml", "emlx" | "msg" | "html") | ("emlx" | "msg", "eml")) {
        return Err("Unsupported email conversion.".into());
    }
    let input = Path::new(&args[1]);
    let output = Path::new(&args[2]);
    let metadata = std::fs::symlink_metadata(input)?;
    if !metadata.is_file() || metadata.len() as usize > INPUT_LIMIT {
        return Err("Email inputs must be regular files no larger than 64 MiB.".into());
    }
    let mut bytes = Vec::new();
    File::open(input)?.take(INPUT_LIMIT as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > INPUT_LIMIT { return Err("The email grew beyond its size limit.".into()); }
    let destination = OpenOptions::new().read(true).write(true).create_new(true).open(output)?;
    let result = (|| {
        if from == "msg" {
            write_eml(&msg::read(&bytes)?, LimitedWriter { inner: destination, remaining: OUTPUT_LIMIT })?;
        } else {
            let eml = if from == "emlx" { emlx_body(&bytes)? } else { &bytes };
            let header = MessageParser::default().parse_headers(eml).ok_or("Invalid email headers.")?;
            if header.headers().is_empty() { return Err("The file has no email headers.".into()); }
            match to {
                "eml" => { let mut file = destination; file.write_all(eml)?; }
                "emlx" => {
                    let mut file = destination;
                    writeln!(file, "{}", eml.len())?;
                    file.write_all(eml)?;
                    file.write_all(b"\n<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>flags</key><integer>0</integer></dict></plist>\n")?;
                }
                "msg" => msg::write(&parse_eml(eml, 0)?, destination)?,
                "html" => write_html(&parse_eml(eml, 0)?, LimitedWriter { inner: destination, remaining: OUTPUT_LIMIT }, include_headers)?,
                _ => unreachable!(),
            }
        }
        if std::fs::metadata(output)?.len() as usize > OUTPUT_LIMIT { return Err("The email output exceeds 128 MiB.".into()); }
        Ok(())
    })();
    if result.is_err() { let _ = std::fs::remove_file(output); }
    result
}

fn emlx_body(bytes: &[u8]) -> Result<&[u8]> {
    let end = bytes.iter().take(21).position(|&b| b == b'\n').ok_or("Invalid EMLX byte count.")?;
    let count = bytes[..end].strip_suffix(b"\r").unwrap_or(&bytes[..end]);
    if count.is_empty() || !count.iter().all(u8::is_ascii_digit) { return Err("Invalid EMLX byte count.".into()); }
    let length = std::str::from_utf8(count)?.parse::<usize>()?;
    let end_body = (end + 1).checked_add(length).ok_or("Invalid EMLX length.")?;
    bytes.get(end + 1..end_body).ok_or("The EMLX message is truncated.".into())
}

fn parse_eml(bytes: &[u8], depth: usize) -> Result<Mail> {
    if depth > 16 { return Err("Email nesting exceeds 16 messages.".into()); }
    let parsed = MessageParser::default().parse(bytes).ok_or("The file is not an email message.")?;
    if parsed.headers().is_empty() || parsed.parts.len() > 4096 || parsed.attachments.len() > 1000
        || parsed.parts.iter().any(|p| p.is_encoding_problem) {
        return Err("The email has invalid encoding or too many message parts.".into());
    }
    if parsed.is_content_type("multipart", "signed") || parsed.is_content_type("multipart", "encrypted")
        || parsed.is_content_type("application", "pkcs7-mime") {
        return Err("Signed or encrypted MIME messages require their original MIME structure.".into());
    }
    let headers = parse_headers(bytes.get(..parsed.root_part().offset_body as usize)
        .ok_or("Invalid email header length.")?)?;
    let mut mail = Mail { headers, ..Default::default() };
    let body_rtf = |part: &mail_parser::MessagePart<'_>| part.is_content_type("text", "rtf")
        && !part.content_disposition().is_some_and(|d| d.c_type.eq_ignore_ascii_case("attachment"));
    for part in parsed.parts.iter().filter(|p| body_rtf(p)) {
        if !mail.rtf.is_empty() { return Err("The email contains multiple RTF bodies.".into()); }
        mail.rtf = part_bytes(bytes, part)?;
        if mail.rtf.len() > 8 * 1024 * 1024 { return Err("The RTF body exceeds 8 MiB.".into()); }
    }
    for part in parsed.text_bodies() {
        if body_rtf(part) { continue; }
        if let PartType::Text(text) = &part.body {
            if !mail.text.is_empty() { mail.text.push('\n'); }
            mail.text.push_str(text);
        }
    }
    for part in parsed.html_bodies() {
        if let PartType::Html(html) = &part.body {
            if !mail.html.is_empty() { mail.html.push_str("\n<hr>\n"); }
            mail.html.push_str(html);
        }
    }
    if !mail.rtf.is_empty() && (mail.text.is_empty() || mail.html.is_empty()) {
        let (html, text) = msg::render_rtf(&mail.rtf)?;
        if mail.html.is_empty() { mail.html = html; }
        if mail.text.is_empty() { mail.text = text; }
    }
    for (index, part) in parsed.attachments().enumerate() {
        if body_rtf(part) { continue; }
        let data = part_bytes(bytes, part)?;
        let nested = if part.is_message() { Some(Box::new(parse_eml(&data, depth + 1)?)) } else { None };
        let mime = part.content_type().map(|ct| {
            let mut value = format!("{}/{}", ct.c_type, ct.c_subtype.as_deref().unwrap_or("octet-stream"));
            if let Some(charset) = ct.attribute("charset") { value.push_str(&format!("; charset={charset}")); }
            value
        }).unwrap_or_else(|| "application/octet-stream".into());
        mail.attachments.push(Attachment {
            name: part.attachment_name().map(str::to_owned).unwrap_or_else(|| format!("attachment-{}{}", index + 1,
                if nested.is_some() { ".eml" } else { "" })),
            mime, cid: part.content_id().unwrap_or_default().into(),
            location: part.content_location().unwrap_or_default().into(),
            inline: part.content_disposition().is_some_and(|d| d.c_type.eq_ignore_ascii_case("inline"))
                || matches!(part.body, PartType::InlineBinary(_)),
            data, message: nested,
        });
        let attachment = mail.attachments.last().unwrap();
        for value in [&attachment.name, &attachment.mime, &attachment.cid, &attachment.location] {
            check_header_value(value)?;
        }
    }
    Ok(mail)
}

fn part_bytes(bytes: &[u8], part: &mail_parser::MessagePart<'_>) -> Result<Vec<u8>> {
    let raw = bytes.get(part.offset_body as usize..part.offset_end as usize).ok_or("Invalid MIME part range.")?;
    Ok(match part.encoding {
        Encoding::None => raw.to_vec(),
        Encoding::Base64 => mail_parser::decoders::base64::base64_decode(raw).ok_or("Invalid MIME base64.")?,
        Encoding::QuotedPrintable => mail_parser::decoders::quoted_printable::quoted_printable_decode(raw)
            .ok_or("Invalid MIME quoted-printable encoding.")?,
    })
}

fn parse_headers(bytes: &[u8]) -> Result<Vec<(String, String)>> {
    let text = std::str::from_utf8(bytes).map_err(|_| "Email headers must use UTF-8 or MIME encoded words.")?;
    if text.len() > 1024 * 1024 || text.contains('\0') { return Err("Invalid or oversized email headers.".into()); }
    let mut headers: Vec<(String, String)> = Vec::new();
    for line in text.lines() {
        if line.is_empty() { break; }
        check_header_value(line)?;
        if line.starts_with([' ', '\t']) {
            let last = headers.last_mut().ok_or("Email starts with a folded header.")?;
            last.1.push_str("\r\n"); last.1.push_str(line);
        } else {
            let (name, value) = line.split_once(':').ok_or("Invalid email header.")?;
            if name.is_empty() || !name.bytes().all(|b| (33..=126).contains(&b) && b != b':') {
                return Err("Invalid email header name.".into());
            }
            headers.push((name.into(), value.trim_start_matches([' ', '\t']).into()));
            if headers.len() > 4096 { return Err("Too many email headers.".into()); }
        }
    }
    Ok(headers)
}

fn check_header_value(value: &str) -> Result<()> {
    if value.chars().any(|c| c.is_ascii_control() && c != '\t') {
        return Err("An email header or attachment label contains a control character.".into());
    }
    Ok(())
}

fn header_bytes(mail: &Mail) -> Vec<u8> {
    mail.headers.iter().map(|(name, value)| format!("{name}: {value}\r\n")).collect::<String>().into_bytes()
}

fn write_eml(mail: &Mail, mut output: impl Write) -> Result<()> {
    for (name, value) in &mail.headers {
        if !["content-type", "content-transfer-encoding", "mime-version"].contains(&name.to_ascii_lowercase().as_str()) {
            write!(output, "{name}: {value}\r\n")?;
        }
    }
    output.write_all(b"MIME-Version: 1.0\r\n")?;
    let mut alternatives = Vec::new();
    if !mail.text.is_empty() { alternatives.push(MimePart::new("text/plain", mail.text.as_str())); }
    if !mail.rtf.is_empty() { alternatives.push(MimePart::new("text/rtf", mail.rtf.as_slice())); }
    if !mail.html.is_empty() { alternatives.push(MimePart::new("text/html", mail.html.as_str())); }
    let body = match alternatives.len() {
        0 => MimePart::new("text/plain", ""),
        1 => alternatives.remove(0),
        _ => MimePart::new("multipart/alternative", alternatives),
    };
    let mut related = vec![body];
    let mut attached = Vec::new();
    for attachment in &mail.attachments {
        let mut part = MimePart::new(attachment.mime.as_str(), attachment.data.as_slice());
        if attachment.message.is_some() { part = part.transfer_encoding("8bit"); }
        if !attachment.cid.is_empty() { part = part.cid(attachment.cid.as_str()); }
        if !attachment.location.is_empty() { part = part.location(attachment.location.as_str()); }
        if attachment.inline {
            part = part.header("Content-Disposition", mail_builder::headers::content_type::ContentType::new("inline")
                .attribute("filename", attachment.name.as_str()));
            related.push(part);
        } else { attached.push(part.attachment(attachment.name.as_str())); }
    }
    let body = if related.len() == 1 { related.remove(0) } else { MimePart::new("multipart/related", related) };
    let body = if attached.is_empty() { body } else {
        attached.insert(0, body); MimePart::new("multipart/mixed", attached)
    };
    MessageBuilder::new().body(body).write_body(output)?;
    Ok(())
}

fn write_html(mail: &Mail, mut output: impl Write, include_headers: bool) -> Result<()> {
    let escaped = ammonia::clean_text;
    let encoded_headers = header_bytes(mail);
    let parsed = MessageParser::default().parse_headers(&encoded_headers).ok_or("Invalid email headers.")?;
    let mut resources = HashMap::new();
    for attachment in &mail.attachments {
        if !attachment.cid.is_empty() && ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"]
            .contains(&attachment.mime.to_ascii_lowercase().as_str()) {
            resources.insert(format!("cid:{}", attachment.cid), format!("data:{};base64,{}", attachment.mime,
                base64::engine::general_purpose::STANDARD.encode(&attachment.data)));
        }
    }
    let mut cleaner = ammonia::Builder::default();
    cleaner.url_schemes(["http", "https", "mailto", "cid", "data"].into_iter().collect())
        .url_relative(ammonia::UrlRelative::Deny)
        .attribute_filter(move |tag, attribute, value| {
            if tag == "img" && attribute == "src" { resources.get(value).cloned().map(Cow::Owned) }
            else if attribute == "href" && value.starts_with("data:") { None }
            else { Some(Cow::Borrowed(value)) }
        });
    write!(output, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\"><title>{}</title><style>body{{font:16px system-ui;max-width:70rem;margin:2rem auto;padding:0 1rem}}pre{{white-space:pre-wrap;overflow-wrap:anywhere}}img{{max-width:100%}}dt{{font-weight:bold}}dd{{margin:0 0 .5rem}}</style></head><body>", escaped(parsed.subject().unwrap_or("Email")))?;
    if include_headers {
        output.write_all(b"<dl>")?;
        let mut positions = HashMap::new();
        for (name, value) in &mail.headers {
            let decoded = parsed.header_as(name.as_str(), mail_parser::HeaderForm::Text);
            let position = positions.entry(name.to_ascii_lowercase()).or_insert(0usize);
            let value = decoded.get(*position).and_then(|v| v.as_text()).unwrap_or(value);
            *position += 1;
            write!(output, "<dt>{}</dt><dd>{}</dd>", escaped(name), escaped(value))?;
        }
        output.write_all(b"</dl><hr>")?;
    }
    if mail.html.is_empty() { write!(output, "<pre>{}</pre>", escaped(&mail.text))?; }
    else { cleaner.clean(&mail.html).write_to(&mut output)?; }
    if !mail.attachments.is_empty() {
        output.write_all(b"<hr><h2>Attachments</h2><ul>")?;
        for attachment in &mail.attachments {
            write!(output, "<li><a download=\"{}\" href=\"data:application/octet-stream;base64,", escaped(&attachment.name))?;
            let mut encoder = base64::write::EncoderWriter::new(&mut output, &base64::engine::general_purpose::STANDARD);
            encoder.write_all(&attachment.data)?; encoder.finish()?; drop(encoder);
            write!(output, "\">{}</a> ({} bytes)</li>", escaped(&attachment.name), attachment.data.len())?;
        }
        output.write_all(b"</ul>")?;
    }
    output.write_all(b"</body></html>\n")?;
    Ok(())
}
