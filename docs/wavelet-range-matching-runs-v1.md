# Wavelet Matrix Range Matching Runs v1 / Range-Native v2

## 目的

Wavelet Matrixに、**値の範囲を指定して、条件に一致する元入力の連続index区間を返すAPI**
を追加します。

入力:

- `low, high`: 値のinclusive range `[low, high]`
- `left, right`: 省略可能な元入力indexの半開区間 `[left, right)`

出力:

- `MatchingRun(left, right)`
- 各runは元入力上の半開index区間 `[left, right)`
- run内の全要素が `low <= value <= high` を満たす
- 前後へ同条件の要素を追加できない極大区間
- 複数runは元入力のindex昇順

ここでphysical positionとはWavelet Matrix内部の並べ替え後位置ではなく、
**元の入力配列におけるindex**を意味します。

既存APIには、単一positionに対するrange判定
`valueInRangeAt` / `valueInRangeAtUnchecked` と、単一valueのrun列挙
`matchingRunsItems` / `matchingRuns` があります。
本APIは「複数valueを含むrange条件について、その一致位置を連続index区間で返す」用途を提供します。

## 公開API

```nim
matchingRangeRunsItems(wm, low, high, left, right)
matchingRangeRunsItems(wm, low, high)

matchingRangeRuns(wm, low, high, left, right)
matchingRangeRuns(wm, low, high)

collectMatchingRangeRuns(wm, low, high, left, right)
collectMatchingRangeRuns(wm, low, high)
```

`WaveletMatrix` と `WaveletMatrixView` の双方で利用できます。

| API | 引数 | 戻り値 |
| --- | --- | --- |
| `matchingRangeRunsItems(wm, low, high, left, right)` | inclusive値範囲 `[low, high]` と元入力index範囲 `[left, right)` | `MatchingRun` をiteratorで順次返す |
| `matchingRangeRunsItems(wm, low, high)` | inclusive値範囲 `[low, high]` | 入力全体の `MatchingRun` をiteratorで順次返す |
| `matchingRangeRuns(...)` | 上記と同じ | `seq[MatchingRun]` |
| `collectMatchingRangeRuns(...)` | 上記と同じ | `matchingRangeRuns` と同じ `seq[MatchingRun]` |

`MatchingRun(left, right)` は元入力上の極大な半開index区間です。
その区間内の全valueが `low <= value <= high` を満たします。

## semantics

value rangeはinclusiveです。

```text
low <= value <= high
```

physical range指定版は半開区間です。

```text
[left, right)
```

境界条件:

- `low > high`: 0件
- `left == right`: 0件
- `low` がWavelet Matrixのvalue domainより大きい: 0件
- queryがvalue domain全体を覆う: `[left, right)` を1 runとして返す
- `low == high`: 既存の単一value `matchingRunsItems` と同じ結果
- `bitWidth == 0`: value 0だけを持つdomainとして扱う
- invalid physical bounds: `IndexDefect`

## 実装方針

### v1

PR #22で導入したv1はquery shapeに応じて経路を分けます。

```text
range covers complete value domain
  -> physical input rangeをそのまま返す

low == high
  -> matchingRunsItems(value)へ委譲

general numeric range
  -> physical orderをposition scan
  -> valueInRangeAtUnchecked(position, low, high)
  -> matching positionを極大runへまとめる
```

general rangeはvalue全体の復元を避けられますが、
対象physical rangeの全positionを最低1回訪問します。

### Range-Native v2

PR #23 Stage Aではgeneral rangeをMSB-first prefix subtree traversalへ変更します。
公開APIとresult semanticsはv1のままです。

internal node:

```nim
RangeRunNode = tuple[
  level: int,
  physicalLeft: int64,
  physicalRight: int64,
  mappedLeft: int64,
  mappedRight: int64,
  prefix: uint64]
```

各nodeは次のinvariantを持ちます。

- `[physicalLeft, physicalRight)` は元入力上の連続区間
- `[mappedLeft, mappedRight)` は同じrow集合をcurrent Wavelet levelへstable projectionした区間
- physical lengthとmapped lengthは一致
- node内の全rowは同じ既知value prefixを共有
- DFSはphysical left-to-right orderを維持

現在prefixが表すvalue intervalとquery `[low, high]` の関係でnodeを分類します。

```text
disjoint
  -> node全体を破棄

fully contained
  -> physical intervalをmatching runとして直接採用

partial overlap
  -> current levelのbit分布をrankで確認
```

partial overlapでcurrent bitが全0または全1なら、
そのnode全体を次levelへstable projectionします。

current bitが混在する場合だけ、

```text
physical midpoint
mapped midpoint
```

を同じoffsetで二分し、current levelを継続します。
left childを先に処理するため、結果は元physical index昇順のままです。
隣接するfully-contained intervalはyield前に結合し、既存の極大run contractを維持します。

v2でも永続補助構造、run-boundary index、row materialization、result sortは導入しません。

## ReversedWaveletMatrixを対象にしない判断

本APIは `ReversedWaveletMatrix` には追加しません。

通常のWavelet MatrixはMSB-firstであり、走査途中のprefixが連続したnumeric intervalを表します。
そのため `valueInRangeAtUnchecked` は、prefix intervalとquery rangeの関係から
早期にfalse/trueを確定できます。

一方、ReversedWaveletMatrixはLSB-firstです。途中prefixは、

```text
lower bits = 01
-> 1, 5, 9, 13, ...
```

のような非連続集合を表し、通常WMと同じnumeric interval pruningが成立しません。

RWMに同名range APIを対称的に追加すると、内部実装は全value復元や複数subtree探索など
異なる性能特性を持つものになります。API表面だけを揃えるより、
MSB-firstの構造的利点を持つWavelet Matrixに限定する方がcontractが明確です。

RWMでは既存のequality predicate `matchesAt` / `matchesAtUnchecked` を維持し、
numeric range run enumerationは本PRの非対象とします。

## Correctness

`tests/twavelet_matching_runs.nim` に以下を追加します。

- 基本range run
- partial physical range
- `low == high` と既存equality runの一致
- full value domain
- value domain外
- `low > high`
- empty physical range
- invalid bounds
- `bitWidth == 0`
- `bitWidth == 64` / `uint64.high`
- randomized oracle comparison
- `WaveletMatrixView` とHeap版の一致

oracleは元配列をscalar scanし、同じinclusive range semanticsでrun化します。

## Performance benchmark

PR #23では `benchmarks/wm_matching_range_runs_perf.nim` を
3-way same-binary比較へ拡張します。

```text
access_compare
  wm.access(position)
  -> low <= value <= high
  -> physical run化

position_predicate_scan
  PR #22 public routeをbenchmark内で固定再現
  -> full-domain / equality fast pathは維持
  -> general rangeだけphysical positionごとにvalueInRangeAtUnchecked

matching_range_runs_native
  public matchingRangeRunsItems
  -> Range-Native v2
```

主比較は、

```text
position_predicate_scan
vs
matching_range_runs_native
```

です。

測定軸:

- bit width: 8 / 16 / 32 / 64
- selectivity: 1 / 5 / 10 / 25 / 40 / 90 / 100%
- data shape:
  - random
  - clustered
  - periodic / fragmented
- run count
- matched row count
- p50 / p95 / p99
- access baselineに対するspeedup
- v1 position scanに対するspeedup
- Scalar / SIMD

通常の反復測定は 262,144 rows / 7 repeats を既定値とします。
全84 workload × 3 methodsをScalar/SIMDで比較します。

各workloadで3 methodを1回ずつwarmupし、repeatごとに開始methodを
`mod 3` でrotateして測定順序biasを抑えます。

より重いextended measurementは明示引数で実行します。

```bash
nim c --path:src -d:release --mm:arc -r   benchmarks/wm_matching_range_runs_perf.nim --rows=1048576 --repeats=11
```

extended measurementは長時間実行を許容する追加 evidence とし、通常のPR validationを
完走不能な既定値にはしません。

benchmarkは測定前に3 methodのchecksum、run count、matched row countが一致することを
assertします。

## Range-Native v2の採用判断

Stage Aではpure native traversalだけを実装し、測定前にadaptive thresholdを導入しません。

採用条件:

1. correctnessがv1 scalar oracleと一致
2. 低〜中selectivityでposition scanより有意に高速
3. p95/p99に重大なregressionがない
4. fragmented workloadのregression範囲を説明できる
5. benchmark後に実行コードを変更しない

random / periodicの高fragmentation条件で明確なregressionが確認された場合は、
同じPR #23のStage Bとしてadaptive strategyを検討します。
thresholdはStage Aの測定結果を根拠に決定します。

公開API contractは変更しません。

## 変更しないもの

- Wavelet Matrix storage layout
- SuccinctBitVector layout
- persistence representation
- existing public API semantics
- SIMD backend contract
- ReversedWaveletMatrix public API

## ローカル検証

GitHub Actionsは使用しません。ローカルで次を実行します。

```bash
nim check --path:src src/nbvs.nim
nim doc --project --outdir:/tmp/nbvs-docs src/nbvs.nim

nimble test
nimble testSimd
nimble check

nimble benchWmMatchingRangeRuns
nimble benchWmMatchingRangeRunsSimd

git diff --check
```

benchmark結果を確認後、必要なら内部strategyを調整し、同一条件で再測定します。
