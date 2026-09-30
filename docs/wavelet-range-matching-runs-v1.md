# Wavelet Matrix Range Matching Runs v1

## 目的

Wavelet Matrix上で、inclusive value range `[low, high]` に一致する元配列上の
physical positionを、極大な連続半開区間 `[left, right)` として列挙する汎用APIを追加します。

既存APIには、

- 単一positionに対するrange判定: `valueInRangeAt` / `valueInRangeAtUnchecked`
- 単一valueに対するphysical run列挙: `matchingRunsItems` / `matchingRuns`

があります。本APIはその中間にある「value range × physical run列挙」を提供します。

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

返却される `MatchingRun` は元配列のphysical orderで昇順です。
隣接する一致positionは必ず1つの極大runへまとめます。

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

v1ではquery shapeに応じて経路を分けます。

```text
range covers complete value domain
  -> physical input rangeをそのまま返す

low == high
  -> matchingRunsItems(value)へ委譲

general numeric range
  -> physical orderを走査
  -> valueInRangeAtUnchecked(position, low, high)
  -> matching positionを極大runへまとめる
```

一般rangeでも `access(position)` で値全体を復元してから比較するのではなく、
MSB-first prefix pruningを使う既存 `valueInRangeAtUnchecked` を利用します。

このv1では永続補助構造、run-boundary index、追加metadataは持ちません。

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

`benchmarks/wm_matching_range_runs_perf.nim` で次を同一dataset上で比較します。

```text
baseline:
  wm.access(position)
  -> low <= value <= high
  -> physical run化

candidate:
  wm.matchingRangeRunsItems(low, high)
```

測定軸:

- bit width: 8 / 16 / 32 / 64
- selectivity: 1 / 10 / 40 / 90 / 100%
- data shape:
  - random
  - clustered
  - periodic / fragmented
- run count
- matched row count
- p50 / p95 / p99
- baselineに対するspeedup
- Scalar / SIMD

通常の反復測定は 262,144 rows / 7 repeats を既定値とします。
全60 workloadをScalar/SIMDで反復可能な時間に収め、日常の回帰確認に使います。

より重いextended measurementは明示引数で実行します。

```bash
nim c --path:src -d:release --mm:arc -r   benchmarks/wm_matching_range_runs_perf.nim --rows=1048576 --repeats=11
```

extended measurementは長時間実行を許容する追加 evidence とし、通常のPR validationを
完走不能な既定値にはしません。

benchmarkは測定前にbaselineとcandidateのchecksum、run count、matched row countが一致することを
assertします。

## 後続最適化候補

v1の測定後、一般rangeのposition-by-position predicateが支配的であれば、
MSB-first value subtreeをrangeでpruneし、一致intervalをphysical orderへprojectionする
range-native traversalを検討します。

その場合も公開API contractは本PRの6 APIを維持し、内部strategyのみを変更します。

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
