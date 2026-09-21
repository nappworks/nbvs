# WM Value Enumeration Fixed-Depth Traversal V1

## 目的

Wavelet Matrixのvalue enumeration系APIで、各tree nodeごとに
`SuccinctBitVector.rank1Unchecked()` のdepth dispatchを繰り返していた経路を、
traversal開始時の1回dispatchへ変更する。

対象:

- `collectValueCountsItems(left, right)`
- `collectValueCountFinalIntervalsItems(left, right)`

## 背景

nbvs PR #18で通常のWM `access/rank/select` はfixed-depth rank primitiveへ接続済みである。

一方、value enumeration系は現在も次の形を残している。

```text
seq stack
 -> node pop
 -> rank1Unchecked(left)
    -> case sbv.level
 -> rank1Unchecked(right)
    -> case sbv.level
 -> child push
```

WMの各levelは同一長のSBVを持つため、同じtraversal内でdepthは不変である。

## 実装

変更後:

```text
traversal start
 -> wm.levels[0].level を1回dispatch
 -> rank1UncheckedDepthNを固定
 -> bounded array stack
 -> leaf yield
```

bitWidthは0..64であるため、DFS stackは固定66 nodeで処理する。

bitWidth=0ではlevel arrayを参照せず、非空rangeならvalue 0のleafを1件返す。

API、yield順序、terminal interval semanticsは変更しない。

## 正しさ

既存 `tests/twavelet_matrix.nim` に以下を追加する。

- bitWidth 0
- rows 257 / SBV depth 0
- rows 4,097 / depth 1
- rows 65,536 / depth 2
- rows 65,537 / depth 3
- range value counts
- final interval frequency / width一致

既存Heap/View query regressionはそのまま維持する。

## A/B benchmark

`benchmarks/wm_value_enumeration_depth_ab.nim`

同一Wavelet Matrixで次を比較する。

```text
legacy:
  seq stack
  nodeごとにrank1Unchecked generic dispatch

current:
  fixed array stack
  traversal開始時にfixed-depth dispatch
```

cases:

- rows: 65,536 / 1,048,576
- cardinality: 256 / 65,536
- full counts
- full final intervals
- 64 x 4,096-row range final intervals
- Scalar / AVX2+BMI2

`speedup = legacy / current` とする。

## shikiDBとの境界

このPRはDB semanticsを持たない。

shikiDB側の以下はこのPRへ移さない。

- terminal DELETE semantics
- NULL handling
- Segment dictionary decode
- SUM reduction
- GlobalValueId / SegmentValueId

nbvs merge後、shikiDB PR #103側でこのvalue-enumeration primitiveをconsumeし、
shikiDB独自のrank depth dispatchを削除できるかをproduction benchmarkで確認する。

## 検証

```bash
nim check --path:src src/nbvs.nim
nim doc --project --outdir:docs/api src/nbvs.nim
nimble test
nimble testSimd
nimble check

nimble benchWmValueEnumerationDepthAb
nimble benchWmValueEnumerationDepthAbSimd

git diff --check
```

GitHub Actionsは使用しない。
