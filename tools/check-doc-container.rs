//! Development-only check with the existing pinned cfb crate. No code is shipped.
use std::{fs::File, io::Read};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    for name in std::env::args().skip(1) {
        let mut file = cfb::CompoundFile::open_strict(File::open(&name)?)?;
        let streams: Vec<_> = file.walk().filter(|entry| entry.is_stream())
            .map(|entry| (entry.path().to_owned(), entry.len())).collect();
        for (path, size) in streams {
            let mut bytes = Vec::new();
            file.open_stream(&path)?.read_to_end(&mut bytes)?;
            assert_eq!(bytes.len() as u64, size);
        }
    }
    Ok(())
}
