use std::io::{Read, Write};
use lz4_flex::frame;

#[derive(Debug)]
pub enum PerhapsCompressedReader<R: Read> {
    Compressed(frame::FrameDecoder<R>),
    UnCompressed(std::io::Take<R>)
}

impl<R: Read> PerhapsCompressedReader<R> {
    /// This does not need a total amount of bytes read,
    /// as lz4 does that internally.
    pub fn compressed(reader: R) -> Self {
        Self::Compressed(frame::FrameDecoder::new(reader))
    }

    /// Use uncompressed reader, 
    /// with the total amount of bytes that are to be read
    pub fn uncompressed(reader: R, total_bytes: u64) -> Self {
        Self::UnCompressed(reader.take(total_bytes))
    }
    
    pub fn into_inner(self) -> R {
        match self {
            Self::Compressed(decoder) => decoder.into_inner(),
            Self::UnCompressed(r) => r.into_inner()
        }
    }
    
    pub fn with_compression(reader: R, comp: bool, total_bytes: u64) -> Self {
        if comp {
            Self::compressed(reader)
        } else {
            Self::uncompressed(reader, total_bytes)
        }
    }
}

impl<R: Read> Read for PerhapsCompressedReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Self::Compressed(decoder) => decoder.read(buf),
            Self::UnCompressed(reader) => reader.read(buf)
        }
    }
}

#[derive(Debug)]
pub enum PerhapsCompressedWriter<W: Write> {
    Compressed(frame::FrameEncoder<W>),
    UnCompressed(W)
}

impl<W: Write> PerhapsCompressedWriter<W> {
    pub fn compressed(writer: W) -> Self {
        let info = frame::FrameInfo::new()
            .block_size(frame::BlockSize::Max64KB)
            .block_mode(frame::BlockMode::Linked);
        Self::Compressed(frame::FrameEncoder::with_frame_info(info, writer))
    }

    pub fn uncompressed(writer: W) -> Self {
        Self::UnCompressed(writer)
    }

    pub fn finish(self) -> anyhow::Result<W> {
        Ok(match self {
            Self::Compressed(encoder) => encoder.finish()?,
            Self::UnCompressed(w) => w
        })
    }
    
    pub fn with_compression(writer: W, comp: bool) -> Self {
        if comp {
            Self::compressed(writer)
        } else {
            Self::uncompressed(writer)
        }
    }
}

impl<W: Write> Write for PerhapsCompressedWriter<W> {
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