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

未実行です。Codexで baseline / optimized の scalar・SIMD を同一環境で測定し、
CSVと考察をこのファイルへ追記してください。
