# nbvs

[English](#english) | [日本語](#日本語)

`nbvs` is a Nim library for bit vectors and succinct data structures.

`nbvs` は Nim 製の Bit Vector / Succinct Data Structures ライブラリです。

The default implementation uses the portable scalar backend. The x86/x86_64
AVX2 + BMI2 backend is available with `-d:nbvsSimd`.

デフォルト実装はportable scalar backendを使います。`-d:nbvsSimd` を指定すると、
x86/x86_64向けのAVX2 + BMI2 backendを利用できます。

### API quick usage

For the recently added run and repeated-select APIs, the main choices are:

```nim
import nbvs

let wm = genWaveletMatrix(@[1'u64, 7, 7, 7, 1, 7, 7])

# Stream contiguous physical ranges for one value.
for run in wm.matchingRunsItems(7):
  echo run.left, "..<", run.right

# Or collect the ranges as a sequence.
doAssert wm.matchingRuns(7) == @[
  (left: 1'i64, right: 4'i64),
  (left: 5'i64, right: 7'i64)]

# Enumerate every matching physical position individually.
var cursor = wm.initWaveletSelectCursor(7)
while cursor.remaining > 0:
  echo wm.nextSelect(cursor)
```

For bit vectors, `bitRunsItems` / `bitRuns` enumerate maximal `0` or `1` runs:

```nim
var bits = genSuccinctBitVector(8)
for pos in [1'i64, 2, 3, 5, 6]:
  bits[pos] = true
bits.build()

doAssert bits.bitRuns(true) == @[
  (left: 1'i64, right: 4'i64),
  (left: 5'i64, right: 7'i64)]
```

| Goal | Recommended API |
| --- | --- |
| Count occurrences | `rank` |
| Get one arbitrary occurrence | `select` |
| Enumerate every occurrence position | `WaveletSelectCursor` + `nextSelect` |
| Stream contiguous matching ranges | `matchingRunsItems` |
| Collect contiguous matching ranges | `matchingRuns` |
| Enumerate bit runs | `bitRunsItems` / `bitRuns` |

Advanced hot-path APIs such as `nextSelectUnchecked`, `selectPrepared`,
`BitVectorSelectCursor`, `selectMonotonic`, and `selectMonotonicUnchecked` are
documented in [docs/api_guide.md](docs/api_guide.md).

### APIクイック利用例

run列挙と同一値の repeated select では、主に次のAPIを使います。

```nim
import nbvs

let wm = genWaveletMatrix(@[1'u64, 7, 7, 7, 1, 7, 7])

# 1つの値に一致する連続物理区間をiteratorで取得します。
for run in wm.matchingRunsItems(7):
  echo run.left, "..<", run.right

# sequenceとしてまとめて取得することもできます。
doAssert wm.matchingRuns(7) == @[
  (left: 1'i64, right: 4'i64),
  (left: 5'i64, right: 7'i64)]

# 一致する全物理positionを1件ずつ取得します。
var cursor = wm.initWaveletSelectCursor(7)
while cursor.remaining > 0:
  echo wm.nextSelect(cursor)
```

BitVectorでは `bitRunsItems` / `bitRuns` で `0` または `1` の極大runを列挙できます。

```nim
var bits = genSuccinctBitVector(8)
for pos in [1'i64, 2, 3, 5, 6]:
  bits[pos] = true
bits.build()

doAssert bits.bitRuns(true) == @[
  (left: 1'i64, right: 4'i64),
  (left: 5'i64, right: 7'i64)]
```

| 目的 | 推奨API |
| --- | --- |
| occurrence数を数える | `rank` |
| 任意の1 occurrenceを取得する | `select` |
| 全occurrence positionを列挙する | `WaveletSelectCursor` + `nextSelect` |
| 一致する連続物理区間をiteratorで列挙する | `matchingRunsItems` |
| 一致する連続物理区間をsequenceで取得する | `matchingRuns` |
| BitVectorのrunを列挙する | `bitRunsItems` / `bitRuns` |

`nextSelectUnchecked`、`selectPrepared`、`BitVectorSelectCursor`、
`selectMonotonic`、`selectMonotonicUnchecked` などのadvanced hot-path APIは
[docs/api_guide.md](docs/api_guide.md) にまとめています。

---

## English

### Overview

`nbvs` provides compact bit vectors and succinct data structures for Nim,
including rank/select queries, Elias-Fano encoding, and wavelet matrices.

### Features

- `BitVector`: simple mutable byte-backed bit vector.
- `PackedArray`: fixed-width packed unsigned integer array.
- `SuccinctBitVector`: portable bit vector with `rank` and `select`; an AVX2/BMI2 backend is available with `-d:nbvsSimd`.
- `QuadVector`: 2-bit four-symbol vector with `access`, `rank`, and `select`; payload and auxiliary structures use `PackedArray`.
- `EliasFano`: Elias-Fano encoding for nondecreasing `uint64` sequences.
- `WaveletMatrix`: rank/select, quantile, and range-frequency index for `uint64` sequences.
- `ReversedWaveletMatrix`: LSB-first wavelet matrix with access, rank, and select.
- `FmDictionary`: hybrid FM-index / path-compressed Radix Trie dictionary with exact, prefix, suffix, and substring search.

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

For MSVC, the AVX2/BMI2 backend uses `/arch:AVX2`. BMI2 intrinsics are available through `<immintrin.h>` on supported MSVC targets.

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
import nbvs/quad_vector
import nbvs/elias_fano
import nbvs/wavelet_matrix
import nbvs/wavelet_select_cursor
import nbvs/reversed_wavelet_matrix
import nbvs/fm_dictionary
```

### BitVector

`BitVector` is a simple mutable byte-backed bit vector. Its logical length grows to the highest written index plus one.

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
`PackedArrayView` provides the same value operations over caller-owned contiguous
memory, including memory obtained with `std/memfiles`. The view does not own or
release the memory; the caller must keep it alive and mapped while the view is in
use. The memory must be aligned for `uint64` access.

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

```nim
import std/memfiles
import nbvs/packed_array

var mappedFile = memfiles.open("values.bin", mode = fmReadWrite,
  newFileSize = 1024)
try:
  var view = initPackedArrayView(mappedFile.mem, mappedFile.size,
    len = 100, bitWidth = 13)
  view[10] = 123
  doAssert view.get(10) == 123
finally:
  mappedFile.close()
```

The file size and layout are application concerns. `PackedArrayView` adds no
header, page size, or one-array-per-file convention.

Important API:

| API | Description |
| --- | --- |
| `genPackedArray(len, bitWidth)` | Creates a packed array. |
| `initPackedArrayView(memory, memorySize, len, bitWidth)` | Creates a non-owning view over external memory. |
| `maskForWidth(bitWidth)` | Returns the low-bit mask for a bit width. |
| `maxValue()` | Returns the largest representable value. |
| `get(i)` / `a[i]` | Reads a value. |
| `set(i, value)` / `a[i] = value` | Writes a value. |
| `fill(value)` | Fills all values. |
| `toSeq()` | Converts to an unpacked sequence. |

### SuccinctBitVector

`SuccinctBitVector` provides `access`, `rank`, and `select` over bits. You may mutate bits first, then call `build()` before rank/select queries.

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
The scalar backend does not automatically create a word-pair rank prefix;
rank inside a 512-bit block is computed directly with scalar popcount. The SIMD
backend retains its AVX2-specific auxiliary prefix for large vectors where the
implementation enables it.

```nim
sbv[10] = false
sbv.build()
doAssert sbv.rank1(1000) == 2
```

### QuadVector

`QuadVector` stores symbols `0..3` using 2 bits per symbol in a `PackedArray`.
After mutation, call `build()` before `rank` or `select`.

```nim
import nbvs/quad_vector

var qv = genQuadVector(8)
for i, value in [0'u8, 1, 2, 3, 0, 1, 2, 3]:
  qv[int64(i)] = value
qv.build()

doAssert qv.access(2) == 2
doAssert qv.rank2(8) == 2
doAssert qv.select3(1) == 7
```

`rank(symbol, pos)` counts the selected symbol in `[0, pos)`. `select(symbol, k)`
returns the position of the 0-based `k`-th occurrence. Convenience wrappers
`rank0`..`rank3`, `rank0Incl`..`rank3Incl`, and `select0`..`select3` are also
available.

The payload is a 2-bit `PackedArray`. Rank metadata uses 4096-symbol superblocks
and 512-symbol blocks, and select stores one sampled superblock id per 1024
occurrences of each symbol. The target auxiliary-space budget is 7.8125% of the
2-bit payload: 6.25% for rank plus 1.5625% for select, excluding object/sequence
headers and tail rounding.

The portable backend uses SWAR equality masks and popcount. With `-d:nbvsSimd`,
block-local scans use AVX2 on 128 packed symbols at a time and BMI2 `PDEP` for the
final 2-bit lane selection. The public API and packed auxiliary representation
are identical between backends.

### EliasFano

`EliasFano` encodes a nondecreasing `uint64` sequence. Duplicates are allowed. `universe` is exclusive.

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
| `toSeq()` | Decodes to an unpacked sequence. |

### WaveletMatrix

`WaveletMatrix` indexes an arbitrary `uint64` sequence. Position and value ranges are half-open.

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
doAssert wm.matchesAt(3, 5)
doAssert wm.valueInRangeAt(4, 2, 8)
```

`WaveletMatrix` provides access, rank/select, quantile, range-frequency,
predecessor/successor, distinct-value enumeration, matching-run enumeration,
and repeated-select cursor APIs. Position and value ranges are half-open unless
an API explicitly documents an inclusive endpoint.

### FmDictionary

`FmDictionary` combines an adaptively selected Wavelet or run-length BWT FM
backend with a compact, path-compressed Radix Trie. Exact and prefix searches and
Dictionary ID restoration use the trie; suffix and substring searches use the
FM-index. UTF-8 strings are searched byte by byte; Unicode normalization is the
caller's responsibility. Input strings must be distinct.

See [benchmarks.md](benchmarks.md) and [docs/api_guide.md](docs/api_guide.md) for
advanced query APIs, storage diagnostics, and benchmark details.

### ReversedWaveletMatrix

`ReversedWaveletMatrix` uses the same compact bit-vector representation but
constructs its levels from LSB to MSB. It supports access, rank/select,
`rankLessThan`, matching predicates, and value/count enumeration. Numeric-order
queries such as `quantile` and `rangeFreq` remain APIs of the MSB-first
`WaveletMatrix`.

### External-memory views

`BitVectorView`, `SuccinctBitVectorView`, `EliasFanoView`, `WaveletMatrixView`,
and `ReversedWaveletMatrixView` provide the corresponding public operations
without owning their backing memory. The caller must keep all buffers and level
descriptor arrays alive and at stable addresses while a view is in use.

### Benchmarks

See [benchmarks.md](benchmarks.md) for benchmark commands and measured results.

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

Run the AVX2/BMI2 backend tests on a supported CPU:

```sh
nimble testSimd
```

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
- `QuadVector`: `0..3` を2-bitで保持し、`access` / `rank` / `select` に対応。payloadと補助構造に `PackedArray` を利用します。
- `EliasFano`: 非減少 `uint64` 列の Elias-Fano 符号化。
- `WaveletMatrix`: `uint64` 列の rank/select、quantile、値域頻度 index。
- `ReversedWaveletMatrix`: access、rank、select 対応の LSB-first Wavelet Matrix。
- `FmDictionary`: exact、prefix、suffix、substring検索に対応するFM-index / path-compressed Radix Trie複合Dictionary。

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
import nbvs/quad_vector
import nbvs/elias_fano
import nbvs/wavelet_matrix
import nbvs/wavelet_select_cursor
import nbvs/reversed_wavelet_matrix
import nbvs/fm_dictionary
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

### PackedArray

`PackedArray` は、各値を `0 .. 64` bit の固定長で詰めて保持します。
`PackedArrayView` は呼び出し側所有の連続メモリに対して同じ値操作を提供します。
Viewはメモリを所有・解放しません。

```nim
import nbvs/packed_array

var a = genPackedArray(5, 13)
a[0] = 1234
a[1] = 8191
a.fill(7)

doAssert a[0] == 7
doAssert a.maxValue == 8191
```

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
doAssert sbv.rank1(11) == 2
doAssert sbv.rank0(11) == 9
doAssert sbv.select1(1) == 10
```

更新後は再度 `build()` してください。
scalar backendではword-pair rank prefixを自動生成せず、512-bit block内のrankは
scalar popcountで直接計算します。SIMD backendでは、実装上有効化される大きなvectorに
対して既存のAVX2向け補助prefixを利用します。

### QuadVector

`QuadVector` は `0..3` の4値シンボルを1要素2 bitで `PackedArray` に保持し、
`access` / `rank` / `select` を提供します。値を設定した後、rank/select を使う前に
`build()` を呼びます。

```nim
import nbvs/quad_vector

var qv = genQuadVector(8)
for i, value in [0'u8, 1, 2, 3, 0, 1, 2, 3]:
  qv[int64(i)] = value
qv.build()

doAssert qv.access(2) == 2
doAssert qv.rank2(8) == 2
doAssert qv.select3(1) == 7
```

`rank(symbol, pos)` は `[0, pos)` に含まれる対象シンボル数を返します。
`select(symbol, k)` は0-basedで `k` 番目の出現位置を返します。
`rank0`..`rank3`、`rank0Incl`..`rank3Incl`、`select0`..`select3` のwrapperも利用できます。

payloadは2-bit `PackedArray` です。rank補助構造は4096-symbol superblockと
512-symbol block、selectは各シンボル1024出現ごとのsampled superblock idを使います。
補助構造の目標容量は2-bit payload比で7.8125%です。内訳はrank 6.25%、select 1.5625%で、
object/sequence headerと末尾の丸めは除きます。

portable backendはSWAR equality maskとpopcountを使用します。`-d:nbvsSimd` 指定時は
block内をAVX2で128 packed symbolずつ走査し、最後の2-bit lane選択にBMI2 `PDEP`を使います。
public APIとpacked補助構造はscalar/SIMDで共通です。

### EliasFano

`EliasFano` は非減少 `uint64` 列を符号化します。重複値は許可されます。`universe` は排他的上限です。

```nim
import nbvs/elias_fano

let xs = @[0'u64, 3, 7, 10, 15, 31]
let ef = genEliasFano(xs, 32)

doAssert ef[2] == 7
doAssert ef.select(4) == 15
doAssert ef.lowerBound(8) == 3
```

### WaveletMatrix

`WaveletMatrix` は任意順序の `uint64` 列を index 化します。位置範囲と値範囲は半開区間です。

```nim
import nbvs/wavelet_matrix

let wm = genWaveletMatrix(@[5'u64, 1, 7, 5, 2, 9, 1])
doAssert wm[2] == 7
doAssert wm.rank(5, 7) == 2
doAssert wm.select(1, 1) == 6
doAssert wm.quantile(1, 6, 2) == 5
```

`WaveletMatrix` は access、rank/select、quantile、range frequency、
predecessor/successor、distinct value列挙、matching run列挙、repeated-select cursorを
提供します。高度なAPIは [docs/api_guide.md](docs/api_guide.md) を参照してください。

### FmDictionary

`FmDictionary` はWavelet BWTまたはrun-length BWTを選択するFM backendとcompactな
path-compressed Radix Trieを組み合わせた文字列Dictionaryです。exact、prefix、suffix、
substring検索に対応します。詳細とbenchmarkは [benchmarks.md](benchmarks.md) を参照してください。

### ReversedWaveletMatrix

`ReversedWaveletMatrix` は `WaveletMatrix` と同じ compact bit vector 表現を使い、
LSB から MSB の順で level を構築します。access、rank/select、`rankLessThan`、
matching predicate、value/count列挙に対応します。

### 外部メモリView

`BitVectorView`、`SuccinctBitVectorView`、`EliasFanoView`、`WaveletMatrixView`、
`ReversedWaveletMatrixView` は、backing memoryを所有せずに対応する公開操作を提供します。
Viewの使用中は呼び出し側がbacking memoryを有効に保つ必要があります。

### ベンチマーク

測定コマンドと結果は [benchmarks.md](benchmarks.md) を参照してください。

### ドキュメント生成

```sh
nimble docs
```

生成先は `docs/api/` です。

### テスト

全テストは次で実行します。

```sh
nimble test
```

AVX2/BMI2対応CPUでは次も実行できます。

```sh
nimble testSimd
```

### ライセンス

`nbvs` は MIT License で提供されます。詳細は [LICENSE](LICENSE) を参照してください。
