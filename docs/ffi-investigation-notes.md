---
title: FFI Investigation Notes
last_updated: 2026-04-24
tags:
  - ffi
  - aeneas
  - benchmark
  - lean4
---

# FFI Investigation Notes

## 目的

Rust 製クライアントから Lean 4 で形式化されたコンセンサスロジックを FFI
経由で呼び出し、2 つのエントリーポイントについて **実行時間とメモリ消費** を
バリデータ数 N=1,000,000 まで計測したい。

- `state_transition.state_transition` — `ConsensusLean4/Funs.lean:2693`
  (block 適用の起点)
- `fork_choice.compute_lmd_ghost_head` — `ConsensusLean4/Funs.lean:1104`
  (ヘッド選択の起点)

署名 / ネットワーク / DB は Lean 側に一切含まれない (Types.lean / Funs.lean を
全量 grep して確認済み)。純粋な状態遷移とフォーク選択の参照実装のみ。

## 事前決定事項 (ユーザ合意)

| 項目 | 選択 |
|---|---|
| FFI 境界方式 | 共有ライブラリ (.so) 静的リンク |
| スケール階段 | N ∈ {1k, 10k, 100k, 1M} |
| `hash_tree_root_*` の扱い | スタブのまま (block.state_root を `H256::ZERO` で生成) |

## 実施済みの変更 (ブランチ: `feat/rust-ffi-benchmark`)

すべて未コミット。

### Lean 側

1. **`ConsensusLean4/FunsExternal.lean`** — 5 個の axiom を実装に置換。
   - `Ordering.eq` (自明)
   - `Vec.clear` / `Vec.is_empty` (自明)
   - `Result.branch` / `Result.from_residual` (Rust `?` 演算子の desugar)
2. **`ConsensusLean4/Funs.lean:15`** — `noncomputable section` マーカを削除。
3. **`ConsensusLean4/Ffi.lean`** (新規) — ByteArray 入出力の FFI シム。
   `@[export consensus_state_transition_ffi]` と
   `@[export consensus_fork_choice_ffi]` の 2 関数。固定レイアウト LE の
   自前 codec 付き (~400 LOC)。
4. **`ConsensusLean4.lean`** — `import ConsensusLean4.Ffi` 追加。
5. **`lakefile.lean`** — `buildType := .release` 追加、コメント更新のみ。

確認: `lake build` でコンパイル成功。`leanc -c` で `Ffi.c` を単体コンパイルし、
`consensus_state_transition_ffi` / `consensus_fork_choice_ffi` が実際に C シンボル
として出力されていることを `nm` で確認済み。

### Rust 側 (骨組みのみ)

- `rust/Cargo.toml` — workspace
- `rust/ffi/Cargo.toml` — `consensus-ffi` crate (空実装)
- `rust/bench/Cargo.toml` — `consensus-bench` crate (空実装)

`src/*.rs` / `build.rs` はまだ書いていない。

## 詰まった所: `precompileModules := true` で上流 .so 相互依存が壊れる

`lake build` デフォルト設定では `.lake/build/ir/ConsensusLean4/*.c` は
出るが `.c.o.export` は出ず、リンク可能な `.a` / `.so` が得られない。

`lean_lib ... where precompileModules := true` を指定すると上流パッケージ
(aeneas, mathlib, batteries, …) が自動で shared library としてビルドされる。
その過程で以下のリンクエラーが出る:

```
symbol lookup error:
  libaeneas_Aeneas.so: undefined symbol: initialize_aeneas_AeneasMeta_Split
```

`libaeneas_Aeneas.so` が `libaeneas_AeneasMeta.so` 内のシンボルを未解決参照
しており、aeneas 上流の lakefile で `.so` 相互依存が宣言されていない。
Lean ツールチェーン v4.28.0-rc1 固有ではなく Lake の共有ライブラリビルド
そのものの弱点に見える。

## 解決策: NyxFoundation/consensus-lean4#2 の方式

[PR #2](https://github.com/NyxFoundation/consensus-lean4/pull/2) で実証済み。
**同じ Lean ツールチェーン (v4.28.0-rc1)** で FFI が動いた実績がある。

### 要点

1. **`precompileModules := true` は使わない** (我々が嵌まった罠を回避)
2. **`lake build ConsensusLean4:static` を実行** — この専用ターゲットを走らせると
   `libconsensus_x2dlean4_ConsensusLean4.a` と、副産物として **全モジュールの
   `.c.o.export` が生成**される。これが我々の `lake build` だけでは出て
   いなかった理由。
3. **`build.rs` が `.lake/**/*.c.o.export` を再帰検索**し、1000+ 個の `.o`
   ファイルを全部リンカに `-Wl,--start-group ... --end-group` で囲んで渡す
   (C/C++ の循環依存解決イディオム)。
4. **Lean ランタイムは動的リンク**: `libleanshared.so` + `libInit_shared.so`
   を `-rpath` 埋め込みで参照 (elan toolchain の lib ディレクトリ)。
5. **`Cache/` / `LongestPole/` / `Shake/` ディレクトリは除外** — Mathlib の
   独立ツール群で `main` シンボルが重複するため。
6. **初期化順序**:
   ```c
   lean_initialize_runtime_module();
   lean_initialize();
   initialize_consensus_x2dlean4_ConsensusLean4_Ffi(1, NULL);
   lean_io_mark_end_initialization();
   ```

### PR #2 の計測結果 (抜粋・release ビルド)

FFI 境界コスト:
- Lean ランタイム初期化: **~46 ms** (1 回のみ)
- 1 回の FFI 呼び出し (`slot_is_justifiable_after(u64, u64) → u8`):
  **320 ns – 14.7 µs**
- 持続スループット: **~92,000 calls/s** (1M 回平均 10.9 µs/call)

`slot_is_justifiable_after` ループ内呼び出し (線形):

| N | 合計 | per-call |
|---:|---:|---:|
| 1,000 | 7.2 ms | 7.2 µs |
| 10,000 | 84.3 ms | 8.4 µs |
| 100,000 | 1.50 s | 15.0 µs |
| 1,000,000 | 17.8 s | 17.8 µs |

`Vec.push × N` (O(N²) の根拠):

| N | 合計 | N²-norm |
|---:|---:|---:|
| 100 | 114 µs | 11.4 ns |
| 1,000 | 9.2 ms | 9.2 ns |
| 10,000 | 1.02 s | 10.2 ns |
| 20,000 | 4.43 s | 11.1 ns |

`process_attestations` (A 個の attestation × V validators):

| V \ A | 1 | 4 | 16 | 64 |
|---:|---:|---:|---:|---:|
| 100 | 216 µs | 522 µs | 1.71 ms | 6.90 ms |
| 500 | 4.24 ms | 9.68 ms | 56.79 ms | 135.35 ms |
| 1,000 | 18.69 ms | 42.51 ms | 137.15 ms | 780.21 ms |
| 2,000 | 112.43 ms | 222.92 ms | 796.89 ms | **2.67 s** |

### 重要: Aeneas の Vec 翻訳が O(N²) を引き起こす

Aeneas は Rust の `Vec<T>` を以下のように翻訳する (我々と同じ挙動):

```lean
def Vec (α : Type u) := { l : List α // l.length ≤ Usize.max }
```

- `Vec.push` → `List.concat` → **O(N)**
- `Vec.index_usize` → `List.get?` → **O(i)**
- 結果として、Rust の O(N) ループが Lean 抽出版では **O(N²)** に膨張する

証明の健全性には影響しないが、実行速度に致命的に効く。

### N=1M での外挿 (PR #2 の結論)

測定された per-(V²·A) ≈ **12 ns** を用いた線形外挿:

| V | A | 1 ブロックの pipeline |
|---:|---:|---:|
| 1,000 | 16 | 192 ms (実測) |
| 10,000 | 16 | 19.2 s |
| 100,000 | 16 | ~32 分 |
| 1,000,000 | 16 | **~2.2 日** |
| 1,000,000 | 64 | **~9 日** |

**1M での単一ブロック処理は criterion でベンチ取れる水準にない。**
ベンチ対象は 1k / 10k / 100k までが現実的上限。1M は「外挿値を示す」扱いに
落とす必要がある。

## 推奨される次ステップ

ユーザ判断待ち。案:

1. **PR #2 の `build.rs` 方式を我々のブランチに移植**
   - `lake build ConsensusLean4:static` を `build.rs` から呼ぶ
   - `.c.o.export` 収集 + `--start-group/--end-group` リンク
   - 既存の `ConsensusLean4/Ffi.lean` (ByteArray codec 方式) をそのまま使う
     か、PR #2 の単純な `u64 → u8` 方式に合わせて書き直すかは別判断
2. **スケール階段を見直す**: 1k / 10k / 100k までを実測、1M は外挿で補う
3. **メモリ計測**: `memory-stats` + `getrusage` の RSS サンプリングで
   現状プラン通り可能 (方式変更の影響なし)

### 既知の制約 (方式に依らず残る)

- `hash_tree_root_*` がスタブ → ブロックの `state_root = H256::ZERO` 前提で
  生成
- 署名検証なし (`AggregatedAttestation` に署名フィールド自体がない)
- Aeneas Vec の O(N²) — 上流 (Aeneas) 修正か、`FunsExternal.lean` で hot path
  を手実装で置き換えるかしない限り回避不能

## 参考資料

- PR #2 本体: https://github.com/NyxFoundation/consensus-lean4/pull/2
- PR #2 内ベンチレポート: `docs/rust-ffi-benchmarks.md` (PR 内で作成)
- Aeneas Vec 定義:
  `.lake/packages/aeneas/backends/lean/Aeneas/Std/Vec.lean:19`
- Lean FFI C API: `$(lean --print-libdir)/../include/lean/lean.h`
