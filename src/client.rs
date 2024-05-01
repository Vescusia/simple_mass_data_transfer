use std::io::{Write};
use rmp_serde::{Serializer, Deserializer};
use serde::{Deserialize, Serialize};
use bytesize::ByteSize;
use chacha20poly1305::KeyInit;

use std::net;
use std::io;

use crate::cli;
use simple_mass_data_transfer::{Handshake, HandshakeResponse, FileHash, EntryHeader::{FileHeader, DirHeader}, EntryHeader, FileHashResponse};
use simple_mass_data_transfer::buffered_io::{HashReader, PerhapsCompressedReader, PerhapsEncrReader, encrypt_io::{prepare_key, maybe_decrypt_path}};


pub fn connect(args: cli::Args) -> anyhow::Result<()> {
    // get relative path
    let rel_path = if let cli::Action::Download { path, .. } = &args.action {
        let p = std::path::PathBuf::from(path);

        // the path exists but is not a file
        if p.exists() && !p.is_dir() {
            anyhow::bail!("Path {p:?} is not a directory!")
        }
        // if the path does not exist, create it
        else if !p.exists() {
            std::fs::create_dir_all(&p)?;
            println!("Created {p:?}.");
        }

        p
    } else { panic!("This should not happen?") };

    // connect to server
    let stream = if let cli::Action::Download { address, .. } = &args.action {
        net::TcpStream::connect(address)?
    } else { panic!("This should not happen?") };
    println!("Connected to server: {:?}", stream.peer_addr()?);

    download(stream, rel_path, args.compression, args.encryption_key)?;

    Ok(())
}

fn download(stream: net::TcpStream, rel_path: std::path::PathBuf, compression: bool, key: Option<String>) -> anyhow::Result<()> {
    let mut serializer = Serializer::new(&stream);
    let mut deserializer = Deserializer::new(&stream);

    // send handshake
    // TODO: resume list should be checked from a .smdres file (also note SIZE!!)
    Handshake{
        version: env!("CARGO_PKG_VERSION").to_owned(),
        resume_list: vec![],
        compression
    }.serialize(&mut serializer)?;

    // receive response
    let response = HandshakeResponse::deserialize(&mut deserializer)?;
    println!("Received Response with advertised total Size of {}", ByteSize(response.total_size));
    if response.compression && !compression {
        println!("Server is forcing compression.")
    }
    let compression = compression | response.compression;
    
    // create encryptor
    let mut decryptor = key.map(|key| 
        chacha20poly1305::ChaCha20Poly1305::new(&prepare_key(key))
    );
    
    let mut stdout = io::stdout().lock();
    
    // write files
    let mut total_received = 0;
    while stream.peek(&mut [0])? > 0 {
        // receive header
        match EntryHeader::deserialize(&mut deserializer)? {
            DirHeader{ path: extend_path } => {
                let mut path = rel_path.clone(); 
                path.push(maybe_decrypt_path(extend_path, &mut decryptor)?);
                std::fs::create_dir_all(&path)?;
            },
            FileHeader{ path: extend_path, size } => loop {
                // decrypt and build path
                let mut path = rel_path.clone(); 
                path.push(maybe_decrypt_path(extend_path.clone(), &mut decryptor)?);
                stdout.write_all(format!("Received FileHeader {path:?} with {}\n", ByteSize(size)).as_bytes())?;
                // create parent folder(s)
                if let Some(p) = path.parent() {
                    std::fs::create_dir_all(p)?;
                }

                // open file
                let mut file = std::fs::OpenOptions::new()
                    .write(true)
                    .create(true)
                    .truncate(true)
                    .open(&path)?;

                // wrap file hasher
                let reader = HashReader::new(&stream);
                // wrap file into decryptor
                let reader = PerhapsEncrReader::with_decryptor(reader, &mut decryptor);
                // wrap file into decompressor
                let mut reader = PerhapsCompressedReader::with_compression(reader, compression, size);
                
                // write
                total_received += io::copy(&mut reader, &mut file).unwrap();

                // calculate hash
                let local_hash = reader.into_inner()
                    .into_inner()
                    .finalize().1;
                // compare hashes
                let hash = FileHash::deserialize(&mut deserializer)?;
                if hash.hash == local_hash {
                    stdout.write_all(format!("Hashes match ({local_hash:x}). Total received {}/{}\n", ByteSize(total_received), ByteSize(response.total_size)).as_bytes())?;
                    FileHashResponse{ matches: true }.serialize(&mut serializer)?;
                    break;
                } else {
                    stdout.write_all(format!("\nHashes do NOT match for file {:?} {local_hash:x} - {:x}!\n", &path, hash.hash).as_bytes())?;
                    FileHashResponse{ matches: false }.serialize(&mut serializer)?;
                }
            }
        }
    }

    Ok(())
}
