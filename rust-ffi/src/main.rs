use std::env;
use std::ffi::c_void;
use std::time::{Duration, Instant};

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

    fn csf_state_transition_e2e(v: u64, a: u64) -> u8;
    fn csf_process_slots(v: u64, target_slot: u64) -> u8;
    fn csf_process_block_header(v: u64) -> u8;
    fn csf_process_attestations(v: u64, a: u64) -> u8;
    fn csf_process_block(v: u64, a: u64) -> u8;
    fn csf_build_only_state_transition(v: u64, a: u64) -> u8;
    fn csf_build_only_process_slots(v: u64, target_slot: u64) -> u8;
    fn csf_build_only_process_block_header(v: u64) -> u8;
    fn csf_build_only_process_attestations(v: u64, a: u64) -> u8;
    fn csf_build_only_process_block(v: u64, a: u64) -> u8;
}

fn scaling_table<F: Fn(u64) -> u64>(label: &str, sizes: &[u64], f: F) {
    println!("--- {label} ---");
    println!("{:>10}  {:>14}  {:>14}  {:>12}", "N", "total", "per-N", "N²-norm");
    for &n in sizes {
        let t = Instant::now();
        let out = f(n);
        let elapsed = t.elapsed();
        let per_n_ns = elapsed.as_nanos() as f64 / n as f64;
        let n2_norm_ns = elapsed.as_nanos() as f64 / (n as f64 * n as f64);
        println!(
            "{n:>10}  {:>14}  {:>10.1} ns  {:>9.3} ns  [result={out}]",
            format!("{elapsed:?}"),
            per_n_ns,
            n2_norm_ns,
        );
    }
    println!();
}

fn iters_for(v: u64) -> usize {
    if v <= 500 { 30 } else if v <= 1000 { 10 } else { 3 }
}

fn median(mut xs: Vec<u128>) -> u128 {
    xs.sort_unstable();
    let n = xs.len();
    if n == 0 { 0 } else if n % 2 == 1 { xs[n/2] } else { (xs[n/2 - 1] + xs[n/2]) / 2 }
}

#[derive(Default)]
struct Paired {
    med_total_ns: u128,
    med_build_ns: u128,
    med_delta_ns: i128,
    min_delta_ns: i128,
    n_ok_total:   usize,
    n_ok_build:   usize,
    iters:        usize,
}

fn paired_sample(
    f_total: &dyn Fn() -> (Duration, u8),
    f_build: &dyn Fn() -> (Duration, u8),
    iters: usize,
    warmup: usize,
) -> Paired {
    for _ in 0..warmup { let _ = f_total(); let _ = f_build(); }
    let mut totals = Vec::with_capacity(iters);
    let mut builds = Vec::with_capacity(iters);
    let mut deltas = Vec::with_capacity(iters);
    let mut n_ok_total = 0usize;
    let mut n_ok_build = 0usize;
    for _ in 0..iters {
        let (et, ct) = f_total();
        let (eb, cb) = f_build();
        let nt = et.as_nanos();
        let nb = eb.as_nanos();
        totals.push(nt);
        builds.push(nb);
        deltas.push(nt as i128 - nb as i128);
        if ct == 0 { n_ok_total += 1; }
        if cb == 0 { n_ok_build += 1; }
    }
    let med_total_ns = median(totals.clone());
    let med_build_ns = median(builds.clone());
    let mut deltas_sorted = deltas.clone();
    deltas_sorted.sort_unstable();
    let med_delta_ns = if iters == 0 {
        0
    } else if iters % 2 == 1 {
        deltas_sorted[iters/2]
    } else {
        (deltas_sorted[iters/2 - 1] + deltas_sorted[iters/2]) / 2
    };
    let min_delta_ns = *deltas_sorted.first().unwrap_or(&0);
    Paired { med_total_ns, med_build_ns, med_delta_ns, min_delta_ns,
             n_ok_total, n_ok_build, iters }
}

fn fmt_ns(ns: u128) -> String {
    if ns >= 1_000_000_000 { format!("{:.2} s",  ns as f64 / 1e9) }
    else if ns >= 1_000_000 { format!("{:.2} ms", ns as f64 / 1e6) }
    else if ns >= 1_000     { format!("{:.2} µs", ns as f64 / 1e3) }
    else                    { format!("{} ns",    ns) }
}

fn fmt_ns_signed(ns: i128) -> String {
    if ns < 0 { format!("-{}", fmt_ns((-ns) as u128)) } else { fmt_ns(ns as u128) }
}

fn flag(p: &Paired) -> &'static str {
    if p.n_ok_total < p.iters { " [!! n_ok_total<iters]" }
    else if p.med_delta_ns < 0 { " [! delta<0]" }
    else { "" }
}

fn paired_bench_table_1d(
    label: &str,
    vs: &[u64],
    f_total: &dyn Fn(u64) -> (Duration, u8),
    f_build: &dyn Fn(u64) -> (Duration, u8),
    warmup: usize,
) {
    println!("--- {label} ---");
    println!("{:>8}  {:>5}  {:>10}  {:>10}  {:>10}  {:>10}  {:>5}", "V", "iter", "build", "total", "pipeline", "min_dlt", "ok");
    for &v in vs {
        let it = iters_for(v);
        let p = paired_sample(&|| f_total(v), &|| f_build(v), it, warmup);
        println!(
            "{v:>8}  {:>5}  {:>10}  {:>10}  {:>10}  {:>10}  {:>2}/{:<2}{}",
            it,
            fmt_ns(p.med_build_ns),
            fmt_ns(p.med_total_ns),
            fmt_ns_signed(p.med_delta_ns),
            fmt_ns_signed(p.min_delta_ns),
            p.n_ok_total, it,
            flag(&p),
        );
    }
    println!();
}

fn paired_bench_table_2d(
    label: &str,
    vs: &[u64],
    as_: &[u64],
    f_total: &dyn Fn(u64, u64) -> (Duration, u8),
    f_build: &dyn Fn(u64, u64) -> (Duration, u8),
    warmup: usize,
) {
    println!("--- {label} ---");
    println!("{:>8}  {:>5}  {:>5}  {:>10}  {:>10}  {:>10}  {:>10}  {:>10}  {:>5}",
             "V", "A", "iter", "build", "total", "pipeline", "min_dlt", "ns/(V²·A)", "ok");
    for &v in vs {
        for &a in as_ {
            let it = iters_for(v);
            let p = paired_sample(&|| f_total(v, a), &|| f_build(v, a), it, warmup);
            let denom = (v as f64).powi(2) * (a.max(1) as f64);
            let const_ns = if p.med_delta_ns > 0 { p.med_delta_ns as f64 / denom } else { 0.0 };
            let const_str = if a == 0 || const_ns == 0.0 { "—".to_string() } else { format!("{const_ns:.2}") };
            println!(
                "{v:>8}  {a:>5}  {:>5}  {:>10}  {:>10}  {:>10}  {:>10}  {:>10}  {:>2}/{:<2}{}",
                it,
                fmt_ns(p.med_build_ns),
                fmt_ns(p.med_total_ns),
                fmt_ns_signed(p.med_delta_ns),
                fmt_ns_signed(p.min_delta_ns),
                const_str,
                p.n_ok_total, it,
                flag(&p),
            );
        }
    }
    println!();
}

fn time1<F: Fn() -> u8>(f: F) -> (Duration, u8) {
    let t = Instant::now();
    let r = f();
    (t.elapsed(), r)
}

fn main() {
    let quick = env::var("CSF_QUICK").is_ok();
    unsafe {
        let t_init = Instant::now();
        lean_initialize_runtime_module();
        lean_initialize();
        let _ = initialize_consensus_x2dlean4_ConsensusLean4_Ffi(1, std::ptr::null_mut());
        lean_io_mark_end_initialization();
        println!("Lean runtime init: {:?}\n", t_init.elapsed());
        if quick { println!("(CSF_QUICK=1 — reduced grid)\n"); }

        // --- existing micro-benchmarks (kept for cross-check) ---
        let sija_sizes = [1_000u64, 10_000, 100_000, 1_000_000];
        scaling_table("bench_sija_loop  (Lean-internal loop, no FFI per-iter)", &sija_sizes, |n| {
            csf_bench_sija_loop(n)
        });

        let vec_sizes: &[u64] = if quick { &[100, 1_000, 5_000] } else { &[100, 1_000, 5_000, 10_000, 20_000] };
        scaling_table("bench_vec_build  (Aeneas Vec.push × N — List.concat O(N²))", vec_sizes, |n| {
            csf_bench_vec_build(n)
        });
        scaling_table("bench_vec_scan   (build + index_usize × N — O(N²) scan)", vec_sizes, |n| {
            csf_bench_vec_scan(n)
        });

        // --- single-call FFI boundary (reference) ---
        println!("--- single-call FFI boundary (reference) ---");
        let cases = [(10u64, 5u64), (4, 5), (9, 0), (25, 0), (6, 0)];
        for (slot, finalized) in cases {
            let t = Instant::now();
            let code = csf_slot_is_justifiable_after(slot, finalized);
            println!("  ({slot:3}, {finalized}) = {code}  [{:?}]", t.elapsed());
        }
        println!();

        // --- E2E paired benchmarks ---
        let warmup = 2;

        let v_sanity: &[u64] = if quick { &[100, 1_000] } else { &[100, 2_000] };
        paired_bench_table_1d(
            "process_slots  (pipeline = O(1); V-sweep is methodology sanity)",
            v_sanity,
            &|v| time1(|| csf_process_slots(v, 1)),
            &|v| time1(|| csf_build_only_process_slots(v, 1)),
            warmup,
        );
        paired_bench_table_1d(
            "process_block_header  (pipeline = O(1); V-sweep is methodology sanity)",
            v_sanity,
            &|v| time1(|| csf_process_block_header(v)),
            &|v| time1(|| csf_build_only_process_block_header(v)),
            warmup,
        );

        let vs_att: &[u64] = if quick { &[100, 500, 1_000] } else { &[100, 500, 1_000, 2_000] };
        let as_att: &[u64] = if quick { &[0, 1, 4, 16] } else { &[0, 1, 4, 16, 64] };
        paired_bench_table_2d(
            "process_attestations  (HEADLINE A·V² benchmark)",
            vs_att, as_att,
            &|v, a| time1(|| csf_process_attestations(v, a)),
            &|v, a| time1(|| csf_build_only_process_attestations(v, a)),
            warmup,
        );

        let vs_e2e: &[u64] = if quick { &[100, 500] } else { &[100, 500, 1_000] };
        let as_e2e: &[u64] = if quick { &[0, 1, 4] } else { &[0, 1, 4, 16] };
        paired_bench_table_2d(
            "process_block  (header + attestations; isolates state_root overhead)",
            vs_e2e, as_e2e,
            &|v, a| time1(|| csf_process_block(v, a)),
            &|v, a| time1(|| csf_build_only_process_block(v, a)),
            warmup,
        );
        paired_bench_table_2d(
            "state_transition_e2e  (full pipeline: process_slots + process_block + state_root)",
            vs_e2e, as_e2e,
            &|v, a| time1(|| csf_state_transition_e2e(v, a)),
            &|v, a| time1(|| csf_build_only_state_transition(v, a)),
            warmup,
        );
    }
}
