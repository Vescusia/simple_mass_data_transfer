use std::io::{Read, Write};
use md5::{Digest, Md5};


#[derive(Debug)]
pub struct HashReader<R: Read> {
    reader: R,
    hasher: Md5,
    /// total bytes digested
    pub digested: usize,
}

impl<R: Read> HashReader<R> {
    pub fn new(reader: R) -> Self {
        Self{
            reader,
            hasher: Md5::new(),
            digested: 0
        }
    }

    pub fn finalize(self) -> (R, u128) {
        (self.reader, u128::from_le_bytes(
            *self.hasher.finalize().split_first_chunk::<16>().unwrap().0)
        )
    }
}

impl<R: Read> Read for HashReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let bytes_read = self.reader.read(buf);
        if let Ok(br) = bytes_read {
            self.hasher.update(&buf[..br]);
            self.digested += br;
        }
        bytes_read
    }
}


#[derive(Debug)]
pub struct HashWriter<W: Write> {
    writer: W,
    hasher: Md5,
    /// total bytes digested
    pub digested: usize,
}

impl<W: Write> HashWriter<W> {
    pub fn new(writer: W) -> Self {
        Self{
            writer,
            hasher: Md5::new(),
            digested: 0
        }
    }

    pub fn finalize(self) -> (W, u128) {
        (self.writer, u128::from_le_bytes(
            *self.hasher.finalize().split_first_chunk::<16>().unwrap().0)
        )
    }
}

impl<W: Write> Write for HashWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let written = self.writer.write(buf);
        if let Ok(bw) = written {
            self.hasher.update(&buf[0..bw]);
            self.digested += bw;
        }
        written
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.writer.flush()
    }
}


pub enum PerhapsHashingWriter<W: Write> {
    Hashing(HashWriter<W>),
    Precomputed{ writer: W, hash: u128, digested: usize }
}

impl<W: Write> PerhapsHashingWriter<W> {
    pub fn with_hash(writer: W, hash: Option<u128>) -> Self {
        if let Some(hash) = hash {
            Self::Precomputed { writer, hash, digested: 0 }
        } else {
            Self::Hashing(HashWriter::new(writer))
        }
    }

    pub fn finalize(self) -> (W, u128) {
        match self {
            Self::Precomputed { writer, hash, .. } => (writer, hash),
            Self::Hashing(hasher) => hasher.finalize()
        }
    }

    pub fn digested(&self) -> usize {
        match self {
            Self::Hashing(hash) => hash.digested,
            Self::Precomputed { digested, .. } => *digested
        }
    }
}

impl<W: Write> Write for PerhapsHashingWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Self::Precomputed { writer, digested, .. } => {
                let written = writer.write(buf);
                if let Ok(written) = written {
                    *digested += written;
                }
                written
            },
            Self::Hashing(hasher) => hasher.write(buf)
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Self::Precomputed { writer, .. } => writer.flush(),
            Self::Hashing(hasher) => hasher.flush()
        }
    }
}
