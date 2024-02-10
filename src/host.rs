use super::files::{ FileSum, FileSumResponse, FileSumResponseType, PathFile };
use super::utils::{ reset_vec_buf, DigestWriter };
use super::var_int_decoder::read_var_int_from_stream;

use std::io::{ Read, Write };
use std::path::PathBuf;
use std::time::Instant;

use prost::Message;
use magic_crypt::{ MagicCryptTrait, generic_array::typenum::U65536 };


/// Host file or directory at `path` on the socket `addr`
pub fn host(addr: std::net::SocketAddr, path: PathBuf, key: Option<String>) -> anyhow::Result<()> {
    let sock = std::net::TcpListener::bind(addr)?;
    println!("Bound to socket {addr} and listening!");

    for stream in sock.incoming() {
        handle_client(stream?, path.clone(), key.clone())?
    }

    Ok(())
}

fn handle_client(mut stream: std::net::TcpStream, path: PathBuf, key: Option<String>) -> anyhow::Result<()> {
    println!("Client connected: {:?}", stream.peer_addr());
    let encryptor = key.as_ref().map(|key| magic_crypt::new_magic_crypt!(key, 128));

    let now = Instant::now();  // measure upload time!
    let bytes_sent = if path.is_file() {
        // host file
        let base_path = path.parent().unwrap();  // has to be at least Path("") if it is a file.
        let file = path.file_name().unwrap();
        send_file(&mut stream, base_path.to_path_buf(), file.into(), encryptor.as_ref())?
    }
    else if path.is_dir() {
        // host directory
        send_directory(stream, path, encryptor.as_ref())?
    }
    // inputs should already be sanitized anyway
    else { 0 };

    let time_taken = now.elapsed().as_secs();
    println!("{bytes_sent} Bytes sent in {}s ({:.3} MB/s)", time_taken, (bytes_sent as f64 / 1_000_000.) / time_taken as f64);
    Ok(())
}

/// Send file at path over stream to client, returns the amount of bytes sent
fn send_file(stream: &mut std::net::TcpStream, base_path: PathBuf, rel_path: PathBuf, encryptor: Option<&magic_crypt::MagicCrypt128>) -> anyhow::Result<u64> {
    // open file for reading
    let mut full_path = base_path.clone();
    full_path.push(&rel_path);  // add relative path to the base path
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(false)
        .open(full_path)?;

    // get file size and maybe calculate in the block size padding
    let mut file_size = file.metadata()?.len();
    if encryptor.is_some() {
        // Align file size to the block size
        file_size = ((file_size >> 4) + 1) << 4;
    }

    // send file message
    let rel_path_str = rel_path.to_string_lossy().into_owned();  // Idc man
    let path_file = PathFile{
        rel_path: encryptor.map(|mc| mc.encrypt_str_to_base64(&rel_path_str)).unwrap_or(rel_path_str),  // encrypt rel_path if wanted
        size: file_size,
    };
    stream.write_all(&path_file.encode_length_delimited_to_vec())?;

    // create hasher
    let mut writer = DigestWriter::new(stream);

    // send file data
    if let Some(mc) = encryptor {
        mc.encrypt_reader_to_writer2::<U65536>(&mut file, &mut writer)?;
    }
    else {
        // create buffer of 64kiB
        let mut buf = Vec::with_capacity(1 << 16);
        while file_size > writer.bytes_written {
            // (re-)initialize buffer, as read_exact expects
            reset_vec_buf(&mut buf, (file_size - writer.bytes_written) as usize);
            // read from file
            file.read_exact(&mut buf)?;
            // write buffer to stream and digest it
            writer.write_all(&buf)?;
        }
    }

    // build checksum
    let (stream, hash) = writer.finalize();
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
            println!("NoMatch received.");
            Ok(file_size + send_file(stream, base_path, rel_path, encryptor)?)
        }
    }
}


#[derive(Debug, Clone)]
enum StackEntry{
    File { rel_path: PathBuf },
    Dir { rel_path: PathBuf }
}

/// Send all files in a directory and all of its descendant directories
fn send_directory(mut stream: std::net::TcpStream, base_path: PathBuf, encryptor: Option<&magic_crypt::MagicCrypt128>) -> anyhow::Result<u64> {
    let mut search_stack = vec![StackEntry::Dir{ rel_path: "".into() }];
    let mut total_sent = 0;

    while let Some(entry) = search_stack.pop() {
        match entry {
            StackEntry::Dir { rel_path } => {
                explore_directory(&mut search_stack, base_path.clone(), rel_path)?
            },
            StackEntry::File { rel_path } => {
                total_sent += send_file(&mut stream, base_path.clone(), rel_path, encryptor)?;
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
            stack.push(StackEntry::Dir{ rel_path });
        }
        else if path.is_file() {
            // add new file to the top of the stack
            stack.push(StackEntry::File { rel_path });
        }
    }

    Ok(())
}
