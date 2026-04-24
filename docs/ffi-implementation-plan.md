---
title: Rust ↔ Lean 4 FFI ベンチマーク 実装計画
last_updated: 2026-04-24
tags:
  - ffi
  - implementation
  - plan
---

# Rust ↔ Lean 4 FFI ベンチマーク 実装計画

> **前提**: [調査メモ](./ffi-feasibility.md) が 2026-04-24 に承認済。本書はその §4.1 骨子を具体的な実装ステップに落とし込んだもので、**実装開始前にユーザー承認を取る**。

## Context

調査メモで決まった方針の組み合わせを実装する:

- **Option A**: 独立 feature branch で再実装 (PR #2 / #3 は参考のみ)
- **Option X**: 2 エントリポイント (`state_transition`, `compute_lmd_ghost_head`) をそれぞれ 1 FFI コールで e2e 実行
- **Option II**: Rust 側で State/Block を構築し `ToLean` で marshal、`lean_object*` を渡す
- 計測は N 軸 (state_transition) と B/A 軸 (compute_lmd_ghost_head) を別プロセスで独立に

## 前提条件

- ベースブランチ: `main` (現 HEAD: `177fd38`)
- ツールチェイン: `leanprover/lean4:v4.28.0-rc1` (変更しない。必要になれば単独承認)
- Lean 依存: Aeneas @ `864eddb4876d0104802e0fd29bd453f67f48c4be` (既存 `lake-manifest.json`)
- 並存する open PR: #2 (feat/rust-ffi-poc), #3 (perf/fast-process-attestations) — どちらも参照するが lift & shift しない

## ブランチ

- 名前: `feat/ffi-benchmarks`
- base: `main`
- `FunsExternal.lean` の axiom 置換は必要最小限 (A5 方針、PR #2 との diff 衝突を最小化)

---

## マイルストーン

### M0: 準備

**Goal**: 環境の sanity 確認と branch 切り出し

- `feat/ffi-benchmarks` ブランチを `main` から切る
- `lake update` で依存 (Mathlib / Aeneas 等) を取得、`lake build` が成功することを確認
- `.gitignore` に `.lake/`, `rust-ffi/target/` が入っているか確認 (既存 `.gitignore` が `.lake/` を除外済。`rust-ffi/target/` は追加)

**検証**: `lake build` が警告ゼロで通る

---

### M1: Smoke Stage 1 — `csf_ping`

**Goal**: FFI 境界の最小確認。Lean と Rust が繋がるかを一番小さい関数で検証。

**Lean 側**:
- `ConsensusLean4/Ffi.lean` (新規、~10 行):
  ```lean
  @[export csf_ping] def csfPing (n : UInt64) : UInt64 := n + 1
  ```
- `ConsensusLean4.lean` root に `import ConsensusLean4.Ffi` を追加
- `lakefile.lean` に `lean_lib ConsensusLean4 { globs := #[.submodules \`ConsensusLean4] }` (submodule 自動 pickup)。`precompileModules` は設定しない (default false、Issue #5509 回避)

**Rust 側**:
- `rust-ffi/Cargo.toml` (新規)
- `rust-ffi/build.rs` (新規): `.c.o.export` 再帰スキャン + `elan which lean` で toolchain `lib/lean/` 解決 + `leanshared`/`Init_shared`/`stdc++`/`gmp` dylib link + RPATH 埋め込み
- `rust-ffi/src/main.rs` (新規、~40 行): extern block で `csf_ping` + 初期化 4 段階 + `assert_eq!(csf_ping(41), 42)`

**検証**:
- `lake build ConsensusLean4:static` → `.lake/build/lib/libConsensusLean4.a` 生成
- `nm .lake/build/lib/libConsensusLean4.a | grep csf_ping` で symbol 可視
- `cd rust-ffi && cargo run --release` が exit 0

---

### M2: FunsExternal axiom 置換 (必要になったら随時)

**Goal**: `FastPath.lean` / `Ffi.lean` のビルドや実行が axiom で阻害されたタイミングでのみ、該当 axiom を real def に置換

**方針**: **事前に 5 axiom すべてを置換しない**。M3 / M4 で実際に panic / typecheck 失敗した axiom だけ、必要性を確認して置換する。
- 5 axiom: `alloc.vec.Vec.clear`, `alloc.vec.Vec.is_empty`, `Ordering.Insts.CoreCmpPartialEqOrdering.eq`, `Result.Insts.CoreOpsTry_traitTryTResultInfallibleE.branch`, `Result.Insts.CoreOpsTry_traitFromResidualResultInfallibleE.from_residual`
- 置換が発生したらこの節に追記、PR #2 の該当実装は参照のみ (コードはゼロから書く)

このマイルストーンは単独では実行せず、M3 / M4 の中で**遅延置換 (defer-based)** する。

---

### M3: handwritten fast path

**Goal**: state_transition を Array ベースの e2e pipeline として手書き実装

- `ConsensusLean4/FastPath.lean` (新規、~250 行):
  - `ofVec` / `toVec`: `alloc.vec.Vec α ↔ Array α` コンバータ
  - `isValidVoteFast`: aggregation_bits を Array で線形スキャン
  - `processSingleAttestationFast`: 1 attestation を Array ベースで処理
  - `processAttestationsFast`: attestation ループを Array で回す (O(A·V))
  - `processBlockFast`: `process_block_header` (Aeneas 版) + `processAttestationsFast`
  - `stateTransitionFast`: `process_slots` (Aeneas 版) + `processBlockFast` + `hash_tree_root_state` 照合
- アルゴリズムは PR #3 を参照するが**コードはゼロから書き直し**
- 小さい入力 (V=2, A=1) で Lean 内部 `#eval` 手動確認

**検証**:
- `lake build` 成功
- `#eval stateTransitionFast <minimal_state> <minimal_block>` が `.ok (.Ok (), _)` を返す
- `#eval` を含む test.lean を 1 本追加して CI-testable に

---

### M4: Smoke Stage 2+3 — 2 エントリポイント e2e FFI

**Goal**: Rust から 1 FFI コールで両エントリポイントを呼ぶ

**Rust 側**:
- `rust-ffi/src/lean_types.rs` (新規): Aeneas 型に対応する Rust struct (`H256`, `Validator`, `State`, `Block`, `AggregatedAttestation`, ...)
- `rust-ffi/src/to_lean.rs` (新規): `trait ToLean { fn to_lean(&self) -> *mut lean_object; }` + 各型の impl (`lean_alloc_ctor` / `lean_box_uint64` / 再帰的に子を構築)
- `rust-ffi/src/ffi.rs` (新規): 4 本の extern 宣言 + 初期化 4 段階の helper
- `rust-ffi/src/bin/bench-state-transition.rs` (新規): 最小入力で `csf_state_transition` の smoke、次に N ループで計測
- `rust-ffi/src/bin/bench-fork-choice.rs` (新規): 同様に `csf_compute_lmd_ghost_head`

**Lean 側**:
- `ConsensusLean4/Ffi.lean` 拡張:
  - `@[export csf_state_transition]` → `stateTransitionFast` を呼ぶ wrapper
  - `@[export csf_state_transition_noop]` → 入力を受けて pipeline を走らせず即 return (paired-delta twin)
  - `@[export csf_compute_lmd_ghost_head]` → Aeneas の `fork_choice.compute_lmd_ghost_head` をそのまま呼ぶ
  - `@[export csf_compute_lmd_ghost_head_noop]` → 同上 twin
- 初期化関数シンボル名を `nm` で確認し、Rust 側 extern 宣言と一致させる (`initialize_consensus_x2dlean4_ConsensusLean4_Ffi`)

**検証**:
- Smoke Stage 2: `cargo run --release --bin bench-state-transition -- --smoke` で最小入力が OK sentinel
- Smoke Stage 3: `cargo run --release --bin bench-fork-choice -- --smoke` で期待 head_root 返却
- 不正入力 (block.slot を壊す等) で Err sentinel、runtime panic なし

---

### M5: ベンチ本走行 + ドキュメント

**実行環境**: ローカル (Linux 6.17、CPU governor performance、`taskset -c <core>` でピン止め)

**Goal**: 計画したスケール階段で実測、結果を docs に集計

- **state_transition**: N ∈ {100, 1K, 10K, 100K}, A=64, 5 試行ずつ (N=1M は 1 試行)
- **compute_lmd_ghost_head**: (B, A) ∈ {100, 1K, 10K} × {32, 128}, 5 試行ずつ
- 各セル別プロセスで実行 (`ru_maxrss` 分離、A10 方針)
- 計測結果を `docs/rust-ffi-benchmarks.md` (新規) に集計
  - 時間: 中央値 + IQR
  - メモリ: `ru_maxrss` 差分
  - 外挿セル / 実測セルを明示 (A4 方針)
  - "crypto cost excluded" の注記 (A3)
- `README.md` に再現手順を 3 ステップで記載: `elan which lean` / `lake build` / `cargo run --release --bin ...`

**検証**: `docs/rust-ffi-benchmarks.md` に完成表、README に再現コマンド記載

---

## 進捗報告

**工数見積もりはしない** (ユーザー方針)。M0 → M1 → M2 → M3 → M4 → M5 の順に進め、**各 M 完了時点でユーザーに進捗報告**する。想定外の時間がかかる箇所 (R1–R5) があれば発生時点で報告・相談。

## リスクと対応

| # | リスク | 発生時対応 |
|---|---|---|
| R1 | `lake update` での Mathlib 取得が遅い | 初回のみ (30 分–1 時間)、以降はキャッシュ。M0 のバッファに含む |
| R2 | `libleanshared.so` が見つからない (elan 未インストール等) | README に前提明記。`LEAN_LIB_DIR` env override を build.rs に追加 |
| R3 | ToLean marshaling で Lean object 構築に失敗 (Aeneas 型形状ミスマッチ) | M4 smoke が落ちる。V=2 の最小入力から増やして特定 |
| R4 | N=1M で OOM | `ru_maxrss` 監視、異常値なら N=100K で打ち切り、結果に注記 |
| R5 | Lean v4.28.0-rc1 固有のバグが発覚 | toolchain 変更は**単独承認を取る** (計画承認に含めない、C11 方針) |

## ロールバック方針

- M0–M5 各段階で commit を切り、失敗時は前段階まで `git reset --soft` で戻せる状態を維持
- feature branch は main に直接 push しない。完了時に PR 化してレビュー
- 万一 main を壊す変更をした場合は `git revert` で取り消し (`git push --force` は使わない)

## 非スコープ (本タスクでやらないもの)

- SSZ encoding/decoding (issue #4)
- `hash_tree_root_*` real 実装 (issue #5)
- `compute_lmd_ghost_head_fast` (A7、mainnet 級 B=32K の追加 fast path)
- BLS 署名検証
- `lean-toolchain` のアップグレード
- PR #2 / PR #3 の close / merge 判断 (完了後にユーザーが判断)

## 承認後の実行順

1. 本計画をユーザーが承認 ✓ (2026-04-24)
2. `feat/ffi-benchmarks` branch を切る
3. M0 → M1 → M2 (遅延) → M3 → M4 → M5 の順に実装、各 M 完了時にユーザーに進捗報告
4. M5 完了後に **M0–M5 をまとめた 1 本の PR** を作成、レビュー待ち

## 2026-04-24 決定事項 (A11–A14)

- **A11**: 工数見積もりはしない。M 完了毎に進捗報告
- **A12**: M2 の axiom 置換は**遅延**。M3 / M4 で実際に必要になった axiom のみ置換
- **A13**: ベンチはローカル環境で実行 (CPU governor performance + taskset 推奨)
- **A14**: M0–M5 を 1 本の PR にまとめる (`feat/ffi-benchmarks` → `main`)
