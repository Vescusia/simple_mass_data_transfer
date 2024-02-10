use std::net::ToSocketAddrs;
use clap::Parser;
use anyhow::{Result, Error};

mod cli;
mod download;
mod host;
mod var_int_decoder;
mod utils;

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

            host::host(addr, path, args.pass_key)
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
            let addr: std::net::SocketAddr = address.to_socket_addrs()?.next().unwrap_or_else(|| panic!("Could not parse Socket Address `{address}`."));

            download::download(addr, path, args.pass_key)
        }
    }
}
