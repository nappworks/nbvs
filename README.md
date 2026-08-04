# nbvs

[English](#english) | [日本語](#日本語)

`nbvs` is a Nim library for bit vectors and succinct data structures.

`nbvs` は Nim 製の Bit Vector / Succinct Data Structures ライブラリです。

The default implementation uses the portable scalar backend. The x86/x86_64
AVX2 + BMI2 backend is available with `-d:nbvsSimd`.

デフォルト実装はportable scalar backendを使います。`-d:nbvsSimd` を指定すると、
x86/x86_64向けのAVX2 + BMI2 backendを利用できます。

---

## English

### Overview

`nbvs` provides compact bit vectors and succinct data structures for Nim,
including rank/select queries, Elias-Fano encoding, and wavelet matrices.

### Features

- `BitVector`: simple mutable byte-backed bit vector.
- `PackedArray`: fixed-width packed unsigned integer array.
- `SuccinctBitVector`: portable bit vector with `rank` and `select`; an AVX2/BMI2 backend is available with `-d:nbvsSimd`.
- `EliasFano`: Elias-Fano encoding for nondecreasing `uint64` sequences.
- `WaveletMatrix`: rank/select, quantile, and range-frequency index for `uint64` sequences.
- `ReversedWaveletMatrix`: LSB-first wavelet matrix with access, rank, and select.

### Requirements

- Nim `>= 2.2.10`
- An x86 or x86_64 CPU with AVX2 and BMI2 support when using `-d:nbvsSimd`
- GCC/Clang or MSVC

The portable scalar backend is used by default:

```sh
nimble test
```

Enable the AVX2/BMI2 backend explicitly on a supported CPU:

```sh
nim c -d:nbvsSimd -r tests/all.nim
nimble testSimd
```

For GCC/Clang, the AVX2/BMI2 backend passes:

```text
-mavx2
-mbmi2
```

For MSVC, the AVX2/BMI2 backend uses `/arch:AVX2`.  BMI2 intrinsics are available through `<immintrin.h>` on supported MSVC targets.

### Installation

From a local checkout:

```sh
nimble install
```

For development:

```sh
nimble develop
nimble test
```

### Import

Import the whole package:

```nim
import nbvs
```

Or import individual modules:

```nim
import nbvs/bit_vector
import nbvs/packed_array
import nbvs/succinct_bit_vector
import nbvs/elias_fano
import nbvs/wavelet_matrix
import nbvs/reversed_wavelet_matrix
```

### BitVector

`BitVector` is a simple mutable byte-backed bit vector.  Its logical length grows to the highest written index plus one.

```nim
import nbvs/bit_vector

var bv = genBitVector(16)
bv[0] = true
bv[3] = true
bv.clearBit(3)
bv.setBit(15)

doAssert bv[0]
doAssert not bv[3]
doAssert bv[15]
doAssert bv.lenOfBits == 16
doAssert $bv == "1000000000000001"
```

Important API:

| API | Description |
| --- | --- |
| `genBitVector(max)` | Creates a mutable bit vector with `max` addressable bits. |
| `setBit(pos)` | Sets a bit to `1`. |
| `clearBit(pos)` | Clears a bit to `0`. |
| `bv[pos]` | Reads a bit. |
| `bv[pos] = bool` | Writes a bit. |
| `$bv` | Converts the logical prefix to a bit string. |

### PackedArray

`PackedArray` stores unsigned integers using a fixed bit width from `0` to `64`.

```nim
import nbvs/packed_array

var a = genPackedArray(5, 13)
a[0] = 1234
a[1] = 8191
a.fill(7)

doAssert a[0] == 7
doAssert a.maxValue == 8191
doAssert a.toSeq == @[7'u64, 7, 7, 7, 7]
```

Important API:

| API | Description |
| --- | --- |
| `genPackedArray(len, bitWidth)` | Creates a packed array. |
| `maskForWidth(bitWidth)` | Returns the low-bit mask for a bit width. |
| `maxValue()` | Returns the largest representable value. |
| `get(i)` / `a[i]` | Reads a value. |
| `set(i, value)` / `a[i] = value` | Writes a value. |
| `fill(value)` | Fills all values. |
| `toSeq()` | Converts to an unpacked sequence. |

### SuccinctBitVector

`SuccinctBitVector` provides `access`, `rank`, and `select` over bits.  You may mutate bits first, then call `build()` before rank/select queries.

```nim
import nbvs/succinct_bit_vector

var sbv = genSuccinctBitVector(1000)
sbv[0] = true
sbv[10] = true
sbv[999] = true
sbv.build()

doAssert sbv.access(10)
doAssert sbv.rank1(11) == 2      # ones in [0, 11)
doAssert sbv.rank0(11) == 9      # zeros in [0, 11)
doAssert sbv.rank1Incl(10) == 2  # ones in [0, 10]
doAssert sbv.select1(0) == 0
doAssert sbv.select1(1) == 10
doAssert sbv.select1(2) == 999
doAssert sbv.select1(3) == -1
```

Rank/select semantics:

| API | Semantics |
| --- | --- |
| `rank1(pos)` | Number of `1` bits in `[0, pos)`. |
| `rank1Unchecked(pos)` | Unchecked `rank1`; requires a built dictionary and `0 <= pos <= lenOfBits`. |
| `rank0(pos)` | Number of `0` bits in `[0, pos)`. |
| `rank1Incl(pos)` | Number of `1` bits in `[0, pos]`. |
| `rank0Incl(pos)` | Number of `0` bits in `[0, pos]`. |
| `select1(k)` | Position of the 0-based `k`-th `1`, or `-1`. |
| `select0(k)` | Position of the 0-based `k`-th `0`, or `-1`. |
| `select1Nth(nth)` | Position of the 1-based `nth` `1`, or `-1`. |
| `select0Nth(nth)` | Position of the 1-based `nth` `0`, or `-1`. |

After any mutation through `setBit`, `clearBit`, or `[]=`, call `build()` again before `rank` or `select`.
The scalar backend stores an additional word-pair rank prefix, increasing
`SuccinctBitVector` storage by about 6.25% of the raw bit data. The SIMD
backend keeps its existing AVX2-specific prefix layout.

```nim
sbv[10] = false
sbv.build()
doAssert sbv.rank1(1000) == 2
```

### EliasFano

`EliasFano` encodes a nondecreasing `uint64` sequence.  Duplicates are allowed.  `universe` is exclusive.

```nim
import nbvs/elias_fano

let xs = @[0'u64, 3, 7, 10, 15, 31]
let ef = genEliasFano(xs, 32)

doAssert ef[2] == 7
doAssert ef.select(4) == 15
doAssert ef.lowerBound(8) == 3
doAssert ef.upperBound(10) == 4
doAssert ef.predecessor(6) == 3
doAssert ef.countLessEqual(10) == 4
doAssert ef.toSeq == xs
```

Important API:

| API | Description |
| --- | --- |
| `genEliasFano(xs, universe)` | Creates the encoded sequence. |
| `ef[i]` / `access(i)` / `select(i)` | Returns the value at index `i`. |
| `lowerBound(v)` | First index with value `>= v`, or `n`. |
| `upperBound(v)` | First index with value `> v`, or `n`. |
| `lastLessEqual(v)` | Last index with value `<= v`, or `-1`. |
| `predecessor(v)` | Largest value `<= v`, or `ValueError`. |
| `countLessThan(v)` | Number of values `< v`. |
| `countLessEqual(v)` | Number of values `<= v`. |
| `items` | Iterates over values. |
| `toSeq()` | Decodes to `seq[uint64]`. |

### WaveletMatrix

`WaveletMatrix` indexes an arbitrary `uint64` sequence. Position and value
ranges are half-open.

```nim
import nbvs/wavelet_matrix

let wm = genWaveletMatrix(@[5'u64, 1, 7, 5, 2, 9, 1])
doAssert wm[2] == 7
doAssert wm.rank(5, 7) == 2
doAssert wm.rankIncl(5, 3) == 2
doAssert wm.rankLessThan(5, 7) == 3
doAssert wm.occPosition(5, 4) == 5
doAssert wm.select(1, 1) == 6
doAssert wm.selectNth(1, 2) == 6
doAssert wm.quantile(1, 6, 2) == 5
doAssert wm.rangeFreq(0, 7, 2, 8) == 4
```

| API | Description |
| --- | --- |
| `genWaveletMatrix(xs)` | Builds an immutable index over `xs`. |
| `wm[i]` / `access(i)` | Returns the original value at index `i`. |
| `rank(value, pos)` | Counts `value` in `[0, pos)`. |
| `rank(value, left, right)` | Counts `value` in `[left, right)`. |
| `rankIncl(value, pos)` | Counts `value` in `[0, pos]`. |
| `rankLessThan(value, pos)` | Counts values `< value` in `[0, pos)` in `O(bitWidth)`. |
| `occPosition(value, pos)` | Returns all values `< value` in the complete sequence plus occurrences of `value` in `[0, pos)`; equivalent to `C[value] + Occ(value, pos)` in an FM-index. |
| `select(value, k)` | Position of the 0-based `k`-th occurrence, or `-1`. |
| `selectNth(value, nth)` | Position of the 1-based `nth` occurrence, or `-1`. |
| `quantile(left, right, k)` | 0-based `k`-th smallest value in the position range. |
| `countLessThan(left, right, value)` | Counts values `< value`. |
| `rangeFreq(left, right, lower, upper)` | Counts values in `[lower, upper)`. |
| `predecessor(left, right, upper)` | Greatest value `< upper`, or `ValueError`. |
| `successor(left, right, lower)` | Smallest value `>= lower`, or `ValueError`. |
| `items` / `toSeq()` | Decodes values in original order. |
| `collectValueCounts(left, right)` | Collects distinct `(value, frequency)` pairs in traversal order without sorting. |
| `valueCounts(left, right)` | Distinct `(value, frequency)` pairs, sorted by value. |
| `collectDistinctValues(left, right)` | Collects distinct values directly from occupied nodes in traversal order without computing frequencies. |
| `distinctValues(left, right)` | Distinct values sorted in ascending order. |
| `collectValueCountsItems` / `valueCountsItems` | Iterators for traversal-order or ascending `(value, frequency)` pairs. |
| `collectDistinctValuesItems` / `distinctValuesItems` | Iterators for traversal-order or ascending distinct values. |

The four enumeration APIs also have whole-sequence overloads without
`left, right`. All ranges are half-open. The `collect` variants do not guarantee
an order, while the variants without `collect` guarantee ascending value order.

```nim
let values = genWaveletMatrix(@[1'u64, 3, 4, 1])
doAssert values.distinctValues == @[1'u64, 3, 4]

for item in values.valueCountsItems:
  echo item.value, ": ", item.frequency
```

### ReversedWaveletMatrix

`ReversedWaveletMatrix` uses the same compact bit-vector representation but
constructs its levels from LSB to MSB.

```nim
import nbvs/reversed_wavelet_matrix

let rwm = genReversedWaveletMatrix(@[5'u64, 1, 7, 5, 2, 1])
doAssert rwm[2] == 7
doAssert rwm.rank(1, 6) == 2
doAssert rwm.rankIncl(5, 3) == 2
doAssert rwm.rankLessThan(5, 6) == 3
doAssert rwm.occPosition(5, 4) == 5
doAssert rwm.select(5, 1) == 3
doAssert rwm.selectNth(5, 2) == 3
doAssert rwm.valueCounts == @[
  (value: 1'u64, frequency: 2'i64),
  (value: 2'u64, frequency: 1'i64),
  (value: 5'u64, frequency: 2'i64),
  (value: 7'u64, frequency: 1'i64)]
```

It provides the same value/count enumeration functions and iterators shown for
`WaveletMatrix`, including `collectDistinctValues`, `distinctValues`, and their
`Items` variants. The `collect` APIs avoid sorting and do not guarantee result
order. The other APIs sort the LSB-first traversal results by value.
`occPosition(value, pos)` returns all values smaller than `value` in the
complete sequence plus occurrences of `value` in `[0, pos)`. This is
`C[value] + Occ(value, pos)` in FM-index terminology.
Numeric-order queries such as `quantile` and `rangeFreq` remain APIs of the
MSB-first `WaveletMatrix`.

For RWM, `rankLessThan(value, pos)` traverses occupied LSB-first subtrees and
prunes subtrees whose value bounds are already decided. Unlike the WM version,
its cost depends on the value distribution rather than being `O(bitWidth)`.

### Documentation generation

Generate Nim API documentation:

```sh
nimble docs
```

The generated HTML is written to `docs/api/`.

### Tests

Run the full test suite:

```sh
nimble test
```

The tests cover public API behavior, error paths, boundary values, packed-word crossing, rank/select semantics, Elias-Fano queries, the default portable backend, and key AVX2/BMI2 helper paths when `testSimd` is used.

### License

`nbvs` is available under the MIT License. See [LICENSE](LICENSE).

---

## 日本語

### 概要

`nbvs` は、rank/select query、Elias-Fano 符号化、Wavelet Matrix などの
compact bit vector と succinct data structure を Nim 向けに提供します。

### 機能

- `BitVector`: 基本的な可変 byte-backed bit vector。
- `PackedArray`: 固定ビット幅の packed unsigned integer array。
- `SuccinctBitVector`: `rank` / `select` 対応のportable bit vector。`-d:nbvsSimd` でAVX2/BMI2 backendを利用できます。
- `EliasFano`: 非減少 `uint64` 列の Elias-Fano 符号化。
- `WaveletMatrix`: `uint64` 列の rank/select、quantile、値域頻度 index。
- `ReversedWaveletMatrix`: access、rank、select 対応の LSB-first Wavelet Matrix。

### 必要環境

- Nim `>= 2.2.10`
- `-d:nbvsSimd` を使用する場合は、AVX2とBMI2に対応したx86またはx86_64 CPU
- GCC/Clang または MSVC

デフォルトではportable scalar backendを使います。

```sh
nimble test
```

対応CPUでAVX2/BMI2 backendを明示的に有効化する場合は、次を実行します。

```sh
nim c -d:nbvsSimd -r tests/all.nim
nimble testSimd
```

GCC/Clang では、AVX2/BMI2 backend が次のフラグを渡します。

```text
-mavx2
-mbmi2
```

MSVC では AVX2/BMI2 backend が `/arch:AVX2` を使います。

### インストール

ローカル checkout から使う場合です。

```sh
nimble install
```

開発中は次を使います。

```sh
nimble develop
nimble test
```

### import

全体を import する場合です。

```nim
import nbvs
```

個別 module を import する場合です。

```nim
import nbvs/bit_vector
import nbvs/packed_array
import nbvs/succinct_bit_vector
import nbvs/elias_fano
import nbvs/wavelet_matrix
import nbvs/reversed_wavelet_matrix
```

### BitVector

`BitVector` は単純な可変 bit vector です。論理長 `lenOfBits` は、書き込んだ最大 index + 1 まで伸びます。

```nim
import nbvs/bit_vector

var bv = genBitVector(16)
bv[0] = true
bv[3] = true
bv.clearBit(3)
bv.setBit(15)

doAssert bv[0]
doAssert not bv[3]
doAssert bv[15]
doAssert bv.lenOfBits == 16
doAssert $bv == "1000000000000001"
```

主な API です。

| API | 説明 |
| --- | --- |
| `genBitVector(max)` | `max` bit まで扱える bit vector を作成します。 |
| `setBit(pos)` | bit を `1` にします。 |
| `clearBit(pos)` | bit を `0` にします。 |
| `bv[pos]` | bit を読みます。 |
| `bv[pos] = bool` | bit を書きます。 |
| `$bv` | 論理長までの bit string に変換します。 |

### PackedArray

`PackedArray` は、各値を `0 .. 64` bit の固定長で詰めて保持します。

```nim
import nbvs/packed_array

var a = genPackedArray(5, 13)
a[0] = 1234
a[1] = 8191
a.fill(7)

doAssert a[0] == 7
doAssert a.maxValue == 8191
doAssert a.toSeq == @[7'u64, 7, 7, 7, 7]
```

主な API です。

| API | 説明 |
| --- | --- |
| `genPackedArray(len, bitWidth)` | packed array を作成します。 |
| `maskForWidth(bitWidth)` | 指定 bit 幅の low-bit mask を返します。 |
| `maxValue()` | 表現可能な最大値を返します。 |
| `get(i)` / `a[i]` | 値を読みます。 |
| `set(i, value)` / `a[i] = value` | 値を書きます。 |
| `fill(value)` | 全要素を指定値で埋めます。 |
| `toSeq()` | unpacked な sequence に変換します。 |

### SuccinctBitVector

`SuccinctBitVector` は `access` / `rank` / `select` に対応した bit vector です。bit を更新した後、`rank` / `select` を使う前に `build()` を呼びます。

```nim
import nbvs/succinct_bit_vector

var sbv = genSuccinctBitVector(1000)
sbv[0] = true
sbv[10] = true
sbv[999] = true
sbv.build()

doAssert sbv.access(10)
doAssert sbv.rank1(11) == 2      # [0, 11) の 1 の個数
doAssert sbv.rank0(11) == 9      # [0, 11) の 0 の個数
doAssert sbv.rank1Incl(10) == 2  # [0, 10] の 1 の個数
doAssert sbv.select1(0) == 0
doAssert sbv.select1(1) == 10
doAssert sbv.select1(2) == 999
doAssert sbv.select1(3) == -1
```

`rank` / `select` の意味です。

| API | 意味 |
| --- | --- |
| `rank1(pos)` | `[0, pos)` に含まれる `1` の個数。 |
| `rank1Unchecked(pos)` | 検査なしの `rank1`。`build` 済みかつ `0 <= pos <= lenOfBits` が必要。 |
| `rank0(pos)` | `[0, pos)` に含まれる `0` の個数。 |
| `rank1Incl(pos)` | `[0, pos]` に含まれる `1` の個数。 |
| `rank0Incl(pos)` | `[0, pos]` に含まれる `0` の個数。 |
| `select1(k)` | 0-based で `k` 番目の `1` の位置。存在しなければ `-1`。 |
| `select0(k)` | 0-based で `k` 番目の `0` の位置。存在しなければ `-1`。 |
| `select1Nth(nth)` | 1-based で `nth` 番目の `1` の位置。存在しなければ `-1`。 |
| `select0Nth(nth)` | 1-based で `nth` 番目の `0` の位置。存在しなければ `-1`。 |

更新後は再度 `build()` してください。
scalar backendはword-pair rank prefixを追加で保持するため、
`SuccinctBitVector`の格納量が生bit data比で約6.25%増加します。
SIMD backendは既存のAVX2専用prefix構成を維持します。

```nim
sbv[10] = false
sbv.build()
doAssert sbv.rank1(1000) == 2
```

### EliasFano

`EliasFano` は非減少 `uint64` 列を符号化します。重複値は許可されます。`universe` は排他的上限です。

```nim
import nbvs/elias_fano

let xs = @[0'u64, 3, 7, 10, 15, 31]
let ef = genEliasFano(xs, 32)

doAssert ef[2] == 7
doAssert ef.select(4) == 15
doAssert ef.lowerBound(8) == 3
doAssert ef.upperBound(10) == 4
doAssert ef.predecessor(6) == 3
doAssert ef.countLessEqual(10) == 4
doAssert ef.toSeq == xs
```

主な API です。

| API | 説明 |
| --- | --- |
| `genEliasFano(xs, universe)` | Elias-Fano を生成します。 |
| `ef[i]` / `access(i)` / `select(i)` | index `i` の値を返します。 |
| `lowerBound(v)` | `v` 以上の最初の index。なければ `n`。 |
| `upperBound(v)` | `v` より大きい最初の index。なければ `n`。 |
| `lastLessEqual(v)` | `v` 以下の最後の index。なければ `-1`。 |
| `predecessor(v)` | `v` 以下の最大値。なければ `ValueError`。 |
| `countLessThan(v)` | `v` 未満の値の個数。 |
| `countLessEqual(v)` | `v` 以下の値の個数。 |
| `items` | 値を順に iterate します。 |
| `toSeq()` | `seq[uint64]` に decode します。 |

### WaveletMatrix

`WaveletMatrix` は任意順序の `uint64` 列を index 化します。位置範囲と
値範囲は半開区間です。

```nim
import nbvs/wavelet_matrix

let wm = genWaveletMatrix(@[5'u64, 1, 7, 5, 2, 9, 1])
doAssert wm[2] == 7
doAssert wm.rank(5, 7) == 2
doAssert wm.rankIncl(5, 3) == 2
doAssert wm.rankLessThan(5, 7) == 3
doAssert wm.occPosition(5, 4) == 5
doAssert wm.select(1, 1) == 6
doAssert wm.selectNth(1, 2) == 6
doAssert wm.quantile(1, 6, 2) == 5
doAssert wm.rangeFreq(0, 7, 2, 8) == 4
```

| API | 説明 |
| --- | --- |
| `genWaveletMatrix(xs)` | `xs` の不変 index を構築します。 |
| `wm[i]` / `access(i)` | 元の列の index `i` の値を返します。 |
| `rank(value, pos)` | `[0, pos)` にある `value` の個数。 |
| `rank(value, left, right)` | `[left, right)` にある `value` の個数。 |
| `rankIncl(value, pos)` | `[0, pos]` にある `value` の個数。 |
| `rankLessThan(value, pos)` | `[0, pos)` にある `value` 未満の個数。WMでは `O(bitWidth)`。 |
| `occPosition(value, pos)` | 列全体の `value` 未満の個数と `[0, pos)` にある `value` の個数の和。FM-indexの `C[value] + Occ(value, pos)` に相当します。 |
| `select(value, k)` | 0-based で `k` 番目の出現位置。なければ `-1`。 |
| `selectNth(value, nth)` | 1-based で `nth` 番目の出現位置。なければ `-1`。 |
| `quantile(left, right, k)` | 位置範囲内で `k` 番目に小さい値。 |
| `countLessThan(left, right, value)` | 位置範囲内の `value` 未満の個数。 |
| `rangeFreq(left, right, lower, upper)` | 値が `[lower, upper)` に入る個数。 |
| `predecessor(left, right, upper)` | `upper` 未満の最大値。なければ `ValueError`。 |
| `successor(left, right, lower)` | `lower` 以上の最小値。なければ `ValueError`。 |
| `items` / `toSeq()` | 元の順序で値を decode します。 |
| `collectValueCounts(left, right)` | sortせず走査順で `(value, frequency)` を収集します。 |
| `valueCounts(left, right)` | 値で昇順の `(value, frequency)` 一覧。 |
| `collectDistinctValues(left, right)` | 頻度を計算せず、存在するnodeから異なる値を走査順で直接収集します。 |
| `distinctValues(left, right)` | 異なる値を昇順で返します。 |
| `collectValueCountsItems` / `valueCountsItems` | 走査順または昇順の `(value, frequency)` を逐次返すiterator。 |
| `collectDistinctValuesItems` / `distinctValuesItems` | 走査順または昇順の異なる値を逐次返すiterator。 |

4種類の列挙APIには、`left, right` を省略して列全体を対象にするoverloadも
あります。すべての範囲は半開区間です。`collect` 系は順序を保証せず、
非 `collect` 系は値の昇順を保証します。

```nim
let values = genWaveletMatrix(@[1'u64, 3, 4, 1])
doAssert values.distinctValues == @[1'u64, 3, 4]

for item in values.valueCountsItems:
  echo item.value, ": ", item.frequency
```

### ReversedWaveletMatrix

`ReversedWaveletMatrix` は `WaveletMatrix` と同じ compact bit vector 表現を
使い、LSB から MSB の順で level を構築します。

```nim
import nbvs/reversed_wavelet_matrix

let rwm = genReversedWaveletMatrix(@[5'u64, 1, 7, 5, 2, 1])
doAssert rwm[2] == 7
doAssert rwm.rank(1, 6) == 2
doAssert rwm.rankIncl(5, 3) == 2
doAssert rwm.rankLessThan(5, 6) == 3
doAssert rwm.occPosition(5, 4) == 5
doAssert rwm.select(5, 1) == 3
doAssert rwm.selectNth(5, 2) == 3
doAssert rwm.valueCounts == @[
  (value: 1'u64, frequency: 2'i64),
  (value: 2'u64, frequency: 1'i64),
  (value: 5'u64, frequency: 2'i64),
  (value: 7'u64, frequency: 1'i64)]
```

`WaveletMatrix` と同じ値・頻度列挙関数とiteratorを提供し、
`collectDistinctValues`、`distinctValues`、各 `Items` 版も利用できます。
`collect` 系APIはsortせず結果順を保証しません。非 `collect` 系APIは
LSB-firstの探索結果を値でsortします。
`occPosition(value, pos)` は列全体の `value` 未満の個数と、`[0, pos)` にある
`value` の出現数の和を返します。FM-indexの `C[value] + Occ(value, pos)` に相当します。
数値順に依存する `quantile` と `rangeFreq` は MSB-first の
`WaveletMatrix` で利用できます。

RWMの `rankLessThan(value, pos)` は、LSB-firstの出現subtreeを走査し、
値の上下限から結果が確定したsubtreeを枝刈りします。WM版の
`O(bitWidth)` とは異なり、計算量は値の分布に依存します。

### ドキュメント生成

Nim の API documentation は次で生成します。

```sh
nimble docs
```

生成先は `docs/api/` です。

### テスト

全テストは次で実行します。

```sh
nimble test
```

公開API、エラー系、境界値、word境界をまたぐpacked storage、rank/select semantics、
Elias-Fano query、デフォルトのportable backend、`testSimd` 利用時の主要な
AVX2/BMI2 helper pathをテスト対象にしています。

### ライセンス

`nbvs` は MIT License で提供されます。詳細は [LICENSE](LICENSE) を参照してください。
