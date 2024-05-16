use bytesize::ByteSize;

use std::io::{Read, Write};
use std::sync::mpsc::{Sender, Receiver};


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


pub fn handle_events_cli(recv: Receiver<ClientEvent>) -> std::io::Result<()> {
    let mut stdout = std::io::stdout().lock();
    
    let mut progress_bar = String::with_capacity(10);
    let mut current_file_size = 1;
    let mut current_file_downloaded = 0;
    let mut current_file_timer = std::time::Instant::now();
    
    let mut total_bytes = 1;
    let mut total_downloaded = 0;

    while let Ok(msg) = recv.recv() {
        match msg {
            ClientEvent::ResumeListFound(file_amount) => {
                writeln!(&mut stdout, "Resume List Found, containing {file_amount} hashes.")?;
            },
            ClientEvent::HandShakeResponse{ total_size, compression } => {
                writeln!(&mut stdout, "CONNECTED with advertised total size of {}", ByteSize(total_size))?;
                if compression {
                    writeln!(&mut stdout, "(server is forcing compression)")?;
                }
                total_bytes = total_size;
            },
            ClientEvent::FileHeader{ rel_path, size } => {
                writeln!(&mut stdout, "{rel_path}\t{}", ByteSize(size))?;
                current_file_size = size;
                current_file_timer = std::time::Instant::now();
                current_file_downloaded = 0;
            },
            ClientEvent::FileUpdate(bytes_read) => {
                current_file_downloaded += bytes_read as u64;
                total_downloaded += bytes_read as u64;

                // build progress bar
                progress_bar.clear();
                let progress = current_file_downloaded * 30 / current_file_size;
                for _ in 0..progress {
                    progress_bar.push('=')
                }
                progress_bar.push('>');
                for _ in progress..29 {
                    progress_bar.push(' ')
                }
                
                write!(&mut stdout, "\r[{progress_bar}] {}/{}  ", ByteSize(current_file_downloaded), ByteSize(current_file_size))?;
            },
            ClientEvent::FileFinished(hashes_match) => if hashes_match {
                let time_taken = current_file_timer.elapsed();
                let dl_speed = current_file_size as f32 / time_taken.as_secs_f32();
                writeln!(&mut stdout, 
                         "\rFile Completely Downloaded in {time_taken:7.1?} ({:08}/s){:>10} {}/{} Downloaded ({}%)",
                         ByteSize(dl_speed as u64),
                         '|',
                         ByteSize(total_downloaded), 
                         ByteSize(total_bytes), 
                         total_downloaded * 100 / total_bytes)?;
            } else {
                writeln!(&mut stdout, "\rFile Completely Downloaded... Hashes did NOT Match... Retrying...")?;
            },
            ClientEvent::Completed(time_taken) => {
                let dl_speed = total_bytes / time_taken.as_secs();
                writeln!(&mut stdout, "\nDownloading {} finished in {time_taken:?} ({}/s)", ByteSize(total_bytes), ByteSize(dl_speed))?;
                break;
            }
        }
    }

    Ok(())
}
