use super::var_int_decoder::read_var_int_from_stream;
use super::files::{ FileSum, FileSumResponse, FileSumResponseType, PathFile };
use super::utils::{ reset_vec_buf, DigestReader };

use std::io::{Read, Write};
use std::time::Instant;
use magic_crypt::generic_array::typenum::{U65536};
use magic_crypt::MagicCryptTrait;

use prost::Message;

pub fn download(addr: std::net::SocketAddr, path: std::path::PathBuf, key: Option<String>) -> anyhow::Result<()> {
    // connect to address
    let mut stream = std::net::TcpStream::connect(addr)?;
    println!("Successfully connected to {addr}!");

    // (Maybe) create decryptor
    let decryptor = key.as_ref().map(|key| magic_crypt::new_magic_crypt!(key, 128));

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
        write!(stdout, "Decoded PathFile: {}B", path_file.size)?;

        // decrypt rel_path
        let rel_path = if let Some(mc) = &decryptor {
            mc.decrypt_base64_to_string(&path_file.rel_path).unwrap_or_else(|_| panic!("\nFailed to decrypt received base64 relative path `{}`, an incorrect decryption key (or one used, when the server is not encrypted) is most probable.\n", path_file.rel_path))
        } else { path_file.rel_path };

        // create file (overwrite if already existing)
        let mut path = path.clone();
        path.push(rel_path);
        std::fs::create_dir_all(path.parent().unwrap())?;  // create all necessary ancestors
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .open(&path)?;
        write!(stdout, "\rDownloading File {path:?}")?;

        // create hasher
        let mut reader = DigestReader::new(&mut stream);

        // read from stream and write to file
        if let Some(mc) = &decryptor {
            // decrypt directly from stream to file (look at that cursed .take)
            mc.decrypt_reader_to_writer2::<U65536>(&mut (&mut reader).take(path_file.size), &mut file)?;
        }
        else {
            // create buffer of 64kiB
            let mut buf = Vec::with_capacity(1 << 16);
            while reader.bytes_read < path_file.size {
                // (re-)initialize buffer
                reset_vec_buf(&mut buf, (path_file.size - reader.bytes_read) as usize);
                // read bytes from stream
                reader.read_exact(&mut buf)?;
                // update user
                write!(stdout, "\r{:.3}% received.      ", (reader.bytes_read as f64) / (path_file.size as f64) * 100.)?;
                // write to file
                file.write_all(buf.as_slice())?;
            };
        }

        // receive checksum
        let (stream, checksum) = reader.finalize();
        let length = read_var_int_from_stream(stream)?;
        let mut buf = vec![0u8; length as usize];
        stream.read_exact(&mut buf)?;
        let correct_sum = FileSum::decode(buf.as_slice())?;

        // compare checksums
        let (high, low) = checksum.into_inner();
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