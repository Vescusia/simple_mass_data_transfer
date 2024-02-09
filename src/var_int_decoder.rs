use std::io::Read;

// based on protobuf var_int encoding: https://protobuf.dev/programming-guides/encoding/
pub fn read_var_int_from_stream<S: Read>(stream: &mut S) -> anyhow::Result<u64> {
    let mut bytes = 0;

    // receive bytes (putting into bytes in already big-endian order)
    let mut len = 0u8;
    loop {
        let byte = take_byte(stream)?;

        // add byte (minus continuation bit) to bytes
        bytes |= ((byte & 0x7F) as u64) << (len*7);
        // check if this is the last byte
        if byte >> 7 == 0 {
            break
        }

        len += 1;
    }

    Ok(bytes)
}

fn take_byte<S: Read>(stream: &mut S) -> anyhow::Result<u8> {
    let mut buf = [0u8];
    stream.read_exact(&mut buf)?;
    Ok(buf[0])
}
