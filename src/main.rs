use clap::Parser;
use anyhow::{Result, Error};
use md5::Digest;

mod cli;
mod download;
mod host;
mod var_int_decoder;

mod files {
    include!(concat!(env!("OUT_DIR"), "/smd_transfer.files.rs"));
}

fn main() -> Result<()> {
    let args = cli::Args::parse();

    match args.command {
        // handle Host command
        cli::Commands::Host { path, bind_address } => {
            // sanitize path
            let path: std::path::PathBuf = path.parse()?;
            if !path.exists() {
                return Err(Error::msg(format!("Provided Path {path:?} does not exist!")))
            }
            if !path.is_dir() && !path.is_file() {
                return Err(Error::msg(format!("Provided Path {path:?} is neither a file not a directory! Only file and directory uploading is currently supported!")))
            }

            // sanitize address
            let addr: std::net::SocketAddr = bind_address.parse()?;

            host::host(addr, path)
        },

        // handle Download command
        cli::Commands::Download { address, path } => {
            // sanitize path input
            let path: std::path::PathBuf = path.parse()?;
            if !path.exists() {
                return Err(Error::msg(format!("Provided Path {path:?} does not exist!")))
            }
            else if !path.is_dir() {
                return Err(Error::msg(format!("Provided Path {path:?} is not a directory!")))
            }

            // sanitize address input
            let addr: std::net::SocketAddr = address.parse()?;

            download::download(addr, path)
        }
    }
}


/// Reset a vector buffer to 0u8's up to `min(reset_size, vec.capacity())`
fn reset_vec_buf(vec: &mut Vec<u8>, reset_size: usize) {
    // clear vec
    vec.clear();
    // push zeroes up to reset size
    for _ in 0..reset_size.min(vec.capacity()) {
        vec.push(0)
    }
}

#[derive(Debug, Clone, Copy)]
struct HashU64{
    pub high: u64,
    pub low: u64
}

impl HashU64 {
    /// Split `self` into its inner parts.
    /// The left `u64` is high, the right `u64` is low
    pub fn into_inner(self) -> (u64, u64) {
        (self.high, self.low)
    }
}

/// Split a md5 hasher into two u64's
fn hasher_to_u64s(hasher: md5::Md5) -> HashU64 {
    // A md5 hash is literally 16 bytes long. It cannot be less.
    let hash = hasher.finalize();
    let hash_array: [u8; 16] = hash[0..16].try_into().unwrap();
    HashU64{
        high: u64::from_be_bytes(hash_array[0..8].try_into().unwrap()),
        low: u64::from_be_bytes(hash_array[8..16].try_into().unwrap())
    }
}
