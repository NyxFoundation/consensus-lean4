---
title: Rust ↔ Lean 4 FFI ベンチマーク実現可能性 調査メモ
last_updated: 2026-04-24
tags:
  - ffi
  - benchmark
  - aeneas
  - lean4
---

# Rust ↔ Lean 4 FFI ベンチマーク実現可能性 調査メモ

## Context — なぜ調査するのか

ユーザー要望: `state_transition.state_transition` と `fork_choice.compute_lmd_ghost_head` を Rust クライアントから FFI 経由で呼び出し、バリデータ数 N を振って実行時間 / メモリを計測したい。
ガードレール: 「1 行もコードを書く前に」調査メモを承認させること。

調査してわかった**最重要事実**:

1. **同じことをやる 2 つの OPEN PR が既に存在する**。PR #2 (`feat/rust-ffi-poc`) は POC 全体を、PR #3 (`perf/fast-process-attestations`) は Aeneas の O(N²) を 55–134× 高速化する fast path を、既に実装済み。ユーザー決定で**参考資料としてのみ**扱い、実装は独立に行う。
2. **`compute_lmd_ghost_head` は Validator 数 N を引数に取らない**。シグネチャは `(start_root, blocks, attestations, min_score) → (H256, Vec (H256, U64))`。N ではなく B (blocks) と A (attestations) でスケールする。ユーザーの「N を振る」という計測計画は `state_transition` 側にのみ素直に適用できる (compute_lmd_ghost_head は B, A 軸で計測)。
3. **生成された `Vec<T>` の実体は `List α` ベース**で push / index が O(n)。`state_transition` 内の `process_attestations` は O(A·N²) で N>2K から実測困難、N=1M で 2 日。**Option X 方式**: `stateTransitionFast` を手書きで組み、`process_slots` / `process_block_header` (Aeneas の線形部分) + handwritten `processBlockFast` (内部で Array ベースの `processAttestationsFast`) + state_root 照合、の全体を 1 FFI コールに畳む。これで N=1M もエントリポイント e2e で実測可能 (~10 s / call 外挿)。
4. **Aeneas 出力には形式的同値性の証明は付随しない** (Funs.lean は `def` のみで `theorem` なし)。よって slow (Aeneas 版) / fast (手書き版) の選択は純粋に engineering 最適化の話で、検証保証とは独立。本タスクは **slow path ベンチを行わず fast e2e のみ計測**する。
5. **Lean v4.28.0-rc1 で `precompileModules := true` は避けるべき** (Issue #5509)。PR #2 は `.c.o.export` object を build.rs で動的に拾って static リンクする方式で、これを採用する。

**推奨 (ユーザー 2026-04-24 回答反映)**: PR #2 / #3 は**参考資料として残す**が、実装は**独立した新規ブランチで再作成**する。2 エントリポイント (`state_transition.state_transition`, `fork_choice.compute_lmd_ghost_head`) を**それぞれ 1 FFI コールの e2e で露出** (= Option X) して計測する。slow path の並走は行わない。**入力値は Rust 側で構築し、ToLean trait 経由で `lean_object*` に marshal して FFI で渡す** (= Option II)。将来的な SSZ バイト列方式 (Option III) への移行は別途 GitHub issue で追跡する。本メモは実装計画ではなく**調査報告**であり、実装計画は別途承認を取る。

---

## 1. 先行試行のサーベイ

### 1.1 PR #2 — feat/rust-ffi-poc

| 項目 | 内容 |
|---|---|
| ステータス | OPEN, CI 未実行, レビュー未 |
| サイズ | +920 / −45、10 ファイル |
| ベース | `main` |
| head commit | `6ba79a7` |

**追加ファイル**
- `CLAUDE.md` — アーキテクチャガイド
- `ConsensusLean4/Ffi.lean` — 14 本の `@[export csf_*]` wrapper
- `ConsensusLean4/FunsExternal.lean` 編集 — 5 axiom に real def を置換
- `docs/rust-ffi-benchmarks.md` — 計測方法と結果
- `rust-ffi/Cargo.toml`, `rust-ffi/build.rs`, `rust-ffi/src/main.rs`
- `lakefile.lean` に `globs := #[.submodules \`ConsensusLean4]` を追記

**FFI 方式**
- `extern "C"` raw bindings (cxx / bindgen 不使用)
- Lean 側 `@[export csf_foo]` → Rust 側 `extern "C" fn csf_foo(...)`
- 結果を `UInt8` sentinel (0=ok false, 1=ok true, 2=panic, 3=divergence) に pack
- `build.rs` が `.lake/**/*.c.o.export` を再帰走査し、`Cache/LongestPole/Shake` の Mathlib 付属ツール用 object を除外、`-Wl,--start-group ... --end-group` で static link
- `libleanshared.so`, `libInit_shared.so`, `libstdc++`, `libgmp` を dylib link、RPATH を toolchain lib dir に設定
- `precompileModules` 不使用

**露出された Lean エントリポイント**
- `csf_state_transition_e2e`, `csf_process_slots`, `csf_process_block_header`, `csf_process_attestations`, `csf_process_block`, `csf_slot_is_justifiable_after` + 5 本の build-only twin + 3 本のマイクロベンチ
- **`compute_lmd_ghost_head` は露出されていない** ← ユーザー要件との差分

**計測値 (PR #2 本文より)**
- Lean runtime init: ~43 ms (one-shot)
- Single FFI call `slot_is_justifiable_after`: 320 ns – 5.9 µs
- 持続スループット: ~92,000 calls/s (1M-call ループで 10.7 µs/call)
- `Vec.push × N`: N=100 → 91 µs、N=10K → 726 ms、N=20K → 2.97 s (**明らかな O(N²)**)

**既知の制約**
- Aeneas `Vec` → `List` 翻訳による O(N²) が根本問題。PR #2 単独では Ethereum scale infeasible
- axiom `alloc.vec.Vec.clear`, `alloc.vec.Vec.is_empty` は残置 (runtime panic の可能性あり)
- Aeneas 再生成時のパッチ自動化は未整備 (deferred)
- CI 未走行

**流用判断: 部分流用 (harness, build.rs, Ffi.lean, docs は丸ごと使える)**

---

### 1.2 PR #3 — perf/fast-process-attestations

| 項目 | 内容 |
|---|---|
| ステータス | OPEN, PR #2 の上にスタック |
| サイズ | +339 / 0、4 ファイル |
| ベース | `feat/rust-ffi-poc` |
| head commit | `1e10fe6` |

**差分**
- `ConsensusLean4/FastPath.lean` (新規 207 行) — `Vec` ↔ `Array` コンバータ + `isValidVoteFast` + `processSingleAttestationFast` + `serializeJustificationsFast`
- `ConsensusLean4/Ffi.lean` に `@[export csf_process_attestations_fast]` wrapper を追加
- `rust-ffi/src/main.rs` に fast path FFI decl + slow/fast parity check
- `docs/rust-ffi-benchmarks.md` に fast-path section を追加

**アルゴリズム**
- 入口で `Vec` → `Array` に O(V) 変換
- `justifications_validators` (flat `Vec Bool`) を `Array (H256 × Array Bool)` に unflatten
- per-attestation の各ステップを Array 操作 (O(1) index, O(V) scan) で置換
- 2/3 閾値達成時は slow path に bail (try_finalize の副作用を保持)
- 出口で Array → `Vec` に O(V) 変換

**計測値 (paired delta, release build)**

| V | A | slow (ms) | fast (ms) | speedup |
|---:|---:|---:|---:|---:|
| 500 | 16 | 31.70 | 1.57 | 20× |
| 500 | 64 | 135.35 | 6.13 | 22× |
| 1,000 | 16 | 140.32 | 2.75 | 51× |
| 1,000 | 64 | 780.21 | 10.29 | 76× |
| 2,000 | 16 | 796.89 | 5.96 | **134×** |
| 2,000 | 64 | 2,670 | 20.51 | 130× |

slow の per-(V²·A) 定数 ≈ 10 ns (二次性の証拠)、fast の per-(V·A) 定数 ≈ 160 ns。
この係数で外挿すると V=1M は slow ~2.2 日、fast ~数秒 / block。

**既知の制約**
- `processAttestationsFast_eq_slow` の形式的同値性証明は未完了 (parity check は実行時のみ)
- `hash_tree_root_*` は stub のまま (crypto cost ゼロ → 絶対時間は過小評価)
- aggregation_bits all-false 条件下の測定なので index_mut write path 未検証

**流用判断: 丸ごと採用**

---

### 1.3 Issue / 関連 PR

- `gh issue list` → 空。実際の issue は 0 件。README 表示の `open_issues_count` は PR カウントを含む GitHub 仕様のため。
- parent/source なし (fork ではない独立リポジトリ)

---

## 2. 2 エントリポイントの計算量と実行可能性の上限

### 2.1 `state_transition.state_transition` (Funs.lean:2693-2725)

```
state_transition (state, block)
├── process_slots state block.slot
│   ├── extend_to_slot (per-slot)
│   └── hash_tree_root_state  [STUB → ZERO]
└── process_block state block
    ├── process_block_header  (O(1) 程度)
    └── process_attestations  ← O(A·N²) の主ボトルネック
        ├── process_attestations_loop0 (A iterations)
        │   ├── _loop0_loop0_loop0  [N × J × N]
        │   ├── _loop0_loop1_loop0  [historical × O(V) lookup]
        │   └── _loop0_loop2        (vote tally)
        └── serialize_justifications  [R × J × N 3 重ループ]
```

**計算量** (Vec が List バックのとき):
- `process_attestations`: **O(A · N²)** が支配項 (PR #3 計測で係数 10 ns/(V²·A))
- `serialize_justifications`: O(R · N) (R ≤ 10 で実質線形)
- `process_slots`: O(S) (slots 数)
- **全体**: O(A·N²) が支配。fast path 適用で **O(A·N)**

### 2.2 `fork_choice.compute_lmd_ghost_head` (Funs.lean:1104-1154)

シグネチャ:
```lean
(start_root : H256)
(blocks : Vec (H256 × (U64 × H256)))
(attestations : Vec (U64 × AttestationData))
(min_score : U64)
→ Result (H256 × Vec (H256 × U64))
```

**N はパラメータに現れない**。スケールするのは:
- A = attestations 数 (外側ループ)
- B = blocks 数 (内側 tree traversal)

**ループ構造**:
```
compute_lmd_ghost_head
├── compute_lmd_ghost_head_loop0/4   [B iterations, min-slot block 探索]
├── compute_lmd_ghost_head_loop1     [B iterations, start_root 照合]
├── compute_block_weights            ← O(A · B²)
│   └── compute_block_weights_loop0
│       └── _loop0_loop0_loop0 (B)    [weights vec search O(B)]
├── compute_lmd_ghost_head_loop2/5   [children_map 構築 O(B)]
│   └── get_weight (O(B) lookup on weights Vec)   ← O(B²)
└── compute_lmd_ghost_head_loop3/6   [tree traversal O(B·max_children)]
```

**全体**: **O(A · B²)**。N に依存しないが、B (ethereum mainnet で ~32K) で二次。

**ユーザー要件との重要な不整合**:
ユーザーは「バリデータ数を振って計測」と書いているが、`compute_lmd_ghost_head` で N を振っても`weights` Vec の**値**が変わるだけで**計算量**は変わらない。計測するなら **B と A を振る**のが正しい。メモ承認後にユーザー意図の確認が必要。

### 2.3 Aeneas `alloc.vec.Vec` の実体 (rev 864eddb4)

GitHub raw (`Aeneas/Std/Vec.lean`) を取得して確認:

```
Vec α := { l : List α // l.length ≤ Usize.max }
```

| 操作 | 漸近コスト |
|---|---|
| `new` | O(1) |
| `len` | O(1) (キャッシュ長) |
| `index i` | **O(i)** (List 走査) |
| `index_mut i` | **O(i)** |
| `push x` | **O(n)** (`List.concat`) |
| `clear` | axiomatized (FunsExternal) |
| `is_empty` | axiomatized (FunsExternal) |

`@[extern ...]` による C 実装差し替えは**なし**。純粋 Lean。PR #3 の fast path はこれを Lean ネイティブ `Array` (mutable underlying、O(1) index、amortized O(1) push) にコピーして回避している。

### 2.4 実測可能スケール階段 (Option X 前提)

**方針**: 本タスクでは slow path (Aeneas 出力そのまま) の計測は**行わない**。代わりに:
- **state_transition**: handwritten `stateTransitionFast` を N 軸で計測 — 内部で `processAttestationsFast` を呼ぶ e2e 1 FFI コール
- **compute_lmd_ghost_head**: Aeneas 出力をそのまま 1 FFI コールで呼び、B, A 軸で計測 (N は内部パラメータ)
- 実測値がないセルは**外挿**と明示。PR #3 の `process_attestations_fast` 単独計測値から e2e を外挿する

#### state_transition e2e (A=64 固定)

| N | 根拠 | 時間 (1 block, 外挿) |
|---:|---|---:|
| 100 | PR #3 fast 係数 ~160 ns/(V·A) | ~1 ms |
| 1,000 | 〃 (PR #3 単独で 10.29 ms、e2e はそれ + process_slots/header 分) | ~10 ms |
| 10,000 | 〃 | ~100 ms |
| 100,000 | 〃 | ~1 s |
| 1,000,000 | 〃 (hash_tree_root stub 前提で過小評価の可能性) | ~10 s |

**注**: 上記は PR #3 の `process_attestations_fast` 単独値を「state_transition 全体の支配項」と仮定した外挿。実装後の実測で以下を確認する必要あり:
- process_slots (slot 進行 + 2 回の hash_tree_root_state stub) の実コスト
- process_block_header のチェック 3 件
- state_root 最終比較 (hash_tree_root_state × 1)
- 上記が process_attestations を覆すのは hash_tree_root が real 実装になったときのみで、stub のままなら process_attestations が支配的

#### compute_lmd_ghost_head e2e (Aeneas 出力そのまま)

| B | A | 複雑度 A·B² | 時間 (外挿、Vec=List ベース、実測なし) |
|---:|---:|---:|---:|
| 100 | 32 | 3·10⁵ ops | ~100 µs |
| 1,000 | 32 | 3·10⁷ ops | ~10 ms |
| 10,000 | 32 | 3·10⁹ ops | ~1 s |
| 32,000 | 128 | 1.3·10¹¹ ops | ~100 s ← 要 fast path (**本タスクでは対象外**) |

compute_lmd_ghost_head は **N 非依存**。Aeneas 出力は O(A·B²) なので、**本タスクのデフォルトは B ≤ 10K で打ち止め** (mainnet 級 B=32K は追加で `compute_lmd_ghost_head_fast` を書く必要があり、別スコープ)。

#### 理論下限 (参考、計測しない)

slow path (= Aeneas 出力そのまま) の state_transition は O(A·N²) で、N=10K で 64 s、N=1M で ~2.2 日。**これを測る意義はないので計測しない**が、「なぜ Option X が必要か」の根拠として記録しておく。

---

## 3. ビルド系の実例と制約

### 3.1 Lake の output 構造

- `.lake/build/lib/`: `.olean`, `.ilean`、`:static` で `.a`
- `.lake/build/ir/`: `.c`, `.c.o.export`, `.c.o.noexport`
- `@[export name]` で unmangled C シンボルが `.c.o.export` に出力される

### 3.2 precompileModules の取り扱い

- `precompileModules := true` は各モジュールを `.so` に事前コンパイル → interpreter を高速化
- **Issue #5509**: precompileModules + `@[extern]` で undefined symbol を起こすケースが報告されている
- **Mathlib + precompileModules**: Issue #9420 (Linux), #7917 (macOS) の存在
- **v4.28.0-rc1 固有のレグレッション**: 公開 issue には見つからず (但し RC なので未検証領域あり)
- **PR #2 は precompileModules を使わない**方式 (build.rs が `.c.o.export` を static リンク) を選択しており、これは堅い選択

### 3.3 libleanshared.so の扱い

- `~/.elan/toolchains/leanprover-lean4-v4.28.0-rc1/lib/libleanshared.so` を dynamic link するのが標準
- Lake は `.lake/build/lib/` に copy しない → consumer 側の build.rs で `cargo:rustc-link-search=native=<toolchain-lib>` と `rustc-link-lib=dylib=leanshared` を指定
- Runtime は `LD_LIBRARY_PATH` か `-Wl,-rpath=<toolchain-lib>` を使用 (PR #2 は rpath 埋め込み)
- `lean_initialize_runtime_module()` → `lean_initialize()` → `initialize_<pkg>()` の順序は必須

### 3.4 実例

| プロジェクト | 方式 | コメント |
|---|---|---|
| leanprover/lean4 `src/lake/examples/reverse-ffi/` | static + `@[export]` | 公式最小例 |
| lurk-lab/RustFFI.lean | static link from Rust | Rust → Lean の典型 |
| DSLstandard/Lean4-FFI-Programming-Tutorial-GLFW | `extern_lib` + C | FFI 学習向け |
| tydeu/lean4-alloy | Lean-in-C shim | 高機能だが学習コスト |

---

## 4. 推奨アプローチと代案

**ユーザー決定 (2026-04-24)**: PR #2 / #3 は参考資料として残し、独立ブランチで再実装する。よって推奨は下記 Option A (新規ブランチ) に確定。

### 4.1 推奨 (Option A + Option X): 新規ブランチで独立実装、2 エントリポイントを e2e で露出

**Option X の定義**: 2 エントリポイント (`state_transition`, `compute_lmd_ghost_head`) を**それぞれ 1 FFI コール**で e2e 実行させる。state_transition 側は Aeneas 出力のままだと O(A·N²) で実測不能なので、handwritten `stateTransitionFast` を用意して `processAttestationsFast` を内部で呼ばせる。compute_lmd_ghost_head 側は Aeneas 出力をそのまま呼ぶ (B ≤ 10K 前提)。

**入力構築モデル (Option II)**:
- Rust 側に `State` / `Block` / `Validator` / `H256` / `Vec<T>` 等の Rust 構造体を定義 (Aeneas 出力の Lean type と対応)
- 各型に `ToLean` trait 実装を書き、`lean_alloc_ctor` / `lean_box_*` / `lean_mk_string` 等で `lean_object*` を構築
- Rust 側で State/Block を組み立てて marshal 完了 → timer 開始 → FFI call → timer 終了、の順で計測するので **marshal コストは計測外**
- `build_state_lean(n, a, seed)` のような helper を Rust 側に用意 (決定的構築)、これはベンチループ前に 1 回呼ぶ
- **将来 Option III (SSZ バイト列) への移行時**: Rust の `ToLean` impl を捨てて `ssz_encode → bytes` に置換、Lean 側に SSZ decoder を追加する。issue で追跡

**露出する FFI シンボル (2 本 + no-op twin 2 本)**:
| シンボル | シグネチャ (Rust 側) | 中身 | 軸 |
|---|---|---|---|
| `csf_state_transition` | `(state: *mut lean_object, block: *mut lean_object) -> u8` | handwritten `stateTransitionFast` 全体 | N (A=64 固定) |
| `csf_state_transition_noop` | 同上 | 入力を受けて pipeline を回さず即 return (FFI 境界コストの twin) | 同上 |
| `csf_compute_lmd_ghost_head` | `(start_root, blocks, atts, min_score: *mut lean_object) -> *mut lean_object` | Aeneas `fork_choice.compute_lmd_ghost_head` | B, A |
| `csf_compute_lmd_ghost_head_noop` | 同上 | 入力を受けて pipeline を回さず即 return | 同上 |

twin の目的: `lean_inc`/`lean_dec` など FFI 境界自体の ~320 ns オーバーヘッドを測り、paired-delta で差し引いて pure pipeline cost を出す。

**handwritten Lean 側の構造** (`ConsensusLean4/FastPath.lean` 相当、ゼロから再実装):
```
stateTransitionFast : State → Block → Result (Result Unit Error × State)
├── process_slots (Aeneas 出力そのまま、線形)
├── process_block_fast
│   ├── process_block_header (Aeneas 出力そのまま、定数時間)
│   └── processAttestationsFast (Array ベースの手書き、PR #3 参照)
└── hash_tree_root_state 照合
```

`compute_lmd_ghost_head` は手書きせず、Aeneas 出力 (`Funs.lean` の定義) をそのまま `@[export]` 経由で呼ぶ。

**骨子** (本メモ承認後、別途「実装計画」として再承認を取る):
1. 新規 feature branch (例: `feat/ffi-benchmarks`) を `main` から切る
2. `ConsensusLean4/FunsExternal.lean` の 5 axiom に real def を追加
3. `ConsensusLean4/FastPath.lean` (新規) に `processAttestationsFast` + `processBlockFast` + `stateTransitionFast` を実装 — PR #3 のアルゴリズムを参考にコードはゼロから書き直し
4. `ConsensusLean4/Ffi.lean` (新規) に `@[export]` wrapper 4 本を定義 (pipeline wrapper 2 本 + noop twin 2 本)
5. `lakefile.lean` に必要最小限の設定 (`precompileModules := false`、static facet を build する target)
6. `rust-ffi/` crate を**ゼロから**作成:
   - `src/lean_types.rs`: `State` / `Block` / `Validator` / `H256` / `Checkpoint` / `AggregatedAttestation` 等の Rust 構造体定義
   - `src/to_lean.rs`: `ToLean` trait 定義 + 各型の impl (`lean_alloc_ctor` / `lean_box_u64` / `lean_mk_empty_array` 等の FFI 呼び出し)
   - `src/ffi.rs`: `extern "C"` ブロックで 5 個の Lean 側関数 (`csf_ping` + 4 本) を宣言
   - `src/bench/{state_transition.rs, fork_choice.rs}`: 2 エントリポイント別の bench バイナリ
   - `build.rs`: `.c.o.export` を動的スキャンして static link、`libleanshared.so` を dylib link、RPATH 埋め込み
7. Smoke test 3 段階 (セクション 7) を最初のマイルストーン
8. N 軸ベンチ: state_transition を `cargo run --release --bin bench-state-transition` で N=100, 1K, 10K, 100K (1M はオプション)
9. B, A 軸ベンチ: compute_lmd_ghost_head を `cargo run --release --bin bench-fork-choice` で B=100, 1K, 10K × A=32/128
10. 結果を `docs/rust-ffi-benchmarks.md` (または別名) に書く
11. 完了後、PR #2 / #3 の扱いはユーザー判断
12. **別途 issue 発行**: Option III (SSZ バイト列移行) のトラッキング issue を作成 (本メモ承認直後、plan mode 終了後に実施)

**採用理由**:
- ユーザー意向: 既存 PR の設計を再検証したい
- 設計判断 (wrapper 分割粒度、build.rs の object 走査範囲、fast path のデータ構造) を本タスクで能動的に選べる
- compute_lmd_ghost_head を最初から含む一貫したベンチ設計が可能

**リスク / 留意点**:
- **二重実装コスト**: PR と同じ trap に引っかかりうる (Aeneas O(N²), axiom panic, precompileModules Issue #5509 など) → 本メモのセクション 6 (既知制約) を事前チェックリスト化する
- **PR との並存**: 同一 repo に 3 本の feature branch が open になる。本ブランチ側の変更が `ConsensusLean4/FunsExternal.lean` に触れると PR #2 とマージ衝突する。どちらを正にするかを初期に決める必要あり (セクション 8 の Q5 追加)
- **Aeneas regeneration drift**: PR #2 同様、`FunsExternal.lean` の 5 axiom 置換が Aeneas 再生成で失われる問題を独立実装でも解決する必要あり

**Option A で「参考はしても copy はしない」ラインの具体化**:

| 項目 | PR から copy する | 仕様 / 知見のみ参照 |
|---|---|---|
| FFI 初期化順序 (`lean_initialize_runtime_module` → `lean_initialize` → `initialize_...`) | ー | ✓ (Lean 公式 FFI docs が一次ソース) |
| build.rs の object 走査方針 | ー | ✓ (`.c.o.export` を拾う、Mathlib tooldir 除外) |
| `@[export csf_*]` 命名規則 | ー | ✓ (衝突回避の prefix アイデアとして) |
| 結果の UInt8 sentinel 設計 | ー | ✓ (0/1/2/3 の意味付けは再決定してよい) |
| FastPath の `Vec` ↔ `Array` 変換アルゴリズム | ー | ✓ (アルゴリズムは同じものを再実装) |
| paired-delta 計測手法 | ー | ✓ (手法として採用、コードは書き直し) |

### 4.2 代案 B: PR #2 / #3 を main にマージしてその上に積む (2026-04-24 見送り)

**見送り理由 (ユーザー決定)**: 設計判断を再検証したい。初期投資を再支払いしてでも。

### 4.3 代案 C: criterion でマイクロベンチのみ、FFI はやらない

**見送り理由**: 「Rust から FFI 経由で呼ぶ」がユーザー要件なのでスコープ逸脱。Lean 側でも `IO.monoMsNow` で測ると元々 possible。

### 4.4 代案 D: cxx / bindgen を使う

**見送り理由**: Lean が generate する C コードは ABI が `extern "C"` 準拠なので raw FFI で十分。cxx は C++ ABI で複雑化するだけ。bindgen も自動 header 生成の利点が小さい。

---

## 5. 計測方法

### 5.1 時間計測

- **推奨**: PR #2 既存方式 (`std::time::Instant` + paired-delta、build-only twin を back-to-back で引き算して construction cost を除去)。Criterion.rs は warmup と統計が強力だが paired-delta 技法と重複する。compute_lmd_ghost_head の計測追加時は criterion の `iter_batched` を使う手もある (blocks Vec 構築コストを除外するため)。
- Lean 側の `IO.monoMsNow` は ms 粒度なので短時間計測には向かない。Rust 側の計時を正とする。
- Lean runtime init (~43 ms) はベンチループ外で一度だけ実施。

### 5.2 メモリ計測

- **推奨**: Linux で `getrusage(RUSAGE_SELF)` から `ru_maxrss` を取る (Rust では `libc` crate)。
- **重要**: `ru_maxrss` はプロセスライフタイム全体の peak を返すため、**2 エントリポイントは別プロセスで独立に計測する**必要あり (§9 参照)。同一プロセス内で state_transition → compute_lmd_ghost_head の順に走らせると、後者の RSS には前者の peak が混入する。
- `memory-stats` crate も同等だが依存が増えるだけなので必要性薄。
- Lean ヒープの内部状態は `lean_ref_count` などで直接取れるが、**プロセス全体の RSS** のほうがユーザーが知りたい値に近い。
- 補足: `valgrind --tool=massif` は絶対ヒープピークを精緻に取れるが FFI 初期化を含めた測定で時間がかかるため、最大セル (N=100K や B=10K, A=128) のみ別プロセスで補足計測する運用がよい。

### 5.3 再現性

- release build (`cargo build --release`) で計測
- CPU governor を performance、`taskset -c <core>` でピン止め、ハイパースレッドの影響を減らす
- 各 (N, A, B) cell は 5 試行以上、中央値 + IQR を記録

---

## 6. 既知の制約 (列挙)

| # | 制約 | 影響 | 対応 |
|---|---|---|---|
| C1 | Aeneas `Vec` が `List α` backing → O(N²) | Aeneas 出力そのままの state_transition は N>2K で実測困難 | handwritten `stateTransitionFast` (Option X) で回避、slow path は計測対象外 |
| C2 | `hash_tree_root_*` が `ZERO` を返す stub | 絶対時間を過小評価 (SSZ hashing ~10-100 µs/State が欠落) | 「実 consensus では + X% 遅い」と注記 |
| C3 | axiom `Vec::clear`, `Vec::is_empty`, `Ordering.eq`, `Result.branch`, `Result.from_residual` | 未実装で runtime panic の可能性 | PR #2 で real def に置換済。Aeneas 再生成で戻るので patch 自動化要 |
| C4 | aggregation_bits 全 false で計測 → index_mut write path 未検証 | worst case 時間が未知 | seed で aggregation_bits を一部 true にするテストを別途 |
| C5 | 署名検証なし (BLS なし) | 実 consensus より軽い | 注記のみ。導入は別スコープ (詳細は §6.1) |
| C6 | precompileModules + `@[extern]` の Issue #5509 | 特定構成で linker error | `precompileModules := false` を維持 |
| C7 | Mathlib サイズ (Aeneas 経由で pull) | リンク時間 / バイナリサイズが大きい | build.rs で不要 object を除外 (PR #2 既存) |
| C8 | compute_lmd_ghost_head のベンチは未計測 | ユーザー要件未達 | Option A の手順 3–4 で追加 |
| C9 | `try_finalize_loop1_loop0` など他の O(?·N) 候補 | PR #3 fast path 対象外 | 計測して必要なら追 fast path |
| C10 | Aeneas regeneration で `Funs.lean`/`Types.lean`/`FunsExternal_Template.lean` 上書き (`FunsExternal.lean` は保持) | FastPath や Ffi は独立ファイルなので影響小、ただし patch ファイルは drift | `FunsExternal.lean` diff を CI で監視 |
| C11 | lean-toolchain は v4.28.0-rc1 (RC) | 正式リリースで挙動変化の可能性 | **toolchain 変更は本メモとは別に単独承認** |
| C12 | Rust 側 ToLean impl は Aeneas 出力の type 形状に依存 | `Types.lean` が再生成で変化すると Rust 側が壊れる | `Types.lean` diff を CI で監視 (C10 と同じ watcher)、Option III (SSZ) 移行で根本解決 |
| C13 | Option II は marshal cost を計測外に置く設計 | 実 client の "Rust から Lean に State を渡す総コスト" とは別物になる | timer の置き方を明示、marshal 別途計測用の cell も用意 (`*_noop` twin) |

### 6.1 C5 詳細: 署名検証の位置づけと Rust 連携モデル (参考)

本プロジェクトでは BLS 署名検証を組み込まないが、**実 consensus client で組み込むとしたらどうなるか**の整理を残しておく。将来 spec 拡張を検討するときの参照用。

#### spec 上どちらのエントリポイントに含まれるか

- **state_transition 側が主担当**。Ethereum consensus の実 spec では `state_transition` (特に `process_block` 経路) で全ての block 内署名を verify する:
  - Block proposer 署名 (`process_block_header` 内)
  - 集約 Attestation 署名 (`process_attestations` 内、BLS12-381 集約)
  - Altair+ では sync committee 署名、Deposit 署名、Voluntary exit 署名、Proposer/Attester slashing の各署名
- **compute_lmd_ghost_head (fork_choice) は signature を verify しない**。前提として入力 attestations は**事前に attestation pool で verify 済**。fork choice は pure な graph / weight 計算に専念する ("pre-verified attestation pool" モデル)
- 3SF-mini の Aeneas 生成コードでも fork_choice 側には signature 関連の logic は**存在しない**

#### Rust 側 BLS 実装を連携させる 3 つの設計モデル

現実の consensus client は BLS 実装 (例: `blst`, `milagro_bls`, `bls12_381`) を Rust で持つのが一般的。仮に本プロジェクトで連携するなら:

**α. Lean から Rust の BLS 関数を `@[extern]` で呼び返す**
```lean
@[extern "consensus_bls_verify"]
axiom consensusBlsVerify : @& ByteArray → @& ByteArray → @& ByteArray → Bool
  -- pubkey / signature / message
```
```rust
#[no_mangle]
extern "C" fn consensus_bls_verify(pk: *const u8, sig: *const u8, msg: *const u8) -> u8 {
    // blst の verify を呼ぶ
}
```
Lean 側の `process_attestations` 等で `consensusBlsVerify` を呼ぶ。**問題**: attestation 数 × FFI 境界 = 大量の callback で境界コストが累積。1M validators × 複数 attestations のベンチに耐えない。

**β. Rust 側で事前 verify、Lean には検証済入力のみ渡す (推奨される整合的モデル)**
- Rust 側で block を受け取り、BLS verify を先に済ませる
- verify OK → Lean に state/block を marshal (現行 Option II の拡張) → FFI 呼び出し → state 更新
- verify NG → Lean を呼ばず reject
- **Lean 側は signature を触らない**: spec 側の純粋さが保たれる
- 現実の consensus client (Lighthouse, Prysm, Teku など) はすべて**この分担**で動いている

利点:
- 関心の分離 (cryptography は Rust、semantics は Lean)
- FFI 境界は block 単位 (attestation 毎の境界跨ぎなし)
- Lean の formalization target から BLS を exclude できる (証明対象を狭く保てる)

**γ. Rust / Lean 両方で dual verify (研究用)**
- 同じ署名を 2 重 verify、トラストモデル研究の題材
- 実用価値低い (コスト重複、メリット薄)

#### 結論

- 本プロジェクトの FFI ベンチでは BLS は**組み込まない** (C5 通り)
- もし将来組み込むなら **β モデル**が標準: Rust が gate-keeper として事前 verify、Lean は verify 済入力を受けて state を進める
- Lean spec 側に BLS を入れる動機はない (Aeneas 形式化の対象を consensus semantics に絞るため)
- spec の `process_attestations` / `process_block_header` に書かれている "signature verify" ステップは、**β の場合 Rust 側で先取り実行されるスキップ相当**として扱う

---

## 7. Smoke test — 3 段階で e2e まで通す

Option X では smoke を 3 ステップに分割し、FFI 境界 → e2e ベンチ対象の順に段階検証する:

### Stage 1: `csf_ping` — FFI 往復の最小確認

```lean
@[export csf_ping] def csfPing (n : UInt64) : UInt64 := n + 1
```
```rust
extern "C" {
  fn lean_initialize_runtime_module();
  fn lean_initialize();
  fn initialize_<pkg>(b: u8, w: *mut core::ffi::c_void) -> *mut core::ffi::c_void;
  fn csf_ping(n: u64) -> u64;
}
assert_eq!(csf_ping(41), 42);
```

**通すべき項目**: `lake build :static` 成功、`nm` でシンボル可視、`cargo build` がリンクエラーなし、実行が exit 0。

### Stage 2: `csf_state_transition` — エントリポイント 1 本目 e2e

最小入力 (validators=2、attestations=1、blocks=1) を **Rust 側で構築し `ToLean` で `lean_object*` に marshal** してから、1 FFI コールで `stateTransitionFast` を呼ぶ。

**通すべき項目**:
- Rust 側で構築した State/Block が Lean 側で正しく復元されている (小さい cell で Lean 側に debug print を仕込むか、noop twin で lean_inc/lean_dec を通すだけで panic しないことを確認)
- `csf_state_transition(state_obj, block_obj) == OK sentinel (1)` を確認
- 入力を一か所壊した (例: block.slot を不正に) 場合に Err sentinel を返すこと
- runtime panic が発生しないこと (FunsExternal の axiom 残置時に panic する可能性への網)

### Stage 3: `csf_compute_lmd_ghost_head` — エントリポイント 2 本目 e2e

最小入力 (blocks=3、attestations=2) を Rust 側で構築し ToLean で marshal、1 FFI コールで Aeneas の `compute_lmd_ghost_head` を呼ぶ。

**通すべき項目**:
- 返り値の (head_root, weights) が期待値と一致
- blocks=[] (空) で `start_root` を素通しで返すエッジケースも確認

Stage 1→2→3 のいずれかで失敗した場合、ベンチフェーズには進まない。

---

## 8. ユーザー確認が必要な論点

2026-04-24 時点の確定事項 (全 Q 解消済):

- **A1 (確定)**: compute_lmd_ghost_head は B と A を振る。state_transition は N を振る。2 エントリポイントで軸が異なることを `docs/rust-ffi-benchmarks.md` に明記する。
- **A2 (確定)**: PR #2 / #3 は参考として残し、本タスクは新規ブランチで独立実装する。
- **A3 (確定、旧 Q3)**: `hash_tree_root_*` は stub (ZERO) のまま、レポートに "crypto cost excluded" を注記。実 SSZ Merkleization は [issue #5](https://github.com/NyxFoundation/consensus-lean4/issues/5) で future work として追跡、本タスクでは実施しない。
- **A4 (確定、旧 Q4)**: N スケール上限は、実測 N ≤ 100K (5 試行)、N=1M は 1 試行 (参考値)。ベンチ実行時間は ~10–15 分の見込み。
- **A5 (確定、旧 Q5)**: PR #2 と `FunsExternal.lean` が編集衝突しうるが、両方 open のまま本ブランチで diff を最小化する方針 (選択肢 b)。axiom 置換は必要最小限に留める。
- **A6 (確定)**: slow path (Aeneas 出力そのまま) のベンチは行わない。Option X で e2e のみ。形式検証の保証が Aeneas 出力には付随しないため、slow を残す動機がない。
- **A7 (確定、旧 Q7)**: compute_lmd_ghost_head の B 上限は B ≤ 10K で打ち止め。B=32K (mainnet) は別途 `compute_lmd_ghost_head_fast` を書く必要があり、Future work。
- **A8 (確定)**: 入力構築は Option II (Rust 側で State/Block/blocks/attestations を構築し `ToLean` で marshal → FFI)。marshal コストは timer 外に置き、ベンチ値は pipeline cost に絞る。
- **A9 (確定)**: Option III (SSZ バイト列で FFI 境界を再設計) は future work。[issue #4](https://github.com/NyxFoundation/consensus-lean4/issues/4) で追跡、本タスクでは実施しない。
- **A10 (確定)**: 2 エントリポイントは別プロセスで独立計測 (`ru_maxrss` peak を分離するため)。`cargo run --release --bin bench-state-transition` と `cargo run --release --bin bench-fork-choice` に分割。

本メモ承認時に残る論点: **なし** (全 Q 解消済)。

---

## 9. 検証 (承認後の実施方法)

本メモ承認 → 次に「実装計画」を別途書いて承認を取る → 実装 → 以下で end-to-end 検証:

1. **型チェック**: `lake build` が警告ゼロで通る
2. **シンボル export**: `nm .lake/build/lib/libConsensusLean4.a | grep csf_` に `csf_ping`, `csf_state_transition`, `csf_state_transition_build`, `csf_compute_lmd_ghost_head`, `csf_compute_lmd_ghost_head_build` が全て出る
3. **Smoke test Stage 1–3**: セクション 7 の 3 段階を順に通す (`csf_ping` → `csf_state_transition` 最小入力 → `csf_compute_lmd_ghost_head` 最小入力)
4. **Sanity check**: state_transition と compute_lmd_ghost_head それぞれ、明らかに不正な入力で Err sentinel を返すこと、runtime panic なし
5. **計測実行 (2 エントリポイントは別プロセスで独立実行)**:
   - **プロセス分離の理由**: `ru_maxrss` はプロセスライフタイム全体の peak を拾うため、両ベンチを同一プロセスで連続実行すると後者の RSS に前者の peak が混入する。クリーンな per-entry-point メモリ測定のため CLI サブコマンド等で別 invocation にする (例: `cargo run --release -- bench-state-transition` と `cargo run --release -- bench-fork-choice`)。
   - **state_transition**: N=100,1K,10K,100K で 5 試行 (N=1M は 1 試行)、A=64 固定、1 プロセス = 1 N 値 (N 間でも RSS 分離したい場合はさらに細分化)、`ru_maxrss` と elapsed を記録
   - **compute_lmd_ghost_head**: (B, A) ∈ {100,1K,10K} × {32,128} で 5 試行、同様に per-cell プロセス分離、`ru_maxrss` と elapsed を記録
   - 両者とも `lean_initialize_runtime_module` → `lean_initialize` → `initialize_<pkg>` は各プロセスで 1 回、ベンチループ外で実施 (初期化の ~43 ms はベンチ時間から除外)
6. **ドキュメント更新**: `docs/rust-ffi-benchmarks.md` に新規結果を append、外挿セルと実測セルを明示
7. **再現手順**: README に `elan which lean` / `lake build` / `cargo run --release` の 3 ステップを明記

---

## 10. 参考: 本メモ作成時に使った探索

- `gh pr view 2 / 3 --json ...`, `gh pr diff 2 / 3`, `gh api .../pulls/{n}/commits`
- Aeneas `Vec.lean` @ `864eddb4` を GitHub raw で取得
- `/home/adust/consensus-lean4/ConsensusLean4/Funs.lean` を直接読んで 2 エントリポイントのループ構造を確認
- leanprover/lean4 Issue #5509, #9420, #7917 の記述を参照
- 実例 repos: lurk-lab/RustFFI.lean, DSLstandard/Lean4-FFI-Programming-Tutorial-GLFW, leanprover/lean4 `src/lake/examples/reverse-ffi/`

---

## 11. 付録: ファイル形式と変換の流れ

Lean ↔ Rust FFI を組むときに出てくるファイル形式は数が多く、どれが誰によって生成され、どうつながるかが分かりにくい。この付録で一通り整理する。

### 11.1 登場するファイル形式

| 拡張子 / ファイル名 | 何者 | 生成元 | 用途 |
|---|---|---|---|
| `.lean` | Lean ソース | 人間 | 編集対象 |
| `.olean` | Lean モジュールのコンパイル済み bytecode | `lean` コンパイラ | 他の Lean モジュールが `import` したときに読む。Lean interpreter の入力 |
| `.ilean` | 言語サーバー (LSP) 用メタデータ index | `lean` コンパイラ | エディタの定義ジャンプ等。ビルド / FFI には不要 |
| `.c` | Lean が生成した C 中間コード | `lean --c` オプション | 次ステップで C コンパイラに渡される |
| `.c.o.export` | `.c` をコンパイルした object、`@[export]` シンボルが外部可視 | `leanc` (Lean 同梱 C コンパイラ wrapper) | **FFI 消費側から link する対象**。Rust build.rs が拾う |
| `.c.o.noexport` | 同じく object、`@[export]` シンボルは hidden | `leanc` | Lean 同士のリンク用。FFI 側はスルー |
| `.a` | 静的アーカイブ (複数 `.o` をまとめたもの) | `ar` (Lake `:static` facet) | 単一 `libFoo.a` として Rust からリンク可能 |
| `.so` | 共有ライブラリ | Lake (`:shared` facet / `precompileModules := true`) | 本タスクでは使わない |
| `libleanshared.so` | **Lean runtime 本体**の共有ライブラリ | elan toolchain 同梱 (自分ではビルドしない) | Rust binary が runtime 関数 (`lean_alloc_ctor` 等) を呼ぶために dylib link する |
| `libInit_shared.so` | Lean 標準ライブラリ `Init` の native ビルド | 同上 | libleanshared と一緒に dylib link |

### 11.2 パイプライン全体図

```
人間が書いた Lean ソース
  ConsensusLean4/Ffi.lean                 (@[export csf_foo] def foo ...)
         │
         │  lean --o Ffi.olean --c Ffi.c  (lake が駆動)
         ▼
  ┌─────────────────────────────┐
  │ .lake/build/lib/*.olean       (import 時に使われる、FFI には無関係)
  │ .lake/build/lib/*.ilean       (LSP 用、FFI には無関係)
  │ .lake/build/ir/*.c            (Lean → C 中間)
  └─────────────────────────────┘
         │
         │  leanc -c -o Ffi.c.o.export Ffi.c  (Lean が駆動、@[export] シンボルが visible)
         │  leanc -c -o Ffi.c.o.noexport Ffi.c  (hidden 版、内部リンク用)
         ▼
  ┌─────────────────────────────┐
  │ .lake/build/ir/*.c.o.export    ← これを Rust が link
  │ .lake/build/ir/*.c.o.noexport   (FFI 側からは不要)
  └─────────────────────────────┘
         │
         │  ar rcs libConsensusLean4.a *.c.o.export       (Lake :static facet)
         ▼
  .lake/build/lib/libConsensusLean4.a
         │
         │  Rust 側 build.rs で (PR #2 の実例):
         │    cargo:rustc-link-arg=-Wl,--start-group
         │    cargo:rustc-link-arg=<各 .c.o.export のパス>  (再帰スキャン)
         │    cargo:rustc-link-arg=-Wl,--end-group
         │    cargo:rustc-link-search=native=<toolchain>/lib/lean
         │    cargo:rustc-link-lib=dylib=leanshared
         │    cargo:rustc-link-lib=dylib=Init_shared
         │    cargo:rustc-link-lib=dylib=stdc++
         │    cargo:rustc-link-lib=dylib=gmp
         │    cargo:rustc-link-arg=-Wl,-rpath,<toolchain>/lib/lean
         ▼
  target/release/rust-ffi   ← 最終 binary
    ├── Lean が吐いた .c.o.export が static link 済
    ├── libleanshared.so, libInit_shared.so を実行時に dlopen
    └── rpath 埋め込みで LD_LIBRARY_PATH 不要
```

### 11.3 Lean が吐く `.c` は普通の C じゃない

Lean compiler が `.c` を生成するとき、ほとんどの Lean 値は `lean_object *` (ポインタ) として表現される。プリミティブ型 (UInt*, Bool, Float など) は unbox されて C のネイティブ型で渡される。

**例: プリミティブのみ (unboxed)**
```lean
@[export csf_add] def add (a b : UInt64) : UInt64 := a + b
```
```c
// 生成される C (概念)
LEAN_EXPORT uint64_t csf_add(uint64_t a, uint64_t b) { return a + b; }
```
Rust 側は `extern "C" fn csf_add(a: u64, b: u64) -> u64;` でそのまま呼べる。

**例: ADT を扱う (boxed)**
```lean
@[export csf_state_transition]
def csfStateTransition (state : State) (block : Block) : UInt8 := ...
```
```c
LEAN_EXPORT uint8_t csf_state_transition(lean_object* state, lean_object* block) { ... }
```
Rust 側:
```rust
extern "C" {
    fn csf_state_transition(state: *mut lean_object, block: *mut lean_object) -> u8;
}
```
呼ぶ前に `state` と `block` を `lean_alloc_ctor` などで組み立てる必要がある (= Option II の ToLean impl の仕事)。

### 11.4 プリミティブ vs boxed の境界

| 型 | C での表現 | 備考 |
|---|---|---|
| `UInt8` / `UInt16` / `UInt32` | `uint8_t` / `uint16_t` / `uint32_t` | unboxed |
| `UInt64` / `USize` | `uint64_t` / `size_t` | unboxed (64bit OS 前提) |
| `Float` / `Float32` | `double` / `float` | unboxed |
| `Bool` | `uint8_t` | unboxed (0/1) |
| `Char` | `uint32_t` | unboxed (Unicode scalar) |
| `Nat` / `Int` | `lean_object*` | **boxed** (任意精度整数) |
| `String` | `lean_object*` | **boxed** |
| ADT (構造体 / enum / inductive) | `lean_object*` | **boxed** |
| `Array α` | `lean_object*` | **boxed** |
| `List α` | `lean_object*` | **boxed** |

本タスクで使う Aeneas 生成型の分類:
- `Std.U64` = `{ bv : BitVec 64 }` の構造体 → **boxed** (素朴な UInt64 ではない点に注意)
- `H256` = `{ val : Array U8 // ... }` → **boxed** (Array + proposition)
- `Validator` / `Checkpoint` / `Block` / `State` → **boxed** (ADT)
- `Vec α` = `{ l : List α // ... }` → **boxed** (List)

したがって FFI で渡す `State` は **lean_object ツリー** であり、Rust 側 `ToLean` impl は再帰的にそのツリーを組み立てる。

### 11.5 `@[export]` 属性が何をするか

```lean
@[export csf_foo] def foo (x : UInt64) : UInt64 := x + 1
```

コンパイラがこれを見ると:
1. **関数名を mangle せず `csf_foo` でそのまま C シンボルを出す** (通常は `l_ConsensusLean4_Ffi_foo___boxed` のように Lean 内部空間の名前がつく)
2. `LEAN_EXPORT` マクロを付ける (`__attribute__((visibility("default")))` + `extern "C"` に展開)
3. その object は `.c.o.export` 側に配置される (`.c.o.noexport` には入らない)

修飾しない普通の `def`:
- 名前はマングルされる (バージョン間で変わりうる)
- デフォルトで hidden visibility
- `.c.o.noexport` に出る

**ルール**: **FFI 境界に露出する関数は必ず `@[export <安定な名前>]` を付ける**。`csf_` プレフィックスは consensus-lean4 FFI symbols 用の慣例 (PR #2 で採用済)。

### 11.6 ランタイム初期化は 4 段階

Rust main から Lean 関数を呼ぶ前に、以下を**この順序で exactly once** 実行する (PR #2 の main.rs 実例):

```rust
extern "C" {
    fn lean_initialize_runtime_module();
    fn lean_initialize();
    fn initialize_consensus_x2dlean4_ConsensusLean4_Ffi(builtin: u8, w: *mut c_void) -> *mut c_void;
    fn lean_io_mark_end_initialization();
}

unsafe {
    lean_initialize_runtime_module();                                   // (1) runtime core を起動
    lean_initialize();                                                  // (2) IO monad の世界を初期化
    initialize_consensus_x2dlean4_ConsensusLean4_Ffi(1, std::ptr::null_mut());  // (3) 各モジュールの top-level 初期化
    lean_io_mark_end_initialization();                                  // (4) 初期化フェーズ終了を runtime に通知
}
// この後に @[export] 関数を呼んで OK
```

- **(1)** runtime 側のシングルトン状態 (allocator, thread-local 等) を構築
- **(2)** IO action を走らせる基盤 (world トークン) を用意
- **(3)** 各 Lean モジュールの `def` の side effect を実行し、constant を alloc。`initialize_<escaped_package>_<module_path>` が関数名。dash (`-`) は `_x2d` に escape される
    - 例: パッケージ `consensus-lean4`、モジュール `ConsensusLean4.Ffi` → `initialize_consensus_x2dlean4_ConsensusLean4_Ffi`
    - 依存モジュール (`ConsensusLean4.Funs`, `ConsensusLean4.FastPath` 等) の初期化は Lean runtime が transitive に呼んでくれるので、**エントリモジュール分だけ呼べばよい**
- **(4)** 「初期化完了」を runtime に伝える。これを呼ばずに通常の Lean 関数を呼ぶと、あるケースで IO state が inconsistent になる (PR #2 実装はこれを入れている)

この順序を破ると `lean_panic_fn` で落ちるか、最悪 SIGSEGV。

### 11.7 リンク構成の地形

Rust binary が最終的に必要とするもの:

1. **Lean コードの object 群** (`.c.o.export`): Lake が生成。build.rs で `.lake/build/ir/` 以下を再帰的にスキャンし、`Cache` / `LongestPole` / `Shake` ディレクトリを除外 (Mathlib の meta-build ツール用 object が入っているため) して拾う
2. **Lean runtime の shared lib**: `<toolchain>/lib/lean/libleanshared.so`。**`lib/` 直下ではなく `lib/lean/` の下**にある点に注意
3. **Lean Init 標準ライブラリ**: `libInit_shared.so` (同じディレクトリ)
4. **C++ / gmp**: Lean runtime が依存しているので dylib link
5. **RPATH**: `-Wl,-rpath,<toolchain>/lib/lean` を埋め込んで LD_LIBRARY_PATH なしで動かせるようにする

`<toolchain>` の取得は `elan which lean` → parent 2 段上がって `lib/lean` を join する (PR #2 build.rs 方式)。ハードコードすると `rustup`/`elan` の再インストールで壊れる。

### 11.8 誰がどのファイルを触るか (まとめ)

| 担当 | ファイル |
|---|---|
| **自分で書く** | `ConsensusLean4/{FastPath, Ffi, FunsExternal}.lean`、`rust-ffi/src/*.rs`、`rust-ffi/build.rs`、`rust-ffi/Cargo.toml`、`lakefile.lean` (最小限) |
| **Aeneas が再生成する** | `ConsensusLean4/{Funs, Types, FunsExternal_Template}.lean` (手動編集しない、ただし FunsExternal.lean は Aeneas に上書きされない) |
| **Lake が自動で作る** | `.lake/build/lib/*.olean`、`.lake/build/lib/*.ilean`、`.lake/build/ir/*.c`、`.lake/build/ir/*.c.o.export`、`.lake/build/ir/*.c.o.noexport`、`.lake/build/lib/*.a` |
| **toolchain 付属 (自分ではビルドしない)** | `libleanshared.so`、`libInit_shared.so`、`lean_*` runtime 関数群 |
| **Cargo が自動で作る** | `rust-ffi/target/release/*` (最終 binary) |

`.lake/` と `target/` は `.gitignore` 対象 (既存 `.gitignore` で `.lake/` は除外済)。

### 11.9 なぜ Lean は Rust より遅いのか (本タスクでの寄与源)

「Lean が遅い」には 3 層あって、**言語ランタイムの構造的性質** + **Aeneas 翻訳の癖** + **本プロジェクト特有の stub 設計**が重なっている。

#### レイヤー 1: Lean 言語ランタイムとして本質的に遅い理由

**(1) ほとんど全ての値が heap 上の `lean_object *` (ref-counted)**

プリミティブ (UInt*, Float, Bool, Char) だけ unboxed、それ以外 (ADT, Array, List, String, BitVec, 構造体) は全部 heap pointer。`state.validators` のような field access は「ポインタ参照 → ref count チェック → 次のポインタ参照」のチェーン。Rust なら struct field access = single `mov` 命令。

**(2) Ref counting の更新コストが毎操作に乗る**

ref count の +1/-1 は atomic instruction (~5 ns)。`{ s with slot := s.slot + 1 }` のような構造体更新でも発生。Rust の move semantics は +0 命令。

**(3) 純粋関数型のセマンティクス → 共有されたデータの更新が O(n) コピー**

```lean
let s1 := { s with slot := newSlot }
let s2 := { s with justified := newJ }
```

`s` が共有されている (refcount > 1) と、`s1`/`s2` 作成時に全 field を新 ctor にコピー。**"Functional But In-Place" (FBIP)** 最適化で refcount == 1 の時だけ in-place mutation に落ちるが、別所で参照していたらアウト。Rust は `&mut` で mutation がゼロコスト。

**(4) 自動ベクトル化が効かない**

Rust/LLVM は `for x in array { sum += x }` を AVX2 で 8 並列実行 (~0.1 ns/element)。Lean の `.c` 出力は heap pointer chase になっていて LLVM が SIMD 展開できない形。`process_attestations` の aggregation_bits ループがその典型 — Rust なら bit-parallel で数十倍速い。

**(5) Cross-module inlining が弱い**

Lean は `.olean` 単位でコンパイル、呼び出し先が別モジュールだと inline がかかりにくい。Rust は crate 単位 + LTO でほぼ全域 inline。

**(6) Generic の dispatch が dictionary-passing**

Lean は Haskell 型クラスと同じ方式で、`Add α` dictionary (vtable 相当) を引数に取って間接呼び出し。**monomorphize されない**。Rust は `add::<u64>` を具象化してインライン化。

#### レイヤー 2: Aeneas 翻訳に特有の遅さ

**(7) Rust `Vec<T>` → Lean `{ l : List α // ... }` 翻訳 (= C1 の根本原因)**

Rust の `Vec<T>` は array backing で O(1) index + amortized O(1) push。Aeneas 翻訳は `List α` backing で **O(n) index**、**O(n) push**。`process_attestations` で `aggregation_bits[i]` を 1M 回読むと、1M × avg(N/2) = 500G の cons cell walk → O(A·N²)。N=1M で 2 日かかる直接原因。

**これは Lean が遅いというより、Rust の mutable vector を Lean の functional list に写しているから**。PR #3 の fast path は「入り口で List → Array に詰め直す」ことで O(A·V) に落としている。

**(8) `Std.U64` が `{ bv : BitVec 64 }` の wrapper**

Aeneas は Rust の `u64` を `Std.U64 = { bv : BitVec 64 }` 構造体として翻訳。`BitVec 64` 自体は内部的に boxed な表現を取る場合があり、Rust の `u64` (64bit register) より重い。算術毎に refcount 操作が入ることもある。Lean コンパイラが最適化で unbox するパターンもあるが一貫しない。

**(9) 証明付き構造体**

`H256 = { val : Array U8 // val.size = 32 }` のような refinement type は実行時に proof 部分を erase するが、型情報の追跡や ctor のコストは残る。Rust の `[u8; 32]` は純粋な 32 バイトの inline storage で、Lean の `H256` は heap object。

#### レイヤー 3: 本プロジェクト特有の事情

**(10) `hash_tree_root_*` が stub**

これは**逆に「stub だから速い」**。ZERO を返すだけなので SHA-256 + Merkleization のコストがゼロ。実 client (Rust の `blst` や `sha2` 利用) と比べると Lean は見かけ上速く出るが、実測はずれる。issue #5 で real 実装すると Lean 側も ~10–100 µs/call 増える。

**(11) BLS / 署名検証なし**

Rust 側で事前 verify するモデル (β、§6.1 参照) を想定しているので、Lean 側の処理には crypto が入っていない。これも見かけを速くしている (実際の fair 比較ではない)。

#### 寄与度のまとめ

| 寄与源 | 大きさ | 回避策 |
|---|---|---|
| Aeneas `Vec → List` → O(N²) (= C1) | **圧倒的** (N=2K で 134×、N=1M 外挿で 10⁵×) | PR #3 方式の Array fast path (本タスク Option X) |
| heap alloc + refcount (Lean 一般) | ~5–10× vs Rust | 回避不能、言語選択の代償 |
| SIMD / LTO なし | ~2–10× vs Rust | 回避不能 (Lean コンパイラの能力次第) |
| generic dispatch | 関数による、~1.2–2× | `@[inline]` 明示で一部緩和 |
| BitVec/BigInt 経由の算術 | 数値ヘビーな箇所で ~2–5× | Std.U64 → native UInt64 に unwrap できるなら |

**一番の教訓**: Lean 言語本体の overhead (heap / refcount / no-SIMD) は **5–10× ぐらいで、現実的に飲める範囲**。本タスクで N=1M が数日かかるのは Lean のせいではなく**Aeneas が Rust の mutable vector を immutable list に翻訳した choice** が支配的で、Array に詰め替えれば桁違いに改善する。

---

## Next action (本メモ承認後)

完了済:
- ✓ `docs/ffi-feasibility.md` 作成 (frontmatter + 全 11 セクション)
- ✓ [issue #4](https://github.com/NyxFoundation/consensus-lean4/issues/4) 発行 (Option III: SSZ バイト列 FFI)
- ✓ [issue #5](https://github.com/NyxFoundation/consensus-lean4/issues/5) 発行 (`hash_tree_root_*` real 実装)
- ✓ Q3, Q4, Q5, Q7 を A3, A4, A5, A7 として解消 (§8 参照)
- ✓ §11「付録: ファイル形式と変換の流れ」追加

残り (承認後):
1. 本メモ §11 を `docs/ffi-feasibility.md` に同期 (plan mode 中は plan ファイル以外を編集できないため保留中)
2. 「実装計画」を別メモに書いて再承認を取得 (feature branch 名、ファイル追加順、Smoke → ベンチの具体手順)
3. 実装計画承認後に feature branch を切り、lakefile / ConsensusLean4/ / rust-ffi/ の編集を開始
4. lean-toolchain 変更が必要になった場合は**単独で**再確認 (包括承認下でも別扱い)
