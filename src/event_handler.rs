use std::io::Read;
use std::sync::mpsc::Sender;

#[derive(Debug)]
pub enum ClientEvent {
    HandShakeResponse{ total_size: u64, compression: bool },
    FileHeader{ rel_path: String, size: u64 },
    /// Additional Bytes Downloaded
    FileUpdate(usize),
    /// Is true, if hashes matches, otherwise false
    FileFinished(bool),
    Completed(std::time::Duration),
    /// Amount of files being (maybe) skipped
    ResumeListFound(usize)
}


pub struct ClientEventReader<'a, R: Read>{
    reader: R,
    sender: &'a Sender<ClientEvent>
}

impl<'a, R: Read> ClientEventReader<'a, R> {
    pub fn new(reader: R, sender: &'a Sender<ClientEvent>) -> Self {
        Self{ reader, sender }
    }
    
    pub fn inner(self) -> R {
        self.reader
    }
}

impl<'a, R: Read> Read for ClientEventReader<'a, R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let read = self.reader.read(buf);
        if let Ok(read) = read {
            self.sender.send(ClientEvent::FileUpdate(read)).expect("Channel has been poisoned! (Please report bug!)");
        }
        read
    }
}
