use md5::Digest;

/// Reset a vector buffer to 0u8's up to `min(reset_size, vec.capacity())`
pub fn reset_vec_buf(vec: &mut Vec<u8>, reset_size: usize) {
    // clear vec
    vec.clear();
    // push zeroes up to reset size
    for _ in 0..reset_size.min(vec.capacity()) {
        vec.push(0)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct HashU64{
    pub high: u64,
    pub low: u64
}

impl HashU64 {
    /// Split `self` into its inner parts.
    /// The left `u64` is high, the right `u64` is low
    pub fn into_inner(self) -> (u64, u64) {
        (self.high, self.low)
    }
}

/// Split a md5 hasher into two u64's
pub fn hasher_to_u64s(hasher: md5::Md5) -> HashU64 {
    // A md5 hash is literally 16 bytes long. It cannot be less.
    let hash = hasher.finalize();
    let hash_array: [u8; 16] = hash[0..16].try_into().unwrap();
    HashU64{
        high: u64::from_be_bytes(hash_array[0..8].try_into().unwrap()),
        low: u64::from_be_bytes(hash_array[8..16].try_into().unwrap())
    }
}
