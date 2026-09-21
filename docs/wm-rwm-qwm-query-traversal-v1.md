# WM / RWM / QWM Query Traversal Optimization V1

## 目的

Wavelet系queryに残っている反復dispatch・重複rank・可変長DFS stackを整理し、
既存のpacked primitiveへ寄せる。

本PRで扱う対象は3系統。

1. WaveletMatrix: SBV fixed-depth dispatch completeness
2. ReversedWaveletMatrix: SBV fixed-depth dispatch completeness
3. QuadWaveletMatrix: QuadVector pair/all-rankと4-way enumeration

## WaveletMatrix / ReversedWaveletMatrix

### Fixed-depth rank

WM/RWMの各levelは同一row countなので、同じquery/traversal内では
SuccinctBitVectorのrank dictionary depthが一定である。

従来の未最適化path:

```text
level / DFS node
 -> rank1Unchecked(...)
    -> case sbv.level
    -> rank1UncheckedDepthN(...)
```

変更後:

```text
query / traversal start
 -> levels[0].levelを1回dispatch
 -> rank1UncheckedDepthNを固定
 -> hot loop / DFS / recursion
```

nbvs PR #18で主要WM queryに導入済みだったpatternを、残りのWM/RWM APIへ
展開する。

### WaveletMatrix対象

- `rank(value, left, right)`
- `rankPair(value, left, right)`
- `countLessThan(left, right, value)`
- `quantile(left, right, k)`
- `collectValueCountsItems`
- `collectValueCountFinalIntervalsItems`
- `collectDistinctValuesItems`
- `terminalPositionUnchecked`
- `accessWithTerminalPositionUnchecked`
- `terminalInterval`
- `initWaveletSelectCursor`
- `matchesAtUnchecked`
- `valueInRangeAtUnchecked`
- `matchingRunsItems` のterminal range projection
- `bitRunsItems`

`rangeFreq` / `predecessor` / `successor` は上記core APIを経由する。

### ReversedWaveletMatrix対象

- `access`
- `rank(value, pos)`
- `rank(value, left, right)`
- `occPosition`
- `select`
- `rankLessThan`
- `collectValueCountsItems`
- `collectDistinctValuesItems`
- `matchesAtUnchecked`

RWM `rankLessThan` はLSB-first subtree recursionを行うため、
static depth genericをquery入口で1回選択する。

### Enumeration stack

WM/RWMのvalue enumerationは `seq[TraversalNode]` から
固定66要素stackへ変更する。

bitWidth <= 64なのでbinary DFSの最大stack requirementを固定化できる。

```text
legacy:
  seq stack
  generic rank dispatch per node

current:
  array[66, TraversalNode]
  fixed-depth rank per traversal
```

公開iteratorのyield順序は維持する。

`matchingRunsItems` のReverseRunNode `seq` stackはterminal-to-root interval
lifting用のwork queueであり、このrank-depth問題とは別なので維持する。

## QuadVector / QuadVectorView

QWMはSuccinctBitVectorを使わないためfixed-depth化の対象ではない。
代わりに、2点range queryと4-way branchingで重複していたQuadVector rankを融合する。

追加primitive:

```nim
rankAllUnchecked(pos): array[4, int64]
rankPairUnchecked(symbol, left, right)
rankAllPairUnchecked(left, right)
```

Heap `QuadVector` と mmap `QuadVectorView` の両方に同じcontractを持たせる。

### rankAllUnchecked

4 symbolのprefix rankを別々に4回求めず、

```text
rank metadata
 + block prefix
 + packed tail 4-symbol count
```

を1回処理して4値を返す。

### rankAllPairUnchecked

left/rightが同じ512-symbol block内なら、

```text
rankAll(left)
 + arbitrary [left,right) 4-symbol count
```

でright rankを復元する。

別blockなら `rankAllUnchecked(left/right)` を使用する。

任意境界用の4-symbol counterは、word境界外の短いprefix/suffixだけscalar処理し、
中央のword-aligned領域をbackend固有の4値集計へ渡す。

## QuadWaveletMatrix

### Pair-rank connection

以下を `QuadVector.rankPairUnchecked` へ接続する。

- `accessRankUnchecked`
- `rank(value, pos)`
- `rank(value, left, right)`
- `rankPair(value, left, right)`
- `select` forward traversal

### 4-symbol all-rank connection

以下を `rankAllPairUnchecked` へ接続する。

- `quantile`
- `countLessThan`
- value enumeration

従来の `quantile` は1levelで4 symbol × left/rightの最大8回rankを行っていた。
変更後は1回のall-pair primitiveから4 child frequencyを得る。

### QWM value enumeration

追加API:

- `collectValueCountsItems`
- `collectValueCountFinalIntervalsItems`
- `collectValueCounts`
- `collectValueCountFinalIntervals`
- `valueCountsItems`
- `valueCounts`
- `collectDistinctValuesItems`
- `collectDistinctValues`
- `distinctValuesItems`
- `distinctValues`

各nodeで `rankAllPairUnchecked(left,right)` を1回呼び、4 childを生成する。

QWMは最大32 levelでbranch factor 4なので、DFS stack capacityは

```text
1 + 3 * 32 = 97
```

以下になる。実装では100要素を確保する。

MSB-first 4-way traversalでsymbol 0..3の順に処理するため、
`valueCountsItems` / `distinctValuesItems` は追加sortなしで数値昇順となる。

## bitWidth = 0

level arrayを参照する前にzero-widthを処理する。

- WM value/distinct enumeration
- WM terminal APIs
- WM select cursor / position predicate
- QWM value/distinct/final-interval enumeration
- QWM rank/select/quantile既存semantics

## 変更しないもの

- SuccinctBitVector layout
- QuadVector payload layout
- rank metadata layout
- select metadata
- WM/RWM/QWM persistence representation
- Heap/View backing layout
- public既存APIのsemantics
- SIMD backend contract

QWMでは新しいenumeration APIとQuadVector rank primitiveを追加するが、
既存APIの意味・storage layoutは変更しない。

## Correctness

### WM/RWM

`tests/twavelet_fixed_depth_completeness.nim`

SBV depth境界:

| rows | expected depth |
| ---: | ---: |
| 257 | 0 |
| 4,097 | 1 |
| 65,536 | 2 |
| 65,537 | 3 |

確認対象:

- WM/RWM access/rank/range-rank/select
- WM rankPair/countLessThan/quantile
- RWM rankLessThan/occPosition
- WM/RWM enumeration
- WM terminal/select cursor
- WM/RWM position predicate
- matching runs

### QuadVector / QWM

既存:

- `tests/tquad_vector_hot_path.nim`
- `tests/tquad_wavelet_matrix.nim`

追加確認:

- `rankAllUnchecked` == 4個の `rankUnchecked`
- `rankAllPairUnchecked` == left/right individual rank
- 31/32, 511/512, 4095/4096等の境界
- QWM range rank / rankPair / select
- QWM quantile / countLessThan
- QWM value counts / distinct values
- QWM final interval frequency
- zero-width QWM
- QuadWaveletMatrixView build/reopen
- Heap/View enumeration一致

## A/B benchmark

### Existing WM fixed-depth

```text
benchmarks/wm_fixed_depth_ab.nim
```

### WM/RWM enumeration

```text
benchmarks/wm_value_enumeration_depth_ab.nim
```

- WM full counts
- WM full final intervals
- WM range final intervals
- RWM full counts
- RWM range counts
- Scalar / SIMD

### WM/RWM core query

```text
benchmarks/wm_rwm_fixed_depth_query_ab.nim
```

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

### QWM pair/all-rank

```text
benchmarks/qwm_pair_enumeration_ab.nim
```

同一QWM内に旧query実装をbenchmark-only baselineとして保持し、

- range rank
- rankPair
- select
- quantile
- countLessThan
- full value counts
- range value counts

をcurrent pair/all-rank pathと比較する。

cases:

- 65,536 rows / cardinality 256
- 65,536 rows / cardinality 65,536
- 1,048,576 rows / cardinality 256
- 1,048,576 rows / cardinality 65,536
- Scalar / SIMD

`speedup = legacy_ns / current_ns` とする。

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

nimble benchQwmPairEnumerationAb
nimble benchQwmPairEnumerationAbSimd

nimble benchWmQwm
nimble benchWmQwmSimd

git diff --check
```

## 性能ゲート

- WM/RWM fixed-depth A/Bで非回帰
- WM/RWM enumerationで非回帰
- QWM pair/all-rank A/Bで主要query非回帰
- QWM quantile/countLessThan/enumerationで明確な改善を確認
- Scalar / SIMD双方で評価
- existing WM/QWM end-to-end比較に異常な回帰がない
- storage / persistence bytes不変
- compile time / binary sizeに異常な増加がない

GitHub Actionsは使用しない。
