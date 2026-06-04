/// Memory-mapped arena for regrets (i16) and strategy sums (f32).
///
/// Backed by a file on disk via mmap. The OS pages data in/out as needed,
/// allowing arenas larger than physical RAM. Hot entries stay in the page
/// cache; cold entries live on disk (SSD).
///
/// During training, most info sets are "cold" (visited once every ~1000
/// iterations). Only ~1% of entries are "hot" at any time. mmap exploits
/// this: hot pages stay resident, cold pages get evicted to disk by the
/// OS. This trades ~2-3x slower access for cold entries against the
/// ability to train with arenas that exceed physical RAM.
///
/// Access pattern: random by entry, sequential within entry's n_actions.
/// Each entry is 6-12 bytes (2-4 actions × 2 or 4 bytes). With 4KB pages,
/// ~680 i16 entries or ~512 f32 entries fit per page.

use memmap2::MmapMut;
use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

/// Issue the two `madvise` hints we want on every mmap arena:
///   - `MADV_RANDOM`     — skip readahead on scattered access.
///   - `MADV_HUGEPAGE`   — ask for 2 MiB transparent huge pages (THP).
///
/// Both are best-effort hints; the kernel can ignore either silently. The
/// only downside is one extra syscall per arena creation, paid once.
///
/// Centralized here so the two MmapArena construction paths (new + open)
/// stay consistent. Adding a third construction site? Call this helper.
#[cfg(unix)]
#[inline]
unsafe fn advise_arena(ptr: *const u8, len: usize) {
    libc::madvise(
        ptr as *mut libc::c_void,
        len,
        libc::MADV_RANDOM,
    );
    libc::madvise(
        ptr as *mut libc::c_void,
        len,
        libc::MADV_HUGEPAGE,
    );
}

/// A growable mmap-backed array that behaves like Vec<T> for T in {i16, f32}.
///
/// Internally manages a file + MmapMut. Grows by doubling the file size
/// (like Vec reallocation). The mmap is remapped on growth.
pub struct MmapArena<T: Copy + Default + bytemuck::Pod> {
    path: PathBuf,
    file: File,
    mmap: MmapMut,
    len: usize,       // number of T elements currently used
    capacity: usize,  // number of T elements the file can hold
    _phantom: std::marker::PhantomData<T>,
}

/// Trait bound for arena element types (i16, f32).
/// We use bytemuck for safe zero-copy casting between bytes and typed slices.

impl<T: Copy + Default + bytemuck::Pod> MmapArena<T> {
    /// Create a new mmap arena backed by a file at `path`.
    /// Initial capacity in number of elements.
    pub fn new(path: impl AsRef<Path>, initial_capacity: usize) -> io::Result<Self> {
        let path = path.as_ref().to_path_buf();
        let elem_size = std::mem::size_of::<T>();
        let byte_cap = (initial_capacity * elem_size).max(4096); // minimum 4KB

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)?;
        file.set_len(byte_cap as u64)?;

        let mmap = unsafe { MmapMut::map_mut(&file)? };

        // Hint to OS: random access pattern — don't do readahead.
        // Reduces wasted I/O when page faults are scattered.
        //
        // Also request transparent huge pages (2 MiB instead of 4 KiB).
        // At billion-entry scale the 4 KiB TLB is the bottleneck on random
        // access; 2 MiB pages cut TLB misses ~500x for the same working
        // set. THP is best-effort — if the kernel can't satisfy a request
        // it silently falls back to 4 KiB, so the worst case is no change.
        // Phase 6 of MMAP_INDEX_PLAN.md. NOTE: 1 GiB hugepages are NOT a
        // useful upgrade here per the research bundle's perf-realism review
        // (only ~4 L1-TLB entries on EPYC, worst case 2.5x slower).
        #[cfg(unix)]
        unsafe {
            advise_arena(mmap.as_ptr(), byte_cap);
        }

        Ok(Self {
            path,
            file,
            mmap,
            len: 0,
            capacity: byte_cap / elem_size,
            _phantom: std::marker::PhantomData,
        })
    }

    pub fn len(&self) -> usize {
        self.len
    }

    /// Get a reference to the underlying slice (up to len).
    #[inline(always)]
    fn as_slice(&self) -> &[T] {
        let bytes = &self.mmap[..self.len * std::mem::size_of::<T>()];
        bytemuck::cast_slice(bytes)
    }

    /// Get a mutable reference to the underlying slice (up to len).
    #[inline(always)]
    fn as_mut_slice(&mut self) -> &mut [T] {
        let byte_len = self.len * std::mem::size_of::<T>();
        let bytes = &mut self.mmap[..byte_len];
        bytemuck::cast_slice_mut(bytes)
    }

    /// Read element at index.
    #[inline(always)]
    pub fn get(&self, idx: usize) -> T {
        debug_assert!(idx < self.len, "MmapArena index {} out of range (len={})", idx, self.len);
        self.as_slice()[idx]
    }

    /// Write element at index.
    #[inline(always)]
    pub fn set(&mut self, idx: usize, val: T) {
        debug_assert!(idx < self.len);
        self.as_mut_slice()[idx] = val;
    }

    /// Grow the arena to hold at least `new_len` elements, zero-filling new space.
    ///
    /// Durability note: after `set_len` extends the backing file, we sync the
    /// inode metadata before remapping. Without this, a crash between extend
    /// and the next OS writeback could leave a sparse file whose `metadata.len`
    /// is "extended" but whose pages are unwritten — `open_existing` would
    /// then infer `len = capacity` and treat zero-filled tail pages as valid
    /// arena entries. The companion `len.bin` header (written on flush) is
    /// the canonical length record; this sync just makes the file's apparent
    /// size durable.
    pub fn resize(&mut self, new_len: usize, _fill: T) -> io::Result<()> {
        if new_len <= self.len {
            self.len = new_len;
            return Ok(());
        }

        if new_len > self.capacity {
            // Grow: at least double, or to new_len
            let new_cap = (self.capacity * 2).max(new_len).max(1024);
            let byte_cap = new_cap * std::mem::size_of::<T>();
            self.file.set_len(byte_cap as u64)?;
            // Make the extension durable before exposing it via mmap. Cost is
            // a single fsync on a metadata-only change — cheap on modern FSs.
            self.file.sync_all()?;
            // Remap
            self.mmap = unsafe { MmapMut::map_mut(&self.file)? };
            self.capacity = new_cap;
        }

        // Zero-fill the new region (mmap'd files are zero-initialized on extend)
        self.len = new_len;
        Ok(())
    }

    /// Path to the sidecar file that records `self.len` durably. Used by
    /// `flush_with_len` and `open_existing` so the on-disk arena length is
    /// authoritative regardless of `metadata.len()` (which only reflects the
    /// allocated capacity).
    fn len_sidecar_path(&self) -> PathBuf {
        let mut p = self.path.as_os_str().to_owned();
        p.push(".len");
        PathBuf::from(p)
    }

    /// Iterate mutably over all elements.
    pub fn iter_mut(&mut self) -> impl Iterator<Item = &mut T> {
        self.as_mut_slice().iter_mut()
    }

    /// Flush dirty pages to disk.
    pub fn flush(&self) -> io::Result<()> {
        self.mmap.flush()?;
        // Persist the canonical `len` so `open_existing` doesn't have to infer
        // it from file size (which is the *capacity*, not the live length).
        // Pre-fix, a crashed `resize` could leave file_size > 0 with no
        // corresponding entries — recovery would silently expand `len` to
        // capacity and treat zero pages as valid info-set data.
        std::fs::write(self.len_sidecar_path(), (self.len as u64).to_le_bytes())?;
        Ok(())
    }

    /// Raw byte access for Index trait.
    pub fn as_ref(&self) -> &[u8] {
        &self.mmap[..self.len * std::mem::size_of::<T>()]
    }

    /// Raw mutable byte access for IndexMut trait.
    pub fn as_mut(&mut self) -> &mut [u8] {
        let byte_len = self.len * std::mem::size_of::<T>();
        &mut self.mmap[..byte_len]
    }

    /// Path to the backing file.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Open an existing mmap-backed arena file without truncating.
    ///
    /// Length resolution: prefer the `.len` sidecar (canonical, written by
    /// `flush`) over `file_size / sizeof(T)`. The latter is only the file's
    /// allocated capacity — it includes any tail pages from a crashed
    /// `resize` that were extended but never populated. Trusting that as
    /// `len` would silently surface zero-filled entries as live info sets.
    /// If the sidecar is missing (e.g. an arena written before this fix),
    /// fall back to file-size inference and warn so the operator can decide
    /// whether to trust the recovery.
    pub fn open_existing(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref().to_path_buf();
        let elem_size = std::mem::size_of::<T>();

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)?;

        let file_size = file.metadata()?.len() as usize;
        if file_size % elem_size != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("file size {} not a multiple of sizeof(T)={}", file_size, elem_size),
            ));
        }
        let capacity = file_size / elem_size;

        let mut len_sidecar = path.as_os_str().to_owned();
        len_sidecar.push(".len");
        let len_sidecar = PathBuf::from(len_sidecar);

        let n = match std::fs::read(&len_sidecar) {
            Ok(bytes) if bytes.len() == 8 => {
                let recorded = u64::from_le_bytes(bytes.as_slice().try_into().unwrap()) as usize;
                if recorded > capacity {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!(
                            "{:?}: .len sidecar records {} elements but file capacity is only {}",
                            path, recorded, capacity
                        ),
                    ));
                }
                recorded
            }
            Ok(_) | Err(_) => {
                eprintln!(
                    "[mmap] {:?}: .len sidecar missing or malformed; falling back to file_size/sizeof — \
                     this trusts that no resize() was interrupted",
                    path
                );
                capacity
            }
        };
        let mmap = unsafe { MmapMut::map_mut(&file)? };

        // See `new` for advise rationale (MADV_RANDOM + MADV_HUGEPAGE).
        #[cfg(unix)]
        unsafe {
            advise_arena(mmap.as_ptr(), file_size);
        }

        Ok(Self {
            path,
            file,
            mmap,
            len: n,
            capacity,
            _phantom: std::marker::PhantomData,
        })
    }
}

impl<T: Copy + Default + bytemuck::Pod> Drop for MmapArena<T> {
    fn drop(&mut self) {
        // Best-effort flush + len sidecar persist on drop. If the process is
        // already unwinding from a panic, recording the current len here
        // means the next process-start sees the right boundary instead of
        // re-treating extended-but-unwritten tail pages as valid entries.
        let _ = self.mmap.flush();
        let _ = std::fs::write(self.len_sidecar_path(), (self.len as u64).to_le_bytes());
    }
}

/// Index operator for convenient access.
impl<T: Copy + Default + bytemuck::Pod> std::ops::Index<usize> for MmapArena<T> {
    type Output = T;
    #[inline(always)]
    fn index(&self, idx: usize) -> &T {
        &self.as_slice()[idx]
    }
}

impl<T: Copy + Default + bytemuck::Pod> std::ops::IndexMut<usize> for MmapArena<T> {
    #[inline(always)]
    fn index_mut(&mut self, idx: usize) -> &mut T {
        &mut self.as_mut_slice()[idx]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn test_dir() -> PathBuf {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tmp");
        std::fs::create_dir_all(&dir).ok();
        dir
    }

    #[test]
    fn test_mmap_arena_i16() {
        let path = test_dir().join("test_arena_i16.bin");
        let mut arena: MmapArena<i16> = MmapArena::new(&path, 1024).unwrap();

        assert_eq!(arena.len(), 0);

        // Grow and write
        arena.resize(10, 0i16).unwrap();
        arena.set(0, 42);
        arena.set(5, -100);
        arena.set(9, 32767);

        assert_eq!(arena.get(0), 42);
        assert_eq!(arena.get(5), -100);
        assert_eq!(arena.get(9), 32767);
        assert_eq!(arena.get(3), 0); // unset = zero

        // Grow beyond initial capacity
        arena.resize(2000, 0i16).unwrap();
        arena.set(1999, 123);
        assert_eq!(arena.get(1999), 123);
        assert_eq!(arena.get(0), 42); // original data preserved

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_mmap_arena_f32() {
        let path = test_dir().join("test_arena_f32.bin");
        let mut arena: MmapArena<f32> = MmapArena::new(&path, 1024).unwrap();

        arena.resize(5, 0.0f32).unwrap();
        arena.set(0, 3.14);
        arena.set(4, -2.71);

        assert!((arena.get(0) - 3.14).abs() < 1e-6);
        assert!((arena.get(4) - (-2.71)).abs() < 1e-6);

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_mmap_arena_halve() {
        let path = test_dir().join("test_arena_halve.bin");
        let mut arena: MmapArena<i16> = MmapArena::new(&path, 1024).unwrap();

        arena.resize(4, 0i16).unwrap();
        arena.set(0, 100);
        arena.set(1, 200);
        arena.set(2, -50);
        arena.set(3, 32000);

        // Halve all values
        for v in arena.iter_mut() {
            *v /= 2;
        }

        assert_eq!(arena.get(0), 50);
        assert_eq!(arena.get(1), 100);
        assert_eq!(arena.get(2), -25);
        assert_eq!(arena.get(3), 16000);

        std::fs::remove_file(&path).ok();
    }
}
