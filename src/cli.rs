use clap::Parser;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
#[command(propagate_version = true)]
pub struct Args {
    #[command(subcommand)]
    pub command: Commands,
    #[arg(short('k'), long)]
    pub pass_key: Option<String>
}

#[derive(clap::Subcommand, Debug)]
pub enum Commands {
    /// Host a file or a directory
    Host {
        /// The address to bind to
        #[arg(short('b'), long, default_value = "0.0.0.0:4444")]
        bind_address: String,

        /// The file/directory to host
        #[arg()]
        path: String,
    },

    /// Download a file from a hoster
    #[command(alias("dl"))]
    Download {
        /// the address to download from
        #[arg()]
        address: String,

        /// The directory the file(s) will be downloaded to
        #[arg(short, long, default_value = "./")]
        path: String,
    }
}
