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

### 環境

```text
OS: Ubuntu 26.04 LTS (WSL2, Linux 5.15.146.1-microsoft-standard-WSL2)
CPU: Intel(R) Core(TM) i5-8365U CPU @ 1.60GHz (4 cores / 8 threads)
Nim: 2.2.10
Compiler: GCC 15.2.0
Commit: 9dd57fef6c86fbedfacaafb82165ceb5d50fb233
Build flags: -d:release --mm:arc（scalar）、-d:release -d:nbvsSimd --mm:arc（SIMD）
```

### bitRuns scalar

```csv
rows,run_length,runs,repeats,iterator_p50_ns,seq_p50_ns,scalar_scan_p50_ns,iterator_vs_scalar_speedup,seq_vs_scalar_speedup
1000000,1,500000,21,102762767,104288705,11175479,0.109,0.107
1000000,4,125000,21,61085826,60689316,6996809,0.115,0.115
1000000,16,31250,21,28604971,27911630,5707234,0.200,0.204
1000000,64,7813,21,10470212,10379806,5556124,0.531,0.535
1000000,256,1954,21,3292292,3193987,5196403,1.578,1.627
1000000,1024,489,21,1159668,1173568,5397715,4.655,4.599
1000000,4096,123,21,581733,611036,9169136,15.762,15.006
```

### bitRuns SIMD

```csv
rows,run_length,runs,repeats,iterator_p50_ns,seq_p50_ns,scalar_scan_p50_ns,iterator_vs_scalar_speedup,seq_vs_scalar_speedup
1000000,1,500000,21,92264231,93391794,9161609,0.099,0.098
1000000,4,125000,21,54149132,53595911,5095491,0.094,0.095
1000000,16,31250,21,26128580,24841432,4454968,0.171,0.179
1000000,64,7813,21,10252984,9743966,4359964,0.425,0.447
1000000,256,1954,21,3238121,3024514,3968849,1.226,1.312
1000000,1024,489,21,1019138,962136,3857745,3.785,4.010
1000000,4096,123,21,332812,303511,3962449,11.906,13.055
```

### matchingRuns scalar

```csv
rows,run_length,occurrences,runs,repeats,iterator_p50_ns,seq_p50_ns,regular_select_p50_ns,cursor_select_p50_ns,iterator_vs_regular_speedup,iterator_vs_cursor_speedup,seq_vs_regular_speedup,seq_vs_cursor_speedup
1000000,1,250000,250000,21,192686145,191685989,77415976,65737731,0.402,0.341,0.404,0.343
1000000,4,250000,62500,21,140617075,141899845,77168266,63313101,0.549,0.450,0.544,0.446
1000000,16,250000,15625,21,142549478,149406357,91927519,73589267,0.645,0.516,0.615,0.493
1000000,64,250048,3907,21,145145983,147297703,98291702,77635224,0.677,0.535,0.667,0.527
1000000,256,250112,977,21,113591256,115311652,78990519,65810182,0.695,0.579,0.685,0.571
1000000,1024,250432,245,21,106440696,106130087,78643500,68065316,0.739,0.639,0.741,0.641
1000000,4096,250432,62,21,107083114,104733159,76000039,65849154,0.710,0.615,0.726,0.629
```

### matchingRuns SIMD

```csv
rows,run_length,occurrences,runs,repeats,iterator_p50_ns,seq_p50_ns,regular_select_p50_ns,cursor_select_p50_ns,iterator_vs_regular_speedup,iterator_vs_cursor_speedup,seq_vs_regular_speedup,seq_vs_cursor_speedup
1000000,1,250000,250000,21,160541283,161793150,45409599,37959806,0.283,0.236,0.281,0.235
1000000,4,250000,62500,21,123739753,124267957,50559171,39639606,0.409,0.320,0.407,0.319
1000000,16,250000,15625,21,105266492,104774244,46932891,36183534,0.446,0.344,0.448,0.345
1000000,64,250048,3907,21,100338320,99111108,45724940,36286097,0.456,0.362,0.461,0.366
1000000,256,250112,977,21,103450692,103106279,49280211,38446716,0.476,0.372,0.478,0.373
1000000,1024,250432,245,21,102920372,101378307,48559515,41283213,0.472,0.401,0.479,0.407
1000000,4096,250432,62,21,107413642,116033694,53159092,41536282,0.495,0.387,0.458,0.358
```

## 確認観点

- `bitRunsItems` と `bitRuns` の allocation 差
- `matchingRunsItems` と `matchingRuns` の allocation 差
- 通常 `select` で全一致 position を列挙して run 化する場合との差
- `WaveletSelectCursor` で position を列挙して run 化する場合との差
- run length が長くなったときに `matchingRuns` が出現数依存から run 数依存へ近づくか
- scalar / SIMD で rank 実装の差がどの程度反映されるか

## 結果まとめ

- `bitRunsItems` と `bitRuns` は scalar / SIMD ともに run length 256 から
  scalar scan を上回りました。run length 4096 では iterator が scalar で
  15.762 倍、SIMD で 11.906 倍でした。
- `matchingRunsItems` と `matchingRuns` は、今回の全 run length で通常の
  `select` および `WaveletSelectCursor` を上回りませんでした。最良値は scalar
  の run length 1024 における iterator 対通常 `select` の 0.739 倍です。
- iterator と seq API の実行時間は概ね同程度でした。ベンチマークはallocation
  回数やバイト数を直接計測していないため、allocationコストの定量評価は未実施です。
- SIMD化によって `bitRunsItems` は run length 1〜4096 で約 1.00〜1.75 倍に
  改善しました。一方、比較対象の `select` も高速化されるため、Wavelet Matrix
  の相対speedupはscalarより低下しました。
- Wavelet Matrix側はrun数が 250,000 から 62 へ減少しても約100 msで下げ止まり、
  現実装はrun数だけに比例する挙動にはなっていません。各levelでの区間分割と
  候補sequence構築のコストが残っていると考えられます。
