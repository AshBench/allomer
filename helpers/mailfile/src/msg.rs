use super::{Attachment, Mail, Result, INPUT_LIMIT};
use cfb::CompoundFile;
use mail_builder::headers::{Header, address::Address, text::Text};
use mail_parser::MessageParser;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Cursor, Read, Seek, Write};
use std::path::{Path, PathBuf};

type Properties = BTreeMap<u32, u64>;
const PROPERTY_STREAM: &str = "__properties_version1.0";

fn u32_at(bytes: &[u8], offset: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(bytes.get(offset..offset + 4).ok_or("Truncated MSG property.")?.try_into()?))
}

fn stream<F: Read + Seek>(file: &mut CompoundFile<F>, path: &Path) -> Result<Vec<u8>> {
    if file.entry(path)?.len() as usize > INPUT_LIMIT { return Err("An MSG stream exceeds 64 MiB.".into()); }
    let mut bytes = Vec::new();
    file.open_stream(path)?.take(INPUT_LIMIT as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > INPUT_LIMIT { return Err("An MSG stream exceeds 64 MiB.".into()); }
    Ok(bytes)
}

fn properties<F: Read + Seek>(file: &mut CompoundFile<F>, path: &Path, header: usize) -> Result<Properties> {
    let bytes = stream(file, &path.join(PROPERTY_STREAM))?;
    if bytes.len() < header || (bytes.len() - header) % 16 != 0 || bytes.len() > header + 4096 * 16 {
        return Err("Invalid MSG property table.".into());
    }
    let mut result = BTreeMap::new();
    for entry in bytes[header..].chunks_exact(16) {
        let tag = u32_at(entry, 0)?;
        if result.insert(tag, u64::from_le_bytes(entry[8..16].try_into()?)).is_some() {
            return Err("Duplicate MSG property.".into());
        }
        if u32_at(entry, 4)? & 2 == 0 { return Err("An MSG property does not permit reading.".into()); }
    }
    Ok(result)
}

fn property_bytes<F: Read + Seek>(file: &mut CompoundFile<F>, path: &Path,
                                  props: &Properties, tag: u32) -> Result<Option<Vec<u8>>> {
    let Some(&size) = props.get(&tag) else { return Ok(None); };
    let bytes = stream(file, &path.join(format!("__substg1.0_{tag:08X}")))?;
    let extra = match tag & 0xffff { 0x001f => 2, 0x001e => 1, _ => 0 };
    if bytes.len() + extra != (size as u32) as usize {
        return Err("The MSG property length does not match its stream.".into());
    }
    Ok(Some(bytes))
}

fn decode(bytes: &[u8], codepage: u32) -> Result<String> {
    let label = match codepage {
        65001 => "utf-8".into(), 1200 => "utf-16le".into(), 1201 => "utf-16be".into(),
        20127 => "us-ascii".into(), 932 => "shift_jis".into(), 936 => "gbk".into(),
        949 => "euc-kr".into(), 950 => "big5".into(), 20866 => "koi8-r".into(),
        21866 => "koi8-u".into(), 28591..=28606 => format!("iso-8859-{}", codepage - 28590),
        value => format!("windows-{value}"),
    };
    let encoding = encoding_rs::Encoding::for_label(label.as_bytes()).ok_or("Unsupported MSG text code page.")?;
    encoding.decode_without_bom_handling_and_without_replacement(bytes)
        .map(|s| s.trim_end_matches('\0').to_owned()).ok_or("Invalid MSG text encoding.".into())
}

fn string<F: Read + Seek>(file: &mut CompoundFile<F>, path: &Path, props: &Properties,
                         id: u32, codepage: u32) -> Result<String> {
    if let Some(bytes) = property_bytes(file, path, props, id << 16 | 0x001f)? {
        if bytes.len() % 2 != 0 { return Err("Invalid UTF-16 MSG string.".into()); }
        let units: Vec<_> = bytes.chunks_exact(2).map(|b| u16::from_le_bytes([b[0], b[1]])).collect();
        return Ok(String::from_utf16(&units)?.trim_end_matches('\0').to_owned());
    }
    if let Some(bytes) = property_bytes(file, path, props, id << 16 | 0x001e)? { return decode(&bytes, codepage); }
    Ok(String::new())
}

fn integer(props: &Properties, id: u32, default: u32) -> u32 {
    props.get(&(id << 16 | 3)).map(|&v| v as u32).unwrap_or(default)
}

fn children<F>(file: &CompoundFile<F>, path: &Path, prefix: &str) -> Result<Vec<PathBuf>> {
    let mut paths: Vec<_> = file.read_storage(path)?.filter(|entry| entry.is_storage()
        && entry.name().starts_with(prefix)).map(|entry| entry.path().to_owned()).collect();
    paths.sort();
    if paths.len() > 1000 { return Err("Too many MSG recipients or attachments.".into()); }
    Ok(paths)
}

pub(super) fn read(bytes: &[u8]) -> Result<Mail> {
    let mut file = CompoundFile::open(Cursor::new(bytes))?;
    let mut size = 0u64;
    for (index, entry) in file.walk().enumerate() {
        size = size.checked_add(entry.len()).ok_or("Invalid MSG stream size.")?;
        if index > 20_000 || size > 256 * 1024 * 1024 || entry.path().components().count() > 36 {
            return Err("The MSG file exceeds its entry, size, or nesting limit.".into());
        }
    }
    read_message(&mut file, Path::new("/"), 0)
}

fn read_message<F: Read + Seek>(file: &mut CompoundFile<F>, path: &Path, depth: usize) -> Result<Mail> {
    if depth > 16 { return Err("MSG nesting exceeds 16 messages.".into()); }
    let props = properties(file, path, if depth == 0 { 32 } else { 24 })?;
    let codepage = integer(&props, 0x3ffd, 1252);
    let class = string(file, path, &props, 0x001a, codepage)?;
    if class != "IPM.Note" && !class.starts_with("IPM.Note.") {
        return Err(format!("The MSG object is not an email message: {class}").into());
    }
    if class.to_ascii_lowercase().contains("smime") { return Err("Encrypted or signed MSG messages are not supported yet.".into()); }
    let raw_headers = string(file, path, &props, 0x007d, codepage)?;
    let mut mail = Mail { headers: super::parse_headers(raw_headers.as_bytes())?,
        text: string(file, path, &props, 0x1000, codepage)?, ..Default::default() };
    let subject = string(file, path, &props, 0x0037, codepage)?;
    if props.contains_key(&0x0037001f) || props.contains_key(&0x0037001e) {
        set_header(&mut mail, "Subject", encoded_text(&subject)?, true);
    }
    if let Some(html) = property_bytes(file, path, &props, 0x10130102)? {
        let fallback = if std::str::from_utf8(&html).is_ok() { 65001 } else { codepage };
        mail.html = decode(&html, integer(&props, 0x3fde, fallback))?;
    } else { mail.html = string(file, path, &props, 0x1013, codepage)?; }
    if let Some(compressed) = property_bytes(file, path, &props, 0x10090102)? {
        if compressed.len() < 16 || u32_at(&compressed, 4)? > 8 * 1024 * 1024 {
            return Err("Invalid or oversized compressed RTF body.".into());
        }
        let size = u32_at(&compressed, 4)? as usize;
        if u32_at(&compressed, 8)? == 0x414c454d && size + 16 > compressed.len() {
            return Err("Truncated uncompressed RTF body.".into());
        }
        let rtf = compressed_rtf::decompress_rtf(&compressed)?;
        mail.rtf = rtf.chars().map(|c| u8::try_from(c as u32)).collect::<std::result::Result<Vec<_>, _>>()?;
        if mail.rtf.len() != size { return Err("The RTF body does not match its declared length.".into()); }
        if mail.text.is_empty() || mail.html.is_empty() {
            let (html, text) = render_rtf(&mail.rtf)?;
            if mail.html.is_empty() { mail.html = html; }
            if mail.text.is_empty() { mail.text = text; }
        }
    }
    let sender_name = string(file, path, &props, 0x0c1a, codepage)?;
    let mut sender_email = string(file, path, &props, 0x5d01, codepage)?;
    if sender_email.is_empty() { sender_email = string(file, path, &props, 0x0c1f, codepage)?; }
    if !sender_email.is_empty() {
        set_header(&mut mail, "From", encoded_address(&sender_name, &sender_email)?, false);
    }
    let recipients = children(file, path, "__recip_version1.0_#")?;
    let attachments = children(file, path, "__attach_version1.0_#")?;
    let table = stream(file, &path.join(PROPERTY_STREAM))?;
    if u32_at(&table, 16)? as usize != recipients.len() || u32_at(&table, 20)? as usize != attachments.len() {
        return Err("The MSG recipient or attachment count is incorrect.".into());
    }
    let mut addresses = [Vec::new(), Vec::new(), Vec::new()];
    for recipient in recipients {
        let values = properties(file, &recipient, 8)?;
        let kind = integer(&values, 0x0c15, 1);
        if !(1..=3).contains(&kind) { return Err("Invalid MSG recipient type.".into()); }
        let name = string(file, &recipient, &values, 0x3001, codepage)?;
        let mut email = string(file, &recipient, &values, 0x39fe, codepage)?;
        if email.is_empty() { email = string(file, &recipient, &values, 0x3003, codepage)?; }
        addresses[kind as usize - 1].push(encoded_address(&name, &email)?);
    }
    for (name, values) in ["To", "Cc", "Bcc"].into_iter().zip(addresses) {
        if !values.is_empty() { set_header(&mut mail, name, values.join(", "), false); }
    }
    if let Some(&time) = props.get(&0x00390040).or_else(|| props.get(&0x0e060040)) {
        if time >= 116_444_736_000_000_000 {
            let date = mail_parser::DateTime::from_timestamp(((time - 116_444_736_000_000_000) / 10_000_000) as i64);
            set_header(&mut mail, "Date", date.to_rfc822(), false);
        }
    }
    let message_id = string(file, path, &props, 0x1035, codepage)?;
    if !message_id.is_empty() {
        super::check_header_value(&message_id)?;
        set_header(&mut mail, "Message-ID", message_id, false);
    }
    for attachment in attachments {
        let values = properties(file, &attachment, 8)?;
        let method = integer(&values, 0x3705, 1);
        let mut name = string(file, &attachment, &values, 0x3707, codepage)?;
        if name.is_empty() { name = string(file, &attachment, &values, 0x3704, codepage)?; }
        if name.is_empty() { name = format!("attachment-{}", mail.attachments.len() + 1); }
        let mut mime = string(file, &attachment, &values, 0x370e, codepage)?;
        let (data, message) = match method {
            1 => (property_bytes(file, &attachment, &values, 0x37010102)?.ok_or("Missing MSG attachment data.")?, None),
            5 => {
                let nested = read_message(file, &attachment.join("__substg1.0_3701000D"), depth + 1)?;
                let mut bytes = Vec::new(); super::write_eml(&nested, &mut bytes)?;
                mime = "message/rfc822".into();
                if name.to_ascii_lowercase().ends_with(".msg") { name.truncate(name.len() - 4); name.push_str(".eml"); }
                else if !name.to_ascii_lowercase().ends_with(".eml") { name.push_str(".eml"); }
                (bytes, Some(Box::new(nested)))
            }
            _ => return Err("The MSG contains a linked or OLE attachment that cannot be exported as a file.".into()),
        };
        if mime.is_empty() { mime = "application/octet-stream".into(); }
        if mime.contains(['\r', '\n', '\0']) { return Err("Invalid attachment MIME type.".into()); }
        mail.attachments.push(Attachment { name, mime, data, message,
            cid: string(file, &attachment, &values, 0x3712, codepage)?,
            location: string(file, &attachment, &values, 0x3713, codepage)?,
            inline: values.get(&0x7ffe000b).is_some_and(|v| v & 0xffff != 0) || integer(&values, 0x3714, 0) & 4 != 0,
        });
        let value = mail.attachments.last().unwrap();
        for field in [&value.name, &value.mime, &value.cid, &value.location] { super::check_header_value(field)?; }
    }
    Ok(mail)
}

fn set_header(mail: &mut Mail, name: &str, value: String, replace: bool) {
    let exists = mail.headers.iter().any(|(key, _)| key.eq_ignore_ascii_case(name));
    if exists && !replace { return; }
    mail.headers.retain(|(key, _)| !key.eq_ignore_ascii_case(name));
    mail.headers.push((name.into(), value));
}

fn encoded_text(value: &str) -> Result<String> {
    super::check_header_value(value)?;
    let mut bytes = Vec::new(); Text::new(value).write_header(&mut bytes, 9)?;
    Ok(String::from_utf8(bytes)?.trim_end_matches(['\r', '\n']).into())
}

fn encoded_address(name: &str, email: &str) -> Result<String> {
    super::check_header_value(name)?; super::check_header_value(email)?;
    let mut bytes = Vec::new();
    Address::new_address(if name.is_empty() { None } else { Some(name) }, email)
        .write_header(&mut bytes, 6)?;
    Ok(String::from_utf8(bytes)?.trim_end_matches(['\r', '\n']).into())
}

fn put_stream(file: &mut CompoundFile<File>, path: &Path, bytes: &[u8]) -> Result<()> {
    file.create_new_stream(path)?.write_all(bytes)?; Ok(())
}

fn put_string(file: &mut CompoundFile<File>, path: &Path, props: &mut Properties, id: u32, value: &str) -> Result<()> {
    if value.is_empty() { return Ok(()); }
    if value.contains('\0') { return Err("MSG strings cannot contain null characters.".into()); }
    let bytes: Vec<_> = value.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let tag = id << 16 | 0x001f;
    props.insert(tag, (bytes.len() + 2) as u64);
    put_stream(file, &path.join(format!("__substg1.0_{tag:08X}")), &bytes)
}

fn put_binary(file: &mut CompoundFile<File>, path: &Path, props: &mut Properties, tag: u32, bytes: &[u8]) -> Result<()> {
    props.insert(tag, bytes.len() as u64);
    put_stream(file, &path.join(format!("__substg1.0_{tag:08X}")), bytes)
}

fn put_properties(file: &mut CompoundFile<File>, path: &Path, props: Properties, header: &[u8]) -> Result<()> {
    let mut bytes = header.to_vec();
    for (tag, value) in props { bytes.extend(tag.to_le_bytes()); bytes.extend(6u32.to_le_bytes()); bytes.extend(value.to_le_bytes()); }
    put_stream(file, &path.join(PROPERTY_STREAM), &bytes)
}

pub(super) fn write(mail: &Mail, destination: File) -> Result<()> {
    let mut file = CompoundFile::create(destination)?;
    file.set_storage_clsid("/", uuid::Uuid::parse_str("00020D0B-0000-0000-C000-000000000046")?)?;
    file.create_storage("/__nameid_version1.0")?;
    for name in ["00020102", "00030102", "00040102"] {
        put_stream(&mut file, Path::new(&format!("/__nameid_version1.0/__substg1.0_{name}")), &[])?;
    }
    write_message(&mut file, Path::new("/"), mail, 0)?;
    file.flush()?; Ok(())
}

fn write_message(file: &mut CompoundFile<File>, path: &Path, mail: &Mail, depth: usize) -> Result<()> {
    if depth > 16 { return Err("MSG nesting exceeds 16 messages.".into()); }
    let headers = super::header_bytes(mail);
    let parsed = MessageParser::default().parse_headers(&headers).ok_or("Invalid email headers.")?;
    let mut props = Properties::new();
    props.insert(0x340d0003, 0x00040000);
    props.insert(0x3fde0003, 65001);
    props.insert(0x3ffd0003, 65001);
    props.insert(0x0e070003, if mail.attachments.is_empty() { 1 } else { 0x11 });
    props.insert(0x0e1b000b, u64::from(!mail.attachments.is_empty()));
    put_string(file, path, &mut props, 0x001a, "IPM.Note")?;
    put_string(file, path, &mut props, 0x0037, parsed.subject().unwrap_or_default())?;
    put_string(file, path, &mut props, 0x007d, std::str::from_utf8(&headers)?)?;
    put_string(file, path, &mut props, 0x1000, &mail.text)?;
    if !mail.html.is_empty() { put_binary(file, path, &mut props, 0x10130102, mail.html.as_bytes())?; }
    if !mail.rtf.is_empty() {
        let rtf: String = mail.rtf.iter().map(|&b| char::from(b)).collect();
        put_binary(file, path, &mut props, 0x10090102, &compressed_rtf::encode_rtf(&rtf)?)?;
    }
    if let Some(id) = parsed.message_id() { put_string(file, path, &mut props, 0x1035, &format!("<{id}>"))?; }
    if let Some(sender) = parsed.sender().or_else(|| parsed.from()).and_then(|v| v.first()) {
        put_string(file, path, &mut props, 0x0c1a, sender.name().unwrap_or_default())?;
        put_string(file, path, &mut props, 0x0c1e, "SMTP")?;
        for id in [0x0c1f, 0x5d01] { put_string(file, path, &mut props, id, sender.address().unwrap_or_default())?; }
    }
    if let Some(date) = parsed.date() {
        let value = (date.to_timestamp() as i128 * 10_000_000 + 116_444_736_000_000_000).try_into()?;
        props.insert(0x00390040, value); props.insert(0x0e060040, value);
    }
    let mut count = 0u32;
    for (kind, addresses) in [(1, parsed.to()), (2, parsed.cc()), (3, parsed.bcc())] {
        if let Some(addresses) = addresses {
            for address in addresses.iter() {
                if count >= 1000 { return Err("Too many email recipients.".into()); }
                let recipient = path.join(format!("__recip_version1.0_#{count:08X}"));
                file.create_storage(&recipient)?;
                let mut values = Properties::new(); values.insert(0x0c150003, kind); values.insert(0x30000003, count as u64);
                put_string(file, &recipient, &mut values, 0x3001, address.name().unwrap_or_default())?;
                put_string(file, &recipient, &mut values, 0x3002, "SMTP")?;
                for id in [0x3003, 0x39fe] { put_string(file, &recipient, &mut values, id, address.address().unwrap_or_default())?; }
                put_properties(file, &recipient, values, &[0; 8])?;
                count += 1;
            }
        }
    }
    for (index, attachment) in mail.attachments.iter().enumerate() {
        let entry = path.join(format!("__attach_version1.0_#{index:08X}"));
        file.create_storage(&entry)?;
        let mut values = Properties::new();
        values.insert(0x0e210003, index as u64);
        values.insert(0x370b0003, u32::MAX as u64);
        values.insert(0x7ffe000b, attachment.inline as u64);
        values.insert(0x37140003, if attachment.inline { 4 } else { 0 });
        put_string(file, &entry, &mut values, 0x3707, &attachment.name)?;
        put_string(file, &entry, &mut values, 0x3704, &attachment.name)?;
        put_string(file, &entry, &mut values, 0x3001, &attachment.name)?;
        put_string(file, &entry, &mut values, 0x370e, &attachment.mime)?;
        put_string(file, &entry, &mut values, 0x3712, &attachment.cid)?;
        put_string(file, &entry, &mut values, 0x3713, &attachment.location)?;
        if let Some(nested) = &attachment.message {
            let nested_path = entry.join("__substg1.0_3701000D");
            file.create_storage(&nested_path)?;
            values.insert(0x37050003, 5);
            values.insert(0x3701000d, 0x00000001ffffffff);
            write_message(file, &nested_path, nested, depth + 1)?;
        } else {
            values.insert(0x37050003, 1);
            put_binary(file, &entry, &mut values, 0x37010102, &attachment.data)?;
        }
        put_properties(file, &entry, values, &[0; 8])?;
    }
    let mut header = vec![0u8; if depth == 0 { 32 } else { 24 }];
    for (offset, value) in [(8, count), (12, mail.attachments.len() as u32), (16, count), (20, mail.attachments.len() as u32)] {
        header[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }
    put_properties(file, path, props, &header)
}

pub(super) fn render_rtf(bytes: &[u8]) -> Result<(String, String)> {
    unsafe extern "C" {
        #[link_name = "render_rtf"]
        fn native_render(input: *const u8, length: usize, html: *mut *mut u8, html_length: *mut usize,
                         text: *mut *mut u8, text_length: *mut usize) -> i32;
        fn free(pointer: *mut std::ffi::c_void);
    }
    let (mut html, mut text) = (std::ptr::null_mut(), std::ptr::null_mut());
    let (mut html_length, mut text_length) = (0usize, 0usize);
    // SAFETY: Native code receives a valid input slice and initialized output pointers.
    // On success it returns malloc-owned buffers whose lengths it checked.
    unsafe {
        if native_render(bytes.as_ptr(), bytes.len(), &mut html, &mut html_length, &mut text, &mut text_length) != 0 {
            return Err("macOS could not read the rich-text message body.".into());
        }
        let html_bytes = std::slice::from_raw_parts(html, html_length).to_vec();
        let text_bytes = std::slice::from_raw_parts(text, text_length).to_vec();
        free(html.cast()); free(text.cast());
        Ok((String::from_utf8(html_bytes)?, String::from_utf8(text_bytes)?))
    }
}
