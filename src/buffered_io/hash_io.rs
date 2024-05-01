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