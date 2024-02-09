use super::var_int_decoder::read_var_int_from_stream;
use super::files::{FileSum, FileSumResponse, FileSumResponseType, PathFile};
use super::{reset_vec_buf, hasher_to_u64s};

use std::io::{Read, Write};
use md5::Digest;
use prost::Message;

pub fn download(addr: std::net::SocketAddr, path: std::path::PathBuf) -> anyhow::Result<()> {
    // connect to address
    let mut stream = std::net::TcpStream::connect(addr)?;
    println!("Successfully connected to {addr}!");

    // the main file_path receiver loop
    while stream.peek(&mut [0; 1])? > 0 {
        // read length
        let length = read_var_int_from_stream(&mut stream).unwrap();
        // buffer for PathFile
        let mut buf = vec![0u8; length as usize];
        stream.read_exact(&mut buf).unwrap();

        // decode PathFile
        let path_file = PathFile::decode(buf.as_slice())?;

        //println!("Received PathFile: size: {}, name: {}", path_file.size, path_file.rel_path);
        // create file (overwrite if already existing)
        let mut path = path.clone();
        path.push(path_file.rel_path);
        std::fs::create_dir_all(path.parent().unwrap())?;  // create all necessary ancestors
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .open(&path)?;

        // create buffer of 64kiB
        let mut buf = Vec::with_capacity(2 << 16);
        let mut bytes_read = 0;

        // create hasher
        let mut hasher = md5::Md5::new();

        // write file
        while bytes_read < path_file.size {
            // (re-)initialize buffer
            reset_vec_buf(&mut buf, (path_file.size - bytes_read) as usize);

            // read bytes from stream
            stream.read_exact(&mut buf)?;
            bytes_read += buf.len() as u64;

            // write to file and hasher
            file.write_all(buf.as_slice())?;
            hasher.update(buf.as_slice());
        };

        // receive checksum
        let length = read_var_int_from_stream(&mut stream)?;
        let mut buf = vec![0u8; length as usize];
        stream.read_exact(&mut buf)?;
        let correct_sum = FileSum::decode(buf.as_slice())?;

        // compare checksums
        let (high, low) = hasher_to_u64s(hasher).into_inner();
        let hashes_match = correct_sum.md5_high == high && correct_sum.md5_low == low;

        // handle comparison
        let response = if hashes_match {
            FileSumResponse{ response: FileSumResponseType::Match.into() }
        }
        else {
            FileSumResponse{ response: FileSumResponseType::NoMatch.into() }
        };
        // send response
        // (when sending a NoMatch response, the server will simply resend this file_path, which we will catch in the next loop.)
        stream.write_all(&response.encode_length_delimited_to_vec())?;
    }

    // all files downloaded
    println!("All files downloaded. ");
    Ok(())
}