use super::files::{FileSum, FileSumResponse, FileSumResponseType, PathFile};
use super::{reset_vec_buf, hasher_to_u64s};

use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::Instant;

use prost::Message;
use md5::Digest;
use crate::var_int_decoder::read_var_int_from_stream;


/// Host file or directory at `path` on the socket `addr`
pub fn host(addr: std::net::SocketAddr, path: PathBuf) -> anyhow::Result<()> {
    let sock = std::net::TcpListener::bind(addr)?;
    println!("Bound to socket {addr} and listening!");

    for stream in sock.incoming() {
        handle_client(stream?, path.clone())?
    }

    Ok(())
}

fn handle_client(mut stream: std::net::TcpStream, path: PathBuf) -> anyhow::Result<()> {
    println!("Client connected: {:?}", stream.peer_addr());

    let now = Instant::now();  // measure upload time!
    let bytes_sent = if path.is_file() {
        // host file
        let base_path = path.parent().unwrap();  // has to be at least Path("") if it is a file.
        let file = path.file_name().unwrap();
        send_file(&mut stream, base_path.to_path_buf(), file.into())?
    }
    else if path.is_dir() {
        // host directory
        send_directory(stream, path)?
    }
    else {
        return Err(
            anyhow::Error::msg(format!("Provided Path {path:?} is neither a directory nor a file!"))
        );
    };

    let time_taken = now.elapsed().as_secs();
    println!("{bytes_sent} Bytes sent in {}s ({:.3} MB/s)", time_taken, (bytes_sent as f64 / 1_000_000.) / time_taken as f64);
    Ok(())
}

/// Send file at path over stream to client, returns the amount of bytes sent
fn send_file(stream: &mut std::net::TcpStream, base_path: PathBuf, rel_path: PathBuf) -> anyhow::Result<u64> {
    // open file for reading
    let mut full_path = base_path.clone();
    full_path.push(&rel_path);  // add relative path to the base path
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(false)
        .open(full_path)?;

    // send file message
    let file_size = file.metadata()?.len();
    let path_file = PathFile{
        rel_path: rel_path.to_string_lossy().into_owned(),  // idc man
        size: file_size,
    };
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

    // handle response
    match FileSumResponseType::try_from(response.response)? {
        FileSumResponseType::Match => {
            Ok(file_size)
        },
        // recurse to resend file if no match
        FileSumResponseType::NoMatch => {
            Ok(file_size + send_file(stream, base_path, rel_path)?)
        }
    }
}


#[derive(Debug, Clone)]
enum StackEntry{
    File { rel_path: PathBuf },
    Dir { rel_path: PathBuf }
}

/// Send all files in a directory and all of its descendant directories
fn send_directory(mut stream: std::net::TcpStream, base_path: PathBuf) -> anyhow::Result<u64> {
    let mut search_stack = vec![StackEntry::Dir{ rel_path: "".into() }];
    let mut total_sent = 0;

    while let Some(entry) = search_stack.pop() {
        match entry {
            StackEntry::Dir { rel_path } => {
                explore_directory(&mut search_stack, base_path.clone(), rel_path)?
            },
            StackEntry::File { rel_path } => {
                total_sent += send_file(&mut stream, base_path.clone(), rel_path)?;
            }
        }
    }

    Ok(total_sent)
}

/// Explore a directory and push all entries onto the stack
fn explore_directory(stack: &mut Vec<StackEntry>, base_path: PathBuf, rel_path: PathBuf) -> anyhow::Result<()> {
    // create absolute path of the directory
    let mut absolute_path = base_path.clone();
    absolute_path.push(&rel_path);

    // iterate over directory entries
    for entry in absolute_path.read_dir()?.flatten() {
        let path = entry.path();
        // add last path component to rel_path
        let mut rel_path = rel_path.clone();
        rel_path.push(path.components().last().unwrap());

        if path.is_dir() {
            // add new directory to the bottom of the stack
            stack.insert(0, StackEntry::Dir{ rel_path });
        }
        else if path.is_file() {
            // add new file to the top of the stack
            stack.push(StackEntry::File { rel_path });
        }
    }

    Ok(())
}
