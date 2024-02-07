use std::io::Result;

use protobuf_src::protoc;

fn main() -> Result<()> {
    std::env::set_var("PROTOC", protoc());
    prost_build::compile_protos(&["src/files.proto"], &["src/"])?;
    Ok(())
}