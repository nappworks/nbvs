# WM / RWM Fixed-Depth Rank Traversal Completeness V1

## 目的

Wavelet Matrix / Reversed Wavelet Matrixで、query/traversal中に同一の
SuccinctBitVector depthを繰り返しdispatchしている経路を整理する。

原則:

```text
query / traversal start
 -> levels[0].level を1回dispatch
 -> rank1UncheckedDepthNを固定
 -> hot loop / DFS / recursionを実行
```

nbvs PR #18でWMの主要access/rank/selectに導入済みだったfixed-depth patternを、
未適用だったWM/RWM APIへ展開する。

## 対象

### WaveletMatrix core

- `rank(value, left, right)`
- `rankPair(value, left, right)`
- `countLessThan(left, right, value)`
- `quantile(left, right, k)`
- `collectValueCountsItems`
- `collectValueCountFinalIntervalsItems`
- `collectDistinctValuesItems`

`rangeFreq` / `predecessor` / `successor` は上記APIを利用するため間接的に対象になる。

### ReversedWaveletMatrix core

- `access`
- `rank(value, pos)`
- `rank(value, left, right)`
- `occPosition`
- `select`
- `rankLessThan`
- `collectValueCountsItems`
- `collectDistinctValuesItems`

LSB-firstの `rankLessThan` はsubtree recursionを行うため、
static depth genericをquery入口で1回選択する。

### WaveletMatrix auxiliary APIs

- `terminalPositionUnchecked`
- `accessWithTerminalPositionUnchecked`
- `terminalInterval`
- `initWaveletSelectCursor`
- `matchesAtUnchecked`
- `valueInRangeAtUnchecked`
- RWM `matchesAtUnchecked`
- `matchingRunsItems` のterminal range projection
- `bitRunsItems`

## Enumeration stack

WM/RWMのvalue enumerationは従来 `seq[TraversalNode]` を使用していた。

bitWidthは最大64なので、DFS stackを固定66要素へ変更する。

```text
legacy:
  seq stack
  generic rank dispatch per node

current:
  array[66, TraversalNode]
  fixed-depth rank per traversal
```

公開iteratorのyield順序は維持する。

`matchingRunsItems` に残るReverseRunNodeのseq stackは
terminal-to-root interval liftingのwork queueであり、今回のrank-depth問題とは別なので維持する。

## bitWidth = 0

level arrayを参照する前にbitWidth=0を処理する。

対象:

- WM value enumeration
- WM distinct enumeration
- terminal position
- terminal interval
- select cursor init
- position predicate

既存のzero-width semanticsを維持する。

## 変更しないもの

- SuccinctBitVector layout
- rank dictionary layout
- WaveletMatrix / ReversedWaveletMatrix layout
- View persistence representation
- select metadata
- public API名
- query semantics
- iterator ordering contract
- SIMD backend contract

## QWM

QuadWaveletMatrixはSuccinctBitVector depth dispatchを使用しないため、本PRの対象外とする。

QWMは次PRで別途、

- QuadVector `rankPairUnchecked` 活用
- 4-symbol pair/all-rank primitive
- QWM value enumeration API
- quantile/countLessThanの4-way traversal

を測定して扱う。

## Correctness

新規:

```text
tests/twavelet_fixed_depth_completeness.nim
```

rows/depth:

| rows | expected SBV depth |
| ---: | ---: |
| 257 | 0 |
| 4,097 | 1 |
| 65,536 | 2 |
| 65,537 | 3 |

確認:

- WM/RWM access
- WM/RWM rank
- WM/RWM range rank
- WM rankPair
- WM countLessThan
- WM quantile
- RWM rankLessThan
- RWM occPosition
- WM/RWM select
- WM/RWM distinct enumeration
- WM terminal position / interval
- select cursor
- WM/RWM position equality
- WM range position predicate
- matching runs

既存 `tests/all.nim` の全回帰も維持する。

## A/B benchmark

### PR #18 existing WM fixed-depth benchmark

```text
benchmarks/wm_fixed_depth_ab.nim
```

WM access/accessRank/rankのgeneric vs fixed-depthを確認する。

### Value enumeration

```text
benchmarks/wm_value_enumeration_depth_ab.nim
```

- full counts
- full final intervals
- range final intervals
- Scalar / SIMD
- legacy seq/generic vs fixed array/fixed-depth

### WM/RWM core query

```text
benchmarks/wm_rwm_fixed_depth_query_ab.nim
```

同一processで比較:

- WM range rank
- WM rankPair
- WM countLessThan
- WM quantile
- RWM access
- RWM rank
- RWM range rank
- RWM select
- RWM occPosition
- RWM rankLessThan

`speedup = legacy / fixed-depth` とする。

## Validation

```bash
nim check --path:src src/nbvs.nim
nim doc --project --outdir:docs/api src/nbvs.nim

nimble test
nimble testSimd
nimble check

nimble benchWmDepthAb
nimble benchWmDepthAbSimd

nimble benchWmValueEnumerationDepthAb
nimble benchWmValueEnumerationDepthAbSimd

nimble benchWmRwmFixedDepthQueryAb
nimble benchWmRwmFixedDepthQueryAbSimd

git diff --check
```

GitHub Actionsは使用しない。
