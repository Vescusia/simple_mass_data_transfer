use super::var_int_decoder::read_var_int_from_stream;
use super::{files::{path_file::Type as PathFileType, PathFile}};

use std::io::{Read, Write};
use prost::Message;

pub fn download(addr: std::net::SocketAddr, mut path: std::path::PathBuf) -> anyhow::Result<()> {
    // connect to address
    let mut stream = std::net::TcpStream::connect(addr)?;
    println!("Successfully connected to {addr}!");

    // read length
    let path_file_length = read_var_int_from_stream(&mut stream)?;
    println!("decoded length: {path_file_length}");
    // buffer for PathFile (I hope this gets nicely optimized...)
    let mut buffer = vec![0u8; path_file_length as usize];
    stream.read_exact(&mut buffer)?;

    // decode PathFile
    let path_file = PathFile::decode(buffer.as_slice())?;

    // handle PathFile
    match PathFileType::try_from(path_file.r#type).unwrap() {
        PathFileType::File => {
            println!("Received PathFile: size: {}, name: {}", path_file.size, path_file.name);
            // open file
            path.push(path_file.name);
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)?;

            // receive and write bytes to file
            let mut reader = stream.take(path_file.size);

            let mut bytes_read = 0;
            while bytes_read < path_file.size {
                let mut buf = vec![0u8; ((path_file.size - bytes_read) as usize).min(2 << 14)];
                bytes_read += reader.read(&mut buf)? as u64;
                print!("\r{} out of {} bytes received", bytes_read, path_file.size);
                file.write_all(buf.as_mut_slice())?;
            };

            println!("file {path:?} completely downloaded.")
        },
        PathFileType::Directory => {
            todo!()
        }
    }

    Ok(())
}