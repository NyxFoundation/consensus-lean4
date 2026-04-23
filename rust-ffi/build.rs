use std::path::{Path, PathBuf};
use std::process::Command;

fn collect_objects(root: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(root) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if name == "Cache" || name == "LongestPole" || name == "Shake" {
                continue;
            }
            collect_objects(&path, out);
        } else if path
            .file_name()
            .and_then(|s| s.to_str())
            .is_some_and(|n| n.ends_with(".c.o.export"))
        {
            out.push(path);
        }
    }
}

fn main() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repo = manifest_dir.parent().expect("repo root").to_path_buf();

    let lean_bin = String::from_utf8(
        Command::new("elan").args(["which", "lean"]).output().expect("elan which lean").stdout,
    )
    .expect("utf8");
    let lean_bin = PathBuf::from(lean_bin.trim());
    let toolchain_lib = lean_bin
        .parent().unwrap()
        .parent().unwrap()
        .join("lib")
        .join("lean");

    let ir_roots = [
        repo.join(".lake/build/ir"),
        repo.join(".lake/packages/aeneas/backends/lean/.lake/build/ir"),
        repo.join(".lake/packages/mathlib/.lake/build/ir"),
        repo.join(".lake/packages/batteries/.lake/build/ir"),
        repo.join(".lake/packages/aesop/.lake/build/ir"),
        repo.join(".lake/packages/Qq/.lake/build/ir"),
        repo.join(".lake/packages/Cli/.lake/build/ir"),
        repo.join(".lake/packages/importGraph/.lake/build/ir"),
        repo.join(".lake/packages/LeanSearchClient/.lake/build/ir"),
        repo.join(".lake/packages/plausible/.lake/build/ir"),
        repo.join(".lake/packages/proofwidgets/.lake/build/ir"),
    ];

    let mut objects = Vec::new();
    for r in &ir_roots {
        collect_objects(r, &mut objects);
    }

    println!("cargo:rustc-link-search=native={}", toolchain_lib.display());

    println!("cargo:rustc-link-arg=-Wl,--start-group");
    for o in &objects {
        println!("cargo:rustc-link-arg={}", o.display());
    }
    println!("cargo:rustc-link-arg=-Wl,--end-group");

    println!("cargo:rustc-link-lib=dylib=leanshared");
    println!("cargo:rustc-link-lib=dylib=Init_shared");
    println!("cargo:rustc-link-lib=dylib=stdc++");
    println!("cargo:rustc-link-lib=dylib=gmp");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", toolchain_lib.display());

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}", repo.join("ConsensusLean4/Ffi.lean").display());
}
