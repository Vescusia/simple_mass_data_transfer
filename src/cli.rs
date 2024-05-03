use clap::Parser;

/// Simple-Mass-Data-Transfer is a capable but simple File Transfer utility.
#[derive(Parser, Debug)]
#[command(author, version, about, long_about = "https://github.com/Vescusia/simple_mass_data_transfer/blob/master/README.md")]
pub struct Args {
    #[command(subcommand)]
    pub action: Action,
    
    /// The encryption key (if encryption is desired).
    /// 
    /// ChaCha20-poly1305 is used. 
    /// That should suffice for most use-cases, 
    /// but please consider that for yourself!
    #[arg(short('k'), long)]
    pub encryption_key: Option<String>,
    
    /// Should the traffic be compressed? (lz4)
    #[arg(short, long, default_value_t = false)]
    pub compression: bool,
} 

#[derive(clap::Subcommand, Debug)]
pub enum Action {
    /// Host a File or Directory
    Host {
        /// The Socket Address to Bind to
        #[arg(short, long, default_value = "0.0.0.0:4444")]
        bind_address: String,
        
        /// The Files and Directories to host
        /// 
        /// Also supports wildcards, like '*'!
        #[arg()]
        path: String,
    },
    
    /// Download from a Hoster
    #[command(alias("dl"))]
    Download {
        /// The Socket Address to download from.
        #[arg()]
        address: String,
        
        /// The Directory the Files will be downloaded to
        #[arg(short, long, default_value = "./")] 
        path: String,
    }
}