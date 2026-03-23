/// FNV-1a 64-bit hashing for info set keys.
/// Must produce identical hashes to OCaml's make_info_key in compact_cfr.ml.

const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

#[inline(always)]
fn fnv1a_mix_byte(h: u64, b: u8) -> u64 {
    (h ^ b as u64).wrapping_mul(FNV_PRIME)
}

#[inline(always)]
fn fnv1a_mix_int(mut h: u64, n: u64) -> u64 {
    for i in 0..8 {
        h = fnv1a_mix_byte(h, ((n >> (i * 8)) & 0xFF) as u8);
    }
    h
}

#[inline(always)]
fn fnv1a_mix_bytes(mut h: u64, data: &[u8]) -> u64 {
    for &b in data {
        h = fnv1a_mix_byte(h, b);
    }
    h
}

/// Hash bucket assignments + round_idx + action history into a u64.
/// Matches OCaml's make_info_key exactly:
///   - Mix buckets[0..=min(round_idx, 3)] as 64-bit ints
///   - Separator 0xFF
///   - Mix round_idx as 64-bit int
///   - Separator 0xFE
///   - Mix history bytes
#[inline]
pub fn make_info_key(buckets: &[u32; 4], round_idx: u8, history: &[u8]) -> u64 {
    let mut h = FNV_OFFSET_BASIS;
    let last = round_idx.min(3) as usize;
    for i in 0..=last {
        h = fnv1a_mix_int(h, buckets[i] as u64);
    }
    h = fnv1a_mix_byte(h, 0xFF);
    h = fnv1a_mix_int(h, round_idx as u64);
    h = fnv1a_mix_byte(h, 0xFE);
    h = fnv1a_mix_bytes(h, history);
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deterministic() {
        let buckets = [34, 29, 78, 3];
        let key1 = make_info_key(&buckets, 2, b"cc/kk/kh");
        let key2 = make_info_key(&buckets, 2, b"cc/kk/kh");
        assert_eq!(key1, key2);
    }

    #[test]
    fn test_different_history() {
        let buckets = [34, 29, 78, 3];
        let key1 = make_info_key(&buckets, 2, b"cc/kk/kh");
        let key2 = make_info_key(&buckets, 2, b"cc/kk/kp");
        assert_ne!(key1, key2);
    }

    #[test]
    fn test_different_buckets() {
        let b1 = [34, 29, 78, 3];
        let b2 = [35, 29, 78, 3];
        let key1 = make_info_key(&b1, 0, b"cc");
        let key2 = make_info_key(&b2, 0, b"cc");
        assert_ne!(key1, key2);
    }
}
