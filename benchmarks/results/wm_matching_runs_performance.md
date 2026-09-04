# Wavelet Matching Runs パフォーマンス結果

## 目的

`bitRuns` / `matchingRuns` の iterator API と `seq[tuple]` API の性能を確認します。
特に、指定値が長い連続区間を形成する場合に、`select` で一致 position を1件ずつ列挙して run 化する方法と比較します。

## 実行対象

- `benchmarks/bit_runs_perf.nim`
- `benchmarks/wm_matching_runs_perf.nim`

## 推奨ビルド・実行コマンド

scalar:

```sh
nim c --path:src -d:release --mm:arc benchmarks/bit_runs_perf.nim
./benchmarks/bit_runs_perf

nim c --path:src -d:release --mm:arc benchmarks/wm_matching_runs_perf.nim
./benchmarks/wm_matching_runs_perf
```

SIMD:

```sh
nim c --path:src -d:release -d:nbvsSimd --mm:arc benchmarks/bit_runs_perf.nim
./benchmarks/bit_runs_perf

nim c --path:src -d:release -d:nbvsSimd --mm:arc benchmarks/wm_matching_runs_perf.nim
./benchmarks/wm_matching_runs_perf
```

## 測定条件

デフォルト値:

- rows: 1,000,000
- repeats: 21
- run length: 1, 4, 16, 64, 256, 1024, 4096
- 集計値: p50

環境変数で変更できます。

```sh
NBVS_BIT_RUNS_ROWS=1000000
NBVS_BIT_RUNS_REPEATS=21
NBVS_MATCHING_RUNS_ROWS=1000000
NBVS_MATCHING_RUNS_REPEATS=21
```

## Codex 実行結果

> このセクションは Codex でベンチマークを実行した際に、実測値へ更新します。

### 環境

```text
OS:
CPU:
Nim:
Compiler:
Commit:
Build flags:
```

### bitRuns scalar

```csv
未実行
```

### bitRuns SIMD

```csv
未実行
```

### matchingRuns scalar

```csv
未実行
```

### matchingRuns SIMD

```csv
未実行
```

## 確認観点

- `bitRunsItems` と `bitRuns` の allocation 差
- `matchingRunsItems` と `matchingRuns` の allocation 差
- 通常 `select` で全一致 position を列挙して run 化する場合との差
- `WaveletSelectCursor` で position を列挙して run 化する場合との差
- run length が長くなったときに `matchingRuns` が出現数依存から run 数依存へ近づくか
- scalar / SIMD で rank 実装の差がどの程度反映されるか

## 結果まとめ

Codex 実行後に以下を記録します。

- `bitRunsItems` が scalar scan を上回る run length の境界
- `matchingRunsItems` が通常 `select` を上回る run length の境界
- `matchingRunsItems` が `WaveletSelectCursor` を上回る run length の境界
- iterator と seq API の allocation コスト
- SIMD 有効化による改善率
