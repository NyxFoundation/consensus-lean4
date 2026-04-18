use std::ffi::c_void;
use std::time::Instant;

extern "C" {
    fn lean_initialize_runtime_module();
    fn lean_initialize();
    fn lean_io_mark_end_initialization();
    fn initialize_consensus_x2dlean4_ConsensusLean4_Ffi(builtin: u8, w: *mut c_void)
        -> *mut c_void;
    fn csf_slot_is_justifiable_after(slot: u64, finalized: u64) -> u8;
    fn csf_bench_sija_loop(n: u64) -> u64;
    fn csf_bench_vec_build(n: u64) -> u64;
    fn csf_bench_vec_scan(n: u64) -> u64;
}

fn scaling_table<F: Fn(u64) -> u64>(label: &str, sizes: &[u64], f: F) {
    println!("--- {label} ---");
    println!("{:>10}  {:>14}  {:>14}  {:>12}", "N", "total", "per-N", "N²-norm");
    let mut prev: Option<(u64, f64)> = None;
    for &n in sizes {
        let t = Instant::now();
        let out = f(n);
        let elapsed = t.elapsed();
        let per_n_ns = elapsed.as_nanos() as f64 / n as f64;
        let n2_norm_ns = elapsed.as_nanos() as f64 / (n as f64 * n as f64);
        let ratio = match prev {
            Some((pn, pt)) if n != pn => {
                let growth = elapsed.as_secs_f64() / pt;
                let scale = n as f64 / pn as f64;
                format!(" ({:.1}x vs N×{:.1})", growth, scale)
            }
            _ => String::new(),
        };
        println!(
            "{n:>10}  {:>14}  {:>10.1} ns  {:>9.3} ns  [result={out}]{ratio}",
            format!("{elapsed:?}"),
            per_n_ns,
            n2_norm_ns,
        );
        prev = Some((n, elapsed.as_secs_f64()));
    }
    println!();
}

fn main() {
    unsafe {
        let t_init = Instant::now();
        lean_initialize_runtime_module();
        lean_initialize();
        let _ = initialize_consensus_x2dlean4_ConsensusLean4_Ffi(1, std::ptr::null_mut());
        lean_io_mark_end_initialization();
        println!("Lean runtime init: {:?}\n", t_init.elapsed());

        let sija_sizes = [1_000u64, 10_000, 100_000, 1_000_000];
        scaling_table("bench_sija_loop  (Lean-internal loop, no FFI per-iter)", &sija_sizes, |n| {
            csf_bench_sija_loop(n)
        });

        let vec_sizes = [100u64, 1_000, 5_000, 10_000, 20_000];
        scaling_table("bench_vec_build  (Aeneas Vec.push × N — List.concat O(N²))", &vec_sizes, |n| {
            csf_bench_vec_build(n)
        });

        scaling_table("bench_vec_scan   (build + index_usize × N — O(N²) scan)", &vec_sizes, |n| {
            csf_bench_vec_scan(n)
        });

        println!("--- single-call FFI boundary (reference) ---");
        let cases = [(10u64, 5u64), (4, 5), (9, 0), (25, 0), (6, 0)];
        for (slot, finalized) in cases {
            let t = Instant::now();
            let code = csf_slot_is_justifiable_after(slot, finalized);
            println!("  ({slot:3}, {finalized}) = {code}  [{:?}]", t.elapsed());
        }
    }
}
