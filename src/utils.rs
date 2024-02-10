use md5::Digest;

/// Reset a vector buffer to 0u8's up to `min(reset_size, vec.capacity())`
pub fn reset_vec_buf(vec: &mut Vec<u8>, reset_size: usize) {
    // clear vec
    vec.clear();
    // push zeroes up to reset size
    for _ in 0..reset_size.min(vec.capacity()) {
        vec.push(0)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct HashU64{
    pub high: u64,
    pub low: u64
}

impl HashU64 {
    /// Split `self` into its inner parts.
    /// The left `u64` is high, the right `u64` is low
    pub fn into_inner(self) -> (u64, u64) {
        (self.high, self.low)
    }
}

/// Split a md5 hasher into two u64's
pub fn hasher_to_u64s(hasher: md5::Md5) -> HashU64 {
    // A md5 hash is literally 16 bytes long. It cannot be less.
    let hash = hasher.finalize();
    let hash_array: [u8; 16] = hash[0..16].try_into().unwrap();
    HashU64{
        high: u64::from_be_bytes(hash_array[0..8].try_into().unwrap()),
        low: u64::from_be_bytes(hash_array[8..16].try_into().unwrap())
    }
}



pub struct DigestReader<R: std::io::Read> {
    reader: R,
    digester: md5::Md5,
    pub bytes_read: u64,
}
impl<R: std::io::Read> DigestReader<R> {
    pub fn new(reader: R) -> Self {
        let digester = md5::Md5::new();
        Self{
            reader,
            digester,
            bytes_read: 0
        }
    }

    pub fn finalize(self) -> (R, HashU64) {
        (self.reader, hasher_to_u64s(self.digester))
    }
}

impl<R: std::io::Read> std::io::Read for DigestReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let res = self.reader.read(buf);
        if let Ok(new_bytes_read) = res {
            self.bytes_read += new_bytes_read as u64;
            self.digester.update(&buf[..new_bytes_read]);
        }
        res
    }
}


pub struct DigestWriter<W: std::io::Write> {
    writer: W,
    digester: md5::Md5,
    pub bytes_written: u64,
}
impl<W: std::io::Write> DigestWriter<W> {
    pub fn new(writer: W) -> Self {
        let digester = md5::Md5::new();
        Self{
            writer,
            digester,
            bytes_written: 0,
        }
    }

    pub fn finalize(self) -> (W, HashU64) {
        (self.writer, hasher_to_u64s(self.digester))
    }
}

impl<W: std::io::Write> std::io::Write for DigestWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let res = self.writer.write(buf);
        if let Ok(new_bytes_written) = res {
            self.digester.update(&buf[..new_bytes_written]);
            self.bytes_written += new_bytes_written as u64;
        }
        res
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.writer.flush()
    }
}
