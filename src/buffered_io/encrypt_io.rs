use chacha20poly1305::{AeadCore, AeadInPlace, ChaCha20Poly1305, Nonce, Key};
use chacha20poly1305::aead::{ OsRng };
use sha2::digest::Digest;

use std::cmp::min;
use std::io::{BufRead, Read, Write};
use std::path::{Path, PathBuf};


pub fn prepare_key<S: AsRef<str>>(key: S) -> Key {
    // hash the key to 64 B length
    let mut digester = sha2::Sha512::new();
    digester.update(key.as_ref());
    let hash = digester.finalize();
    let hash = hash.split_first_chunk::<32>().unwrap().0;
    Key::from(*hash)
}


pub fn maybe_encrypt_path(path: &Path, encryptor: &mut Option<ChaCha20Poly1305>) -> anyhow::Result<Vec<u8>> {
    let mut path = path.to_string_lossy().into_owned().into_bytes();
    
    if let Some(encryptor) = encryptor {
        // generate
        let nonce = ChaCha20Poly1305::generate_nonce(&mut OsRng);
        
        // encrypt
        encryptor.encrypt_in_place(&nonce, b"", &mut path).unwrap();
        
        // append nonce
        path.extend(nonce.as_slice());
        Ok(path)
    }
    else {
        Ok(path)
    }
}


pub fn maybe_decrypt_path(mut path_bytes: Vec<u8>, decryptor: &mut Option<ChaCha20Poly1305>) -> anyhow::Result<PathBuf> {
    let bytes = if let Some(decryptor) = decryptor {
        // grab hex from first 12 bytes
        let nonce = path_bytes.as_slice().split_last_chunk::<12>().unwrap().1;
        let nonce = Nonce::from(*nonce);

        // decrypt rest
        path_bytes.truncate(path_bytes.len()-12);
        decryptor.decrypt_in_place(&nonce, b"", &mut path_bytes).expect("\nYou are using encryption with the wrong key!\n");
        path_bytes
    }
    else {
        path_bytes
    };

    Ok(PathBuf::from(String::from_utf8(bytes)?))
}


pub enum PerhapsEncrWriter<'a, W: Write> {
    Plain(W),
    Encrypted{
        buffer: Vec<u8>,
        encryptor: &'a mut ChaCha20Poly1305,
        writer: W
    }
}

impl<'a, W: Write> PerhapsEncrWriter<'a, W> {
    pub fn with_encryptor(writer: W, encryptor: &'a mut Option<ChaCha20Poly1305>) -> Self {
        if let Some(encryptor) = encryptor {
            Self::Encrypted {
                buffer: Vec::with_capacity(1 << 13),
                encryptor,
                writer
            }
        }
        else {
            Self::Plain(writer)
        }
    }

    pub fn into_inner(self) -> W {
        match self {
            Self::Plain(w) => w,
            Self::Encrypted {writer, ..} => writer
        }
    }
}

impl<'a, W: Write> Write for PerhapsEncrWriter<'a, W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Self::Plain(w) => w.write(buf),
            Self::Encrypted {writer, encryptor, buffer} => {
                // generate nonce
                let nonce = ChaCha20Poly1305::generate_nonce(&mut OsRng);
                // write nonce
                writer.write_all(nonce.as_slice())?;
                // write total length of data (including padding and tag)
                let length = buf.len() + 16;
                writer.write_all(&(length as u32).to_be_bytes())?;

                // encrypt and send data
                buffer.resize_with(buf.len(), || 0);
                buffer.copy_from_slice(buf);
                encryptor.encrypt_in_place(&nonce, b"", buffer).unwrap();
                writer.write_all(buffer)?;

                Ok(buf.len())
            }
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Self::Plain(w) => w.flush(),
            Self::Encrypted { writer, .. } => writer.flush()
        }
    }
}

pub enum PerhapsEncrReader<'a, R: Read> {
    Plain(R),
    Encrypted{
        buffer: Vec<u8>,
        decryptor: &'a mut ChaCha20Poly1305,
        reader: R,
        already_read: usize
    }
}

impl<'a, R: Read> PerhapsEncrReader<'a, R> {
    pub fn with_decryptor(reader: R, decryptor: &'a mut Option<ChaCha20Poly1305>) -> Self {
        if let Some(decryptor) = decryptor {
            Self::Encrypted {
                buffer: Vec::with_capacity(1 << 13),
                decryptor,
                reader,
                already_read: 0
            }
        }
        else {
            Self::Plain(reader)
        }
    }

    pub fn into_inner(self) -> R {
        match self {
            Self::Plain(r) => r,
            Self::Encrypted {reader, ..} => reader
        }
    }
}

impl<'a, R: Read + BufRead> Read for PerhapsEncrReader<'a, R> {
    /// This is pretty bad,
    /// if possible, use the [`BufRead`] interface (✿◡‿◡)
    fn read(&mut self, dist_buf: &mut [u8]) -> std::io::Result<usize> {
        let data = self.fill_buf()?;
        let to_copy = min(dist_buf.len(), data.len());
        let (left, _) = dist_buf.split_at_mut(to_copy);
        
        left.copy_from_slice(&data[..to_copy]);
        self.consume(to_copy);
        Ok(to_copy)
    }
}

impl<'a, R: Read + BufRead> BufRead for PerhapsEncrReader<'a, R> {
    fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
        match self {
            Self::Plain(r) => r.fill_buf(),
            Self::Encrypted { buffer, decryptor, reader, already_read } => {
                // if there are some residuals...
                if *already_read < buffer.len() {
                    Ok(&buffer[*already_read..buffer.len()])
                }
                // get and decrypt more bytes from reader
                else {
                    // get nonce
                    let mut nonce = [0u8; 12];
                    reader.read_exact(&mut nonce)?;
                    let nonce = Nonce::from(nonce);

                    // get length of encrypted block
                    let mut length = [0u8; 4];
                    reader.read_exact(&mut length)?;
                    let length = u32::from_be_bytes(length) as usize;

                    // decrypt into buffer
                    buffer.resize_with(length, || 0);
                    reader.read_exact(buffer)?;
                    if decryptor.decrypt_in_place(&nonce, b"", buffer).is_err() {
                        // this error's, when a wrong encryption key is used
                        return Err(std::io::Error::other("Wrong encryption key used!"))
                    }
                    *already_read = 0;

                    Ok(&buffer[..])
                }
            }
        }
    }

    fn consume(&mut self, amt: usize) {
        match self {
            Self::Plain(r) => r.consume(amt),
            Self::Encrypted { already_read, .. } => *already_read += amt
        }
    }
}
