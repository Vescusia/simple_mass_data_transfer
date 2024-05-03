use serde::{Serialize, Deserialize};

pub mod buffered_io;


#[derive(Debug, Serialize, Deserialize)]
pub enum EntryHeader {
    FileHeader{ 
        /// Could be an utf-8 String or encrypted
        path: Vec<u8>,
        /// If compression is used, this is probably inaccurate
        size: u64
    },
    DirHeader{
        /// Could be an utf-8 String or encrypted
        path: Vec<u8>
    }
}

#[derive(Debug, Serialize, Deserialize, Eq, PartialEq, Hash)]
pub struct FileHash {
    pub hash: u128
}

#[derive(Debug, Serialize, Deserialize)]
pub struct FileHashResponse {
    pub matches: bool
}

/// Sent from the Client to the Server.
/// Server can decline by closing connection. (right now)
#[derive(Debug, Serialize, Deserialize)]
pub struct Handshake {
    pub version: String,
    pub resume_list: Option<std::collections::HashSet<FileHash>>,
    pub compression: bool,
}

/// Reply (if client got accepted)
/// Client can decline by closing connection. (right now)
#[derive(Debug, Serialize, Deserialize)]
pub struct HandshakeResponse {
    /// of all files, in Bytes.
    pub total_size: u64,
    pub compression: bool,
}
