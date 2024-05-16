use std::io::{Write};
use rmp_serde::{Serializer, Deserializer};
use serde::{Deserialize, Serialize};
use chacha20poly1305::KeyInit;

use std::net;
use std::io;
use std::sync::mpsc::Sender;

use crate::cli;
use simple_mass_data_transfer::{Handshake, HandshakeResponse, FileHash, EntryHeader::{FileHeader, DirHeader}, EntryHeader, FileHashResponse};
use simple_mass_data_transfer::buffered_io::{HashReader, PerhapsCompressedReader, PerhapsEncrReader, encrypt_io::{prepare_key, maybe_decrypt_path}};
use simple_mass_data_transfer::client_events::{ClientEvent, ClientEventReader};


pub fn connect(args: cli::Args, handler: Sender<ClientEvent>) -> anyhow::Result<()> {
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
        }

        p
    } else { panic!("This should not happen?") };

    // connect to server
    let stream = if let cli::Action::Download { address, .. } = &args.action {
        net::TcpStream::connect(address)?
    } else { panic!("This should not happen?") };

    download(stream, rel_path, args.compression, args.encryption_key, handler)?;

    Ok(())
}

fn download(stream: net::TcpStream, rel_path: std::path::PathBuf, compression: bool, key: Option<String>, handler: Sender<ClientEvent>) -> anyhow::Result<()> {
    let mut serializer = Serializer::new(&stream);
    let mut deserializer = Deserializer::new(&stream);

    // load resume list from file
    let mut smd_res_path = rel_path.to_owned(); smd_res_path.push(".smdres");
    let resume_list = load_resume_list(&smd_res_path)?;
    if let Some(list) = &resume_list {
        handler.send(ClientEvent::ResumeListFound(list.len()))?
    }
    
    // send handshake
    Handshake{
        version: env!("CARGO_PKG_VERSION").to_owned(),
        resume_list,
        compression
    }.serialize(&mut serializer)?;

    // receive response
    let response = HandshakeResponse::deserialize(&mut deserializer)?;
    handler.send(ClientEvent::HandShakeResponse{ total_size: response.total_size, compression: response.compression })?;
    let compression = compression | response.compression;
    
    // create encryptor
    let mut decryptor = key.map(|key| 
        chacha20poly1305::ChaCha20Poly1305::new(&prepare_key(key))
    );
    
    
    // open resume list file
    let mut smd_res_file = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&smd_res_path)?;
    
    // write files
    let start = std::time::Instant::now();
    while stream.peek(&mut [0])? > 0 {
        // receive header
        match EntryHeader::deserialize(&mut deserializer)? {
            DirHeader{ path: extend_path } => {
                let path = rel_path.join(maybe_decrypt_path(extend_path, &mut decryptor)?);
                std::fs::create_dir_all(path)?;
            },
            FileHeader{ path: extend_path, size } => loop {
                // decrypt and build path
                let path = maybe_decrypt_path(extend_path.clone(), &mut decryptor)?;
                handler.send(ClientEvent::FileHeader{ rel_path: path.to_string_lossy().into(), size })?;
                
                // open file
                let mut file = std::fs::OpenOptions::new()
                    .write(true)
                    .create(true)
                    .truncate(true)
                    .open(&rel_path.join(path))?;
                
                // wrap file into decryptor
                let reader = PerhapsEncrReader::with_decryptor(&stream, &mut decryptor);
                // into decompressor
                let reader = PerhapsCompressedReader::with_compression(reader, compression, size);
                // into hasher
                let reader = HashReader::new(reader);
                // and into message sender
                let mut reader = ClientEventReader::new(reader, &handler);
                
                // write
                io::copy(&mut reader, &mut file)?;

                // calculate and receive both hashes 
                let (_, local_hash) = reader.inner().finalize();
                let hash = FileHash::deserialize(&mut deserializer)?;
                
                // compare hashes
                if hash.hash == local_hash {
                    handler.send(ClientEvent::FileFinished(true))?;
                    FileHashResponse{ matches: true }.serialize(&mut serializer)?;
                    // write hash to smd_res
                    smd_res_file.write_all(&local_hash.to_ne_bytes())?;
                    break;
                } 
                else {
                    handler.send(ClientEvent::FileFinished(false))?;
                    FileHashResponse{ matches: false }.serialize(&mut serializer)?;
                }
            }
        }
    }

    // delete resume list file after completion
    std::fs::remove_file(smd_res_path)?;
    // send finish event
    handler.send(ClientEvent::Completed(start.elapsed()))?;
    
    Ok(())
}


fn load_resume_list(smd_res_path: &std::path::Path) -> io::Result<Option<std::collections::HashSet<FileHash>>> {
    // open file
    let resume_list = match std::fs::read(smd_res_path) {
        Ok(list) => list,
        Err(e) => return match e.kind() {
            io::ErrorKind::NotFound => Ok(None),
            _ => Err(e)
        }
    };
    
    // combine bytes into u128's and return
    let hashes = resume_list.chunks(16)
        .map(|bytes| u128::from_ne_bytes(*bytes.split_first_chunk::<16>().unwrap().0))
        .map(|hash| FileHash{hash})
        .collect::<std::collections::HashSet<FileHash>>();
    Ok(Some(hashes))
}
