use super::var_int_decoder::read_var_int_from_stream;
use super::files::{FileSum, FileSumResponse, FileSumResponseType, PathFile};
use super::{reset_vec_buf, hasher_to_u64s};

use std::io::{Read, Write};
use std::time::Instant;

use md5::Digest;
use prost::Message;

pub fn download(addr: std::net::SocketAddr, path: std::path::PathBuf) -> anyhow::Result<()> {
    // connect to address
    let mut stream = std::net::TcpStream::connect(addr)?;
    println!("Successfully connected to {addr}!");

    // scope stdout for good performance writing
    let mut stdout = std::io::stdout();
    // stat tracking
    let mut total_bytes_downloaded = 0;
    let outer_now = Instant::now();

    // the main file_path receiver loop
    while stream.peek(&mut [0; 1])? > 0 {
        let now = Instant::now();

        // read length
        let length = read_var_int_from_stream(&mut stream).unwrap();
        // buffer for PathFile
        let mut buf = vec![0u8; length as usize];
        stream.read_exact(&mut buf).unwrap();
        // decode PathFile
        let path_file = PathFile::decode(buf.as_slice())?;
        write!(stdout, "Decoded PathFile.")?;

        // create file (overwrite if already existing)
        let mut path = path.clone();
        path.push(path_file.rel_path);
        std::fs::create_dir_all(path.parent().unwrap())?;  // create all necessary ancestors
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .open(&path)?;
        write!(stdout, "\rDownloading File {path:?}")?;

        // create buffer of 64kiB
        let mut buf = Vec::with_capacity(2 << 16);
        let mut bytes_read = 0;
        // create hasher
        let mut hasher = md5::Md5::new();
        // write file
        while bytes_read < path_file.size {
            // (re-)initialize buffer
            reset_vec_buf(&mut buf, (path_file.size - bytes_read) as usize);

            // read bytes from stream
            stream.read_exact(&mut buf)?;
            bytes_read += buf.len() as u64;

            // write to file and hasher
            file.write_all(buf.as_slice())?;
            hasher.update(buf.as_slice());
            write!(stdout, "\r{:.3}% received   ", (bytes_read as f64) / (path_file.size as f64) * 100.)?;
        };

        // receive checksum
        let length = read_var_int_from_stream(&mut stream)?;
        let mut buf = vec![0u8; length as usize];
        stream.read_exact(&mut buf)?;
        let correct_sum = FileSum::decode(buf.as_slice())?;

        // compare checksums
        let (high, low) = hasher_to_u64s(hasher).into_inner();
        let hashes_match = correct_sum.md5_high == high && correct_sum.md5_low == low;

        // handle comparison
        let time_taken = now.elapsed().as_millis();
        let response = if hashes_match {
            writeln!(stdout, "\r{path:?} completely downloaded. {}B downloaded in {:.3}s ({:.3} MB/s) Hashes Match.", path_file.size, time_taken as f64 / 1000., (path_file.size as f64 / 1_000_000.) / (time_taken as f64 / 1000.))?;
            FileSumResponse{ response: FileSumResponseType::Match.into() }
        }
        else {
            writeln!(stdout, "\n{path:?} completely downloaded. {}B downloaded in {:.3}s ({:.3} MB/s) Hashes did NOT Match. Retrying...", path_file.size, time_taken as f64 / 1000., (path_file.size as f64 / 1_000_000.) / (time_taken as f64 / 1000.))?;
            FileSumResponse{ response: FileSumResponseType::NoMatch.into() }
        };
        // send response
        // (when sending a NoMatch response, the server will simply resend this file_path, which we will catch in the next loop.)
        stream.write_all(&response.encode_length_delimited_to_vec())?;

        total_bytes_downloaded += path_file.size;
    }

    // all files downloaded
    let time_taken = outer_now.elapsed().as_secs();
    writeln!(stdout, "All files downloaded:")?;
    writeln!(stdout, "{total_bytes_downloaded} Bytes in {time_taken}s - {:.3} MB/s", (total_bytes_downloaded as f64 / 1_000_000.) / time_taken as f64)?;
    Ok(())
}