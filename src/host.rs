use super::files::{FileSum, FileSumResponse, FileSumResponseType, PathFile};
use super::{reset_vec_buf, hasher_to_u64s};

use std::io::{Read, Write};

use prost::Message;
use md5::Digest;
use crate::var_int_decoder::read_var_int_from_stream;


/// Host file or directory at `path` on the socket `addr`
pub fn host(addr: std::net::SocketAddr, path: std::path::PathBuf) -> anyhow::Result<()> {
    let sock = std::net::TcpListener::bind(addr)?;
    println!("Bound to socket {addr} and listening!");

    for stream in sock.incoming() {
        handle_client(stream?, path.as_path())?
    }

    Ok(())
}

fn handle_client(mut stream: std::net::TcpStream, path: &std::path::Path) -> anyhow::Result<()> {
    println!("Client connected!");

    if path.is_file() {
        let _bytes_sent = send_file(&mut stream, path)?;
        Ok(())
    }
    else if path.is_dir() {
        todo!()
    }
    else {
        Err(anyhow::Error::msg(format!("Provided Path {path:?} is neither a directory nor a file!")))
    }
}

/// Send file at path over stream to client, returns the amount of bytes sent
fn send_file(stream: &mut std::net::TcpStream, path: &std::path::Path) -> anyhow::Result<u64> {
    // open file for reading
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(false)
        .open(path)?;

    // get file name
    let file_name = match path.file_name() {
        Some(name) => match name.to_str() {
            Some(name) => {
                name.to_owned()
            },
            None => {
                return Err(anyhow::Error::msg(format!("Path {path:?} has an invalid name!")))
            }
        },
        None => return Err(anyhow::Error::msg(format!("Path {path:?} does not have a name!")))
    };

    // send file message
    let file_size = file.metadata()?.len();
    let path_file = PathFile{
        rel_path: file_name,
        size: file_size,
    };
    println!("path_file: {path_file:?}, len: {}", path_file.encoded_len());
    stream.write_all(&path_file.encode_length_delimited_to_vec())?;

    // create buffer of 64kiB
    let mut buf = Vec::with_capacity(2 << 16);
    let mut bytes_sent = 0;
    // create hasher
    let mut hasher = md5::Md5::new();

    // send file data
    while file_size > bytes_sent {
        // (re-)initialize buffer
        reset_vec_buf(&mut buf, (file_size - bytes_sent) as usize);

        // fill buffer
        file.read_exact(&mut buf)?;
        bytes_sent += buf.len() as u64;

        // write buffer to stream and digest it
        stream.write_all(&buf)?;
        hasher.update(buf.as_slice());
    }

    // build checksum
    let hash = hasher_to_u64s(hasher);
    println!("Hash finalized: {hash:x?}");
    let file_sum = FileSum{
        md5_high: hash.high,
        md5_low: hash.low,
    };

    // send checksum
    stream.write_all(&file_sum.encode_length_delimited_to_vec())?;

    // receive checksum response
    let delimiter = read_var_int_from_stream(stream)?;
    let mut buf = vec![0; delimiter as usize];
    stream.read_exact(&mut buf)?;
    let response = FileSumResponse::decode(buf.as_slice())?;
    println!("Received checksum response: {response:?}");

    // handle response
    match FileSumResponseType::try_from(response.response)? {
        FileSumResponseType::Match => {
            Ok(file_size)
        },
        // recurse to resend file if no match
        FileSumResponseType::NoMatch => {
            Ok(file_size + send_file(stream, path)?)
        }
    }
}
