//! NUMA helpers — Phase 6 of `docs/MMAP_INDEX_PLAN.md`.
//!
//! Single function: `interleave_all`. Call it once at process startup,
//! BEFORE spawning rayon threads or allocating mmap arenas. It calls
//! `set_mempolicy(MPOL_INTERLEAVE, all_nodes)` so that newly-touched
//! pages get round-robin'd across NUMA nodes instead of going wherever
//! the first-touching thread happens to land.
//!
//! For our MCCFR workload this matters when the box has multiple NUMA
//! nodes (multi-socket Intel, or AMD EPYC parts with the NPS=2/4 BIOS
//! setting). On single-socket EPYC with NPS=1 (the default on most
//! provider configs, including the new Hostkey 7402P) the call is a
//! safe no-op — interleaving across a single node is just "use that
//! node," which is what would have happened anyway.
//!
//! We don't use the dead `libnuma` crate (last release 2017, Rust 2015
//! edition, transitively-broken deps per the verifier report). Instead
//! we make the raw `set_mempolicy` syscall ourselves — ~30 lines of
//! libc::syscall, no dependency cost.
//!
//! The implementation is a no-op on non-Linux targets so tests on macOS
//! / Windows / WSL don't break.

#[cfg(target_os = "linux")]
mod linux {
    /// `policy` argument value for `set_mempolicy`. From `linux/mempolicy.h`.
    /// We only ever pass INTERLEAVE; other values exist but we don't use them.
    const MPOL_INTERLEAVE: i32 = 3;

    /// Maximum number of NUMA nodes the kernel may report. The set_mempolicy
    /// nodemask is a bitmap of this many bits, padded to multiples of `ulong`.
    /// 1024 is the kernel's `MAX_NUMNODES` cap on x86_64 since Linux 4.x —
    /// real boxes have at most a handful. We just need the buffer to be
    /// large enough.
    const MAX_NUMA_NODES: usize = 1024;

    /// Set the calling thread's memory policy to "interleave across every
    /// NUMA node the kernel reports." Newly-touched pages get spread evenly.
    ///
    /// Returns `true` on success, `false` on any error. Errors are non-fatal
    /// — interleave is a perf hint, not a correctness requirement, so we
    /// log the errno and continue.
    ///
    /// MUST be called before spawning worker threads. The policy is per-task
    /// (i.e. per-thread by Linux semantics) and inherited at clone() time,
    /// so threads spawned after the call inherit the interleave policy.
    /// Setting it later has no effect on already-running threads.
    pub fn interleave_all() -> bool {
        // Build a nodemask with every possible bit set. The kernel ANDs this
        // with its actual node mask, so setting bits past the real node count
        // is harmless (and saves us a `numa_max_node()` round-trip).
        let n_longs = MAX_NUMA_NODES / (std::mem::size_of::<usize>() * 8);
        let nodemask: Vec<usize> = vec![usize::MAX; n_longs];

        // SAFETY: `set_mempolicy` reads `maxnode + 1` bits from the nodemask
        // pointer. We pass `maxnode = MAX_NUMA_NODES`, and the buffer holds
        // exactly that many bits (n_longs * 8 * size_of::<usize>()).
        // `SYS_set_mempolicy` is a stable syscall number since Linux 2.6.7;
        // x86_64 number is 238.
        let rc = unsafe {
            libc::syscall(
                libc::SYS_set_mempolicy,
                MPOL_INTERLEAVE as libc::c_long,
                nodemask.as_ptr() as libc::c_long,
                MAX_NUMA_NODES as libc::c_long,
            )
        };

        if rc == 0 {
            eprintln!("[numa] set_mempolicy(MPOL_INTERLEAVE, all_nodes) ok");
            true
        } else {
            // errno == ENOSYS on kernels without NUMA support (rare); we
            // also get EINVAL on single-node single-socket boxes where
            // MPOL_INTERLEAVE is redundant. Either way it's not fatal.
            let err = std::io::Error::last_os_error();
            eprintln!("[numa] set_mempolicy failed (non-fatal): {}", err);
            false
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux::interleave_all;

/// Non-Linux stub. Returns `false` so callers can branch on platform if
/// they care (most don't — interleave is a perf hint, not load-bearing).
#[cfg(not(target_os = "linux"))]
pub fn interleave_all() -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Smoke test: on Linux this exercises the real syscall and the result
    /// depends on the kernel + box config. We can't assert true (would fail
    /// in containers / kernels without NUMA support) or false (would fail
    /// on real boxes). Just assert it doesn't panic.
    #[test]
    fn test_interleave_all_does_not_panic() {
        let _ = interleave_all();
    }
}
