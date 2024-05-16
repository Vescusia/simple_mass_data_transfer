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
use std::path::{Path, PathBuf};

use crate::cli::Action;
use simple_mass_data_transfer::{EntryHeader::{FileHeader, DirHeader}, FileHash, FileHashResponse, Handshake, HandshakeResponse};
use simple_mass_data_transfer::buffered_io::{PerhapsHashingWriter, PerhapsCompressedWriter, PerhapsEncrWriter, encrypt_io::{prepare_key, maybe_encrypt_path}, CountingWriter};


// type definitions for simplification
type StaticHashmap<K, V> = Lazy<Arc<RwLock<HashMap<K, V>>>>;
type PathVec = Vec<(Arc<PathBuf>, Arc<Path>)>;

// statics
static HASH_CASH: StaticHashmap<Arc<PathBuf>, (u128, std::time::SystemTime)> = Lazy::new(|| Arc::new(RwLock::new(HashMap::new())));
static FILES: Lazy<Arc<RwLock<PathVec>>> = Lazy::new(|| Arc::new(RwLock::new(Vec::new())));


/// Start serving the `args`
pub fn serve(args: crate::cli::Args) -> anyhow::Result<()> {
    // extract compression level
    let comp_level = if let Action::Host { comp_level, .. } = args.action {
        comp_level
    } else { panic!("this should not happen") };
    
    // collect all files
    if let Action::Host{ path, .. } = &args.action {
        for path in glob::glob(path)?.filter_map(|p| p.ok()) {
            let prefix = path.parent().unwrap_or(Path::new("/"));
            
            // recurse over directories
            if path.is_dir() {
                FILES.write().unwrap().extend(
                    WalkDir::new(&path).into_iter()
                        .filter_map(|p| p.ok())
                        .map(|p| p.path().to_path_buf())
                        .map(|p| (Arc::new(p.canonicalize().unwrap()), Arc::from(p.strip_prefix(prefix).unwrap())))
                )
            } else {
                FILES.write().unwrap().push(
                    (Arc::new(path.canonicalize().unwrap()), Arc::from(path.strip_prefix(prefix).unwrap()))
                );
            }
        }
    }
    
    // calculate total size
    let total_size: u64 = FILES.read().unwrap().iter()
        .filter(|p| p.0.is_file())
        .filter_map(|p| p.0.metadata().ok().map(|p| p.len()))
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
        std::thread::spawn(move || { handle_client(client, args.compression, total_size, key, comp_level) });
    }
}


fn handle_client(stream: net::TcpStream, compression: bool, total_size: u64, key: Arc<Option<String>>, comp_level: u8) -> anyhow::Result<()> {
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
    
    // create encryptor
    let mut encryptor = key.as_ref().as_ref().map(|key|
        chacha20poly1305::ChaCha20Poly1305::new(&prepare_key(key))
    );
    
    // send reply
    HandshakeResponse{
        total_size,
        compression
    }.serialize(&mut serializer)?;
    
    // main loop
    let start = std::time::Instant::now();
    for (abs_path, rel_path) in FILES.read().unwrap().iter() {
        let path_bytes = maybe_encrypt_path(rel_path, &mut encryptor)?;
        let metadata = abs_path.metadata()?;
 
        // send dir
        if metadata.is_dir() {
            DirHeader{ path: path_bytes }.serialize(&mut serializer)?;
        }
        // send file
        else { loop {
            // check for cached hash
            let hash = HASH_CASH.read().unwrap().get(abs_path)
                .filter(|(_, modified)| modified == &metadata.modified().expect("FUCK MAN, why are u using an OS without modified metadata????"))
                .map(|(h, _)| *h);
            let precomputed_hash = hash.is_some();

            // check in Resume List
            if let Some(hash) = hash {
                if let Some(resume_list) = &handshake.resume_list {
                    if resume_list.get(&hash.into()).is_some() {
                        break
                    }
                }
            }
            
            // send header
            FileHeader{ path: path_bytes.clone(), size: metadata.len() }.serialize(&mut serializer)?;

            // wrap stream into Byte counter and encryptor
            let writer = PerhapsEncrWriter::with_encryptor(CountingWriter::new(&stream), &mut encryptor);
            // into compressor
            let writer = PerhapsCompressedWriter::with_compression(writer, compression, comp_level);
            // and into hasher
            let mut writer = PerhapsHashingWriter::with_hash(writer, hash);
            
            // open file
            let mut file = std::fs::OpenOptions::new().read(true)
                .open(abs_path.as_path())?;
            // send file
            io::copy(&mut file, &mut writer)?;

            // get hash
            let (compressor, hash) = writer.finalize();
            // finish compression and add sent bytes
            total_sent += compressor.finish()?.into_inner().written;
            
            // send Hash
            FileHash{ hash }.serialize(&mut serializer)?;
            // cache hash
            if !precomputed_hash {
                HASH_CASH.write().unwrap().insert(abs_path.clone(), (hash, metadata.modified()?));
            }

            // handle response of client
            if FileHashResponse::deserialize(&mut deserializer)?.matches {
                break
            }
        }}
    }
    
	let time_taken = start.elapsed();
    println!("Total Sent {} - deflation: {}%", ByteSize(total_sent as u64), (total_sent*100)/(total_size as usize));
    println!("{} in {time_taken:?} ({}/s)", ByteSize(total_size), ByteSize(total_size / time_taken.as_secs()));
    
    Ok(())
}
