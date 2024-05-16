use std::io::{BufRead, Read, Write};
use zstd::{Decoder, Encoder};


pub enum PerhapsCompressedReader<'a, R: BufRead> {
    Compressed(Decoder<'a, R>),
    UnCompressed(R)
}

impl<'a, R: BufRead> PerhapsCompressedReader<'a, R> {
    pub fn into_inner(self) -> R {
        match self {
            Self::Compressed(decoder) => decoder.finish(),
            Self::UnCompressed(r) => r
        }
    }
    
    pub fn with_compression(reader: R, comp: bool) -> Self {
        if comp {
            Self::Compressed(Decoder::with_buffer(reader).unwrap())
        } else {
            Self::UnCompressed(reader)
        }
    }
}

impl<'a, R: BufRead> Read for PerhapsCompressedReader<'a, R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Self::Compressed(decoder) => decoder.read(buf),
            Self::UnCompressed(reader) => reader.read(buf)
        }
    }
}


pub enum PerhapsCompressedWriter<'a, W: Write> {
    Compressed(Encoder<'a, W>),
    UnCompressed(W)
}

impl<'a, W: Write> PerhapsCompressedWriter<'a, W> {
    pub fn finish(self) -> anyhow::Result<W> {
        Ok(match self {
            Self::Compressed(encoder) => encoder.finish()?,
            Self::UnCompressed(w) => w
        })
    }
    
    pub fn with_compression(writer: W, comp: bool, level: u8) -> Self {
        if comp {
            Self::Compressed(Encoder::new(writer, level as i32).unwrap())
        } else {
            Self::UnCompressed(writer)
        }
    }
}

impl<'a, W: Write> Write for PerhapsCompressedWriter<'a, W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Self::Compressed(encoder) => { encoder.write(buf) },
            Self::UnCompressed(writer) => writer.write(buf)
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Self::Compressed(encoder) => encoder.flush(),
            Self::UnCompressed(writer) => writer.flush()
        }
    }
}