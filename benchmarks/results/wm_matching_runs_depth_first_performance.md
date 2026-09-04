# matchingRuns depth-first 最適化 パフォーマンス検証

## 目的

`matchingRunsItems` の各 Wavelet level ごとの candidate sequence 再構築を廃止し、
単一スタックによる depth-first traversal に変更した効果を確認します。

## 変更内容

従来実装:

```text
candidates
  -> levelごとに bitRunsItems
  -> next.add(...)
  -> candidates = move(next)
```

最適化後:

```text
単一 stack
  -> 混在区間は同じ level で二分
  -> 全一致区間は rank で次 level へ写像
  -> terminal まで depth-first で処理
```

中間 candidate sequence の生成・再構築と、`matchingRunsItems` 内からの
`bitRunsItems` iterator 呼び出しを避けます。

## 比較対象

既存の以下のベンチマークを使用します。

```sh
benchmarks/wm_matching_runs_perf.nim
```

比較する commit:

- baseline: PR #12 マージ直後の main
- optimized: 本PRの head

## 推奨実行コマンド

scalar:

```sh
nim c --path:src -d:release --mm:arc benchmarks/wm_matching_runs_perf.nim
./benchmarks/wm_matching_runs_perf
```

SIMD:

```sh
nim c --path:src -d:release -d:nbvsSimd --mm:arc benchmarks/wm_matching_runs_perf.nim
./benchmarks/wm_matching_runs_perf
```

## 確認観点

- `matchingRunsItems` の p50
- `matchingRuns` の p50
- 通常 `select` 比
- `WaveletSelectCursor` 比
- run length が長い場合に約100msで下げ止まっていた挙動が改善するか
- iterator / seq の差
- scalar / SIMD の差

## Codex 実行結果

2026-09-04 に以下の環境で実行しました。

- CPU: Intel Core i5-8365U（4 cores / 8 threads）
- OS: Linux 5.15.146.1-microsoft-standard-WSL2 x86_64
- Nim: 2.2.10
- memory manager: ARC
- rows: 1,000,000
- repeats: 21
- 集計値: p50

baseline scalar:

```csv
run_length,runs,iterator_p50_ns,seq_p50_ns,regular_select_p50_ns,cursor_select_p50_ns
1,250000,310842149,316614029,120683297,100207904
4,62500,258385370,256840095,137379025,108704888
16,15625,209752949,215095416,138397317,101786578
64,3907,205743935,203352918,131352471,106683490
256,977,197657990,188260738,130467025,106702109
1024,245,128554359,131360894,98352819,80253146
4096,62,119708944,122193463,89022471,74981898
```

optimized scalar:

```csv
run_length,runs,iterator_p50_ns,seq_p50_ns,regular_select_p50_ns,cursor_select_p50_ns
1,250000,267551653,268603904,119905905,99675571
4,62500,245881862,249413834,132014186,108071357
16,15625,206750618,203876690,134013084,102958615
64,3907,191688743,190552862,136677033,104145480
256,977,180048016,174435489,128389727,108268360
1024,245,130437849,133269586,101791479,85875114
4096,62,122044648,121479420,93498286,78734178
```

baseline SIMD:

```csv
run_length,runs,iterator_p50_ns,seq_p50_ns,regular_select_p50_ns,cursor_select_p50_ns
1,250000,265532555,269424744,70299535,51571997
4,62500,221304331,226825334,81781779,61111491
16,15625,185695680,194054953,79255134,58464060
64,3907,167289423,172329638,73665500,53732778
256,977,176509050,174740708,73950843,54498785
1024,245,167657072,167199051,68497974,52747919
4096,62,150799780,160481234,68320008,52543467
```

optimized SIMD:

```csv
run_length,runs,iterator_p50_ns,seq_p50_ns,regular_select_p50_ns,cursor_select_p50_ns
1,250000,239652603,230236051,65558274,51384211
4,62500,227600838,217524283,82396608,61371986
16,15625,193363721,182940857,76716221,56244736
64,3907,171243247,161870954,77008305,54460161
256,977,166240829,163402849,73973150,53523236
1024,245,159557315,150359606,71165605,52443806
4096,62,160811050,154974575,70025988,54918314
```

## 考察

- scalar の iterator は run length 1 で 13.9%、256 で 8.9%短縮しました。
  一方、1024 と 4096 ではそれぞれ 1.5%、2.0%遅く、長い run での約100msの
  下げ止まりは解消していません。
- SIMD の iterator は run length 1 で 9.7%、256 と 1024 で約5%短縮しましたが、
  4、16、64、4096 では 2.4%から6.6%遅くなりました。
- seq は iterator と概ね同じ傾向で、sequence へ結果を格納する追加コストは
  相対的に小さい結果でした。
- すべての条件で通常 `select` と `WaveletSelectCursor` より遅く、今回の
  depth-first traversal だけでは性能上の優位性を得られませんでした。
- WSL2 上の単回測定であり、数%程度の差は実行時の揺らぎを含む可能性が
  あります。特に長い run で改善を狙う場合は、stack 操作と同一区間に対する
  rank 呼び出し回数を profile し、別の最適化を検討する必要があります。
