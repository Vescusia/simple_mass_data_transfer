use std::io::{Read, Write};
use prost::Message;
use super::files::{path_file::Type as PathFileType, PathFile };


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
        send_file(&mut stream, path)
    }
    else if path.is_dir() {
        todo!()
    }
    else {
        Err(anyhow::Error::msg(format!("Provided Path {path:?} is neither a directory nor a file!")))
    }
}

/// Send file at path over stream to client
fn send_file(stream: &mut std::net::TcpStream, path: &std::path::Path) -> anyhow::Result<()> {
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
    let path_file = PathFile{
        r#type: PathFileType::File.into(),
        name: file_name,
        size: file.metadata()?.len(),
    };
    println!("path_file: {path_file:?}, len: {}", path_file.encoded_len());
    stream.write_all(&path_file.encode_length_delimited_to_vec())?;

    // create buffer 1kiB
    let mut buf = Vec::with_capacity(1024);
    // fill buffer
    while file.read_to_end(&mut buf)? > 0 {
        // write buffer
        stream.write_all(&buf)?;
        buf.clear();
    }

    Ok(())
}
