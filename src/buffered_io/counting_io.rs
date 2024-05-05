use std::io::{Read, Write};

#[derive(Debug)]
pub struct CountingWriter<W: Write> {
    writer: W,
    pub written: usize
}

impl<W: Write> CountingWriter<W> {
    pub fn new(writer: W) -> Self {
        Self{ writer, written: 0 }
    }
}

impl<W: Write> Write for CountingWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let written = self.writer.write(buf);
        if let Ok(written) = written {
            self.written += written
        }
        written
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.writer.flush()
    }
}


#[derive(Debug)]
pub struct CountingReader<R: Read> {
    reader: R,
    pub read: usize
}

impl<R: Read> CountingReader<R> {
    pub fn new(reader: R) -> Self {
        Self{ reader, read: 0 }
    }
}

impl<R: Read> Read for CountingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let read = self.reader.read(buf);
        if let Ok(read) = read {
            self.read += read
        }
        read
    }
}
