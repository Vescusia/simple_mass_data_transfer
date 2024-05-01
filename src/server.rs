use walkdir::WalkDir;
use once_cell::sync::Lazy;
use rmp_serde::{Serializer, Deserializer};
use serde::{Serialize, Deserialize};
use bytesize::ByteSize;
use chacha20poly1305::KeyInit;

use std::net;
use std::collections::HashMap;
use std::io;
use std::sync::{Arc, RwLock};

use crate::cli::Action;
use simple_mass_data_transfer::{EntryHeader::{FileHeader, DirHeader}, FileHash, FileHashResponse, Handshake, HandshakeResponse};
use simple_mass_data_transfer::buffered_io::{HashWriter, PerhapsCompressedWriter, PerhapsEncrWriter, encrypt_io::prepare_key};
use simple_mass_data_transfer::buffered_io::encrypt_io::maybe_encrypt_path;


type StaticHashmap<K, V> = Lazy<Arc<RwLock<HashMap<K, V>>>>;
static HASH_CASH: StaticHashmap<std::path::PathBuf, Option<(u128, std::time::SystemTime)>> = Lazy::new(|| Arc::new(RwLock::new(HashMap::new())));
// TODO: cash file data


pub fn serve(args: crate::cli::Args) -> anyhow::Result<()> {
    // TODO: handle relative path!
    // as in, should hosting ./target/files/file.txt 
    // be sent as ./target/files/file.txt or ./file.txt?
    // 
    // Yeah, HASH_CASH should have both an absolute and relative path.
    
    // collect all files
    if let Action::Host{ path, .. } = &args.action {
        for path in glob::glob(path)?.filter_map(|p| p.ok()) {
                // recurse over directories
                if path.is_dir() {
                    HASH_CASH.write().unwrap().extend(
                        WalkDir::new(path).into_iter()
                            .filter_map(|p| p.ok())
                            .map(|p| p.path().to_path_buf())
                            .map(|p| (p, None))
                    )
                } else {
                    HASH_CASH.write().unwrap().insert(path, None);
                }
            }
    }
    
    // calculate total size
    let total_size: u64 = HASH_CASH.read().unwrap().keys()
        .filter(|p| p.is_file())
        .filter_map(|p| p.metadata().ok().map(|p| p.len()))
        .sum();
    println!("total size: {}", ByteSize(total_size));
        

    // create listener
    let listener = if let Action::Host { bind_address, .. } = &args.action {
        println!("Binding to {bind_address}...");
        net::TcpListener::bind(bind_address)?
    }
    else { panic!("this should not happen?") };

    // main loop
    let key = Arc::new(args.encryption_key);
    loop {
        // accept client
        let (client, socket) = listener.accept()?;
        println!("Client arrived: {socket}");
        
        // start handle thread
        let key = key.clone();
        std::thread::spawn(move || { handle_client(client, args.compression, total_size, key) });
    }
}


fn handle_client(stream: net::TcpStream, compression: bool, total_size: u64, key: Arc<Option<String>>) -> anyhow::Result<()> {
    let mut deserializer = Deserializer::new(&stream);
    let mut serializer = Serializer::new(&stream);
    let mut total_sent = 0;
    
    // receive Handshake
    let handshake = Handshake::deserialize(&mut deserializer)?;
    println!("Client sent handshake: {handshake:?}");
    if env!("CARGO_PKG_VERSION") != handshake.version {
        println!("Invalid version of client!");
        return Ok(()) 
    }
    let compression = compression | handshake.compression;
    
    let mut encryptor = key.as_ref().as_ref().map(|key|
        chacha20poly1305::ChaCha20Poly1305::new(&prepare_key(key))
    );
    
    // send reply
    HandshakeResponse{
        total_size,
        compression
    }.serialize(&mut serializer)?;
    
    // send paths
    for path in HASH_CASH.read().unwrap().keys() {
        let path_bytes = maybe_encrypt_path(path, &mut encryptor)?;
        
        // send dir
        if path.is_dir() {
            DirHeader{ path: path_bytes }.serialize(&mut serializer)?;
        }
        // send file
        else { loop {
            // send header
            let size = path.metadata()?.len();
            FileHeader{ path: path_bytes.clone(), size }.serialize(&mut serializer)?;
            
            // wrap stream into hasher
            let writer = HashWriter::new(&stream);
            // into encryptor
            let writer = PerhapsEncrWriter::with_encryptor(writer, &mut encryptor);
            // and into compressor
            let mut writer = PerhapsCompressedWriter::with_compression(writer, compression);
            
            
            // open file
            let mut file = std::fs::OpenOptions::new().read(true)
                .open(path)?;
            // send file
            io::copy(&mut file, &mut writer)?;
            // finish compression
            // TODO cash hash
            let hasher = writer.finish()?.into_inner();
            total_sent += hasher.digested;
            
            // send Hash
            let hash = hasher.finalize().1;
            FileHash{ hash }.serialize(&mut serializer)?;
            
            // handle response of client
            if FileHashResponse::deserialize(&mut deserializer)?.matches {
                break
            }
        }}
    }
    
    println!("Total Sent {} - deflation: {}%", ByteSize(total_sent as u64), (total_sent*100)/(total_size as usize));
    
    Ok(())
}
