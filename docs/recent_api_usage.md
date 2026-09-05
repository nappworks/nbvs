# nbvs recent API usage guide (#12–#17)

This page summarizes the public APIs added or materially changed since PR #12.
All examples work with the umbrella import unless noted otherwise:

```nim
import nbvs
```

The Japanese section follows the English section.

---

## English

### 1. Physical matching runs in a Wavelet Matrix

Use `matchingRunsItems` or `matchingRuns` when you need contiguous physical
position ranges for one value, rather than every matching position separately.
Returned ranges are maximal half-open intervals `[left, right)` in original
sequence order.

```nim
let wm = genWaveletMatrix(@[1'u64, 7, 7, 7, 1, 7, 7])

doAssert wm.matchingRuns(7) == @[
  (left: 1'i64, right: 4'i64),
  (left: 5'i64, right: 7'i64)]

for run in wm.matchingRunsItems(7):
  echo run.left, "..<", run.right
```

A position range may be supplied explicitly:

```nim
doAssert wm.matchingRuns(7, 2, 6) == @[
  (left: 2'i64, right: 4'i64),
  (left: 5'i64, right: 6'i64)]
```

APIs:

| API | Use |
| --- | --- |
| `matchingRunsItems(value)` | Streams maximal matching runs without allocating the result sequence. |
| `matchingRunsItems(value, left, right)` | Iterator restricted to `[left, right)`. |
| `matchingRuns(value)` | Returns all maximal matching runs as `seq[MatchingRun]`. |
| `matchingRuns(value, left, right)` | Sequence form restricted to `[left, right)`. |
| `collectMatchingRuns(...)` | Compatibility alias of `matchingRuns(...)`. |

`matchingRunsItems` is the preferred API when results can be consumed as a
stream. `matchingRuns` is convenient when the complete run list is needed.

The implementation is hybrid. A bounded probe selects either sequential
selection for heavily fragmented matches or terminal-to-root interval lifting
for long contiguous groups. This selection is internal: the public result and
ordering are identical for both paths. No persistent run-boundary index is
stored.

The same APIs are available on `WaveletMatrixView`.

### 2. Matching bit runs in SuccinctBitVector

`bitRunsItems` and `bitRuns` enumerate maximal runs of either `1` or `0` bits.

```nim
var bits = genSuccinctBitVector(8)
for pos in [1'i64, 2, 3, 5, 6]:
  bits[pos] = true
bits.build()

doAssert bits.bitRuns(true) == @[
  (left: 1'i64, right: 4'i64),
  (left: 5'i64, right: 7'i64)]

doAssert bits.bitRuns(false) == @[
  (left: 0'i64, right: 1'i64),
  (left: 4'i64, right: 5'i64),
  (left: 7'i64, right: 8'i64)]
```

Range-restricted enumeration is also supported:

```nim
doAssert bits.bitRuns(true, 2, 6) == @[
  (left: 2'i64, right: 4'i64),
  (left: 5'i64, right: 6'i64)]
```

Use `bitRunsItems` to stream results and `bitRuns` when a sequence is required.

### 3. Repeated same-value select with WaveletSelectCursor

When every matching physical position is needed, use `WaveletSelectCursor` to
avoid recomputing the fixed value interval for each occurrence.

```nim
let wm = genWaveletMatrix(@[5'u64, 1, 7, 5, 2, 5, 1])

var cursor = wm.initWaveletSelectCursor(5)
var positions: seq[int64]
while cursor.remaining > 0:
  positions.add wm.nextSelect(cursor)

doAssert positions == @[0'i64, 3, 5]
```

Main cursor APIs:

| API | Use |
| --- | --- |
| `initWaveletSelectCursor(value)` | Computes the terminal value interval once and initializes per-level cursor state. |
| `nextSelect(cursor)` | Returns the next physical occurrence, or `-1` when exhausted. |
| `remaining(cursor)` | Number of occurrences not yet consumed. |

For random access to an occurrence after the cursor has prepared the value
interval, use `selectPrepared`:

```nim
let prepared = wm.initWaveletSelectCursor(5)
doAssert wm.selectPrepared(prepared, 1) == 3
```

### 4. Advanced / unchecked Wavelet cursor path

`nextSelectUnchecked` removes the exhaustion check and is intended for hot paths
where the caller already guarantees `cursor.nextOccurrence < cursor.count`.

```nim
var cursor = wm.initWaveletSelectCursor(5)
while cursor.remaining > 0:
  let pos = wm.nextSelectUnchecked(cursor)
  discard pos
```

Prefer `nextSelect` unless the surrounding loop already proves the precondition.

### 5. BitVectorSelectCursor and monotonic select

`BitVectorSelectCursor` is the lower-level cursor used by
`WaveletSelectCursor`. It is useful when select occurrence numbers are queried in
monotonically increasing order.

```nim
var bits = genSuccinctBitVector(128)
for pos in [3'i64, 5, 9, 65, 80]:
  bits[pos] = true
bits.build()

var cursor = initBitVectorSelectCursor(true)
doAssert bits.selectMonotonic(cursor, 0) == 3
doAssert bits.selectMonotonic(cursor, 1) == 5
doAssert bits.selectMonotonic(cursor, 3) == 65
```

`selectMonotonic` reuses the previous physical position and performs a bounded
forward scan before falling back to the normal select tree. Non-increasing
occurrence numbers are also handled by falling back to regular select and
repositioning the cursor.

`selectMonotonicUnchecked` is the unchecked hot-path variant. Use it only when
the occurrence is known to be valid.

### 6. Which API should I use?

| Goal | Recommended API |
| --- | --- |
| Count occurrences | `rank` |
| Get one arbitrary occurrence position | `select` |
| Enumerate every occurrence of one value | `WaveletSelectCursor` + `nextSelect` |
| Enumerate contiguous physical ranges for one value | `matchingRunsItems` |
| Collect contiguous physical ranges as a sequence | `matchingRuns` |
| Enumerate `0`/`1` runs in a bit vector | `bitRunsItems` |
| Low-level monotonic bit select | `BitVectorSelectCursor` + `selectMonotonic` |

`matchingRunsItems` and `WaveletSelectCursor` solve different problems:
`matchingRunsItems` returns ranges, while the cursor returns individual
positions.

---

## 日本語

### 1. Wavelet Matrix 上の一致値の物理 run

`matchingRunsItems` / `matchingRuns` は、一致する全 position を1件ずつ取得するのではなく、
元配列上で連続している極大な物理位置区間を返します。返却区間は半開区間
`[left, right)` です。

```nim
let wm = genWaveletMatrix(@[1'u64, 7, 7, 7, 1, 7, 7])

doAssert wm.matchingRuns(7) == @[
  (left: 1'i64, right: 4'i64),
  (left: 5'i64, right: 7'i64)]

for run in wm.matchingRunsItems(7):
  echo run.left, "..<", run.right
```

範囲指定もできます。

```nim
doAssert wm.matchingRuns(7, 2, 6) == @[
  (left: 2'i64, right: 4'i64),
  (left: 5'i64, right: 6'i64)]
```

| API | 用途 |
| --- | --- |
| `matchingRunsItems(value)` | 結果sequenceを確保せず、極大runをiteratorで列挙します。 |
| `matchingRunsItems(value, left, right)` | `[left, right)` 内だけを列挙します。 |
| `matchingRuns(value)` | 全runを `seq[MatchingRun]` で返します。 |
| `matchingRuns(value, left, right)` | 範囲指定したsequence版です。 |
| `collectMatchingRuns(...)` | `matchingRuns(...)` の互換aliasです。 |

結果を逐次処理できる場合は `matchingRunsItems`、全runを保持したい場合は
`matchingRuns` が適しています。

内部実装はハイブリッドです。bounded probeにより、細かく分断された一致では
sequential cursor、長い連続区間では terminal-to-root interval lifting を自動選択します。
この選択は内部実装であり、どちらの経路でも公開APIの結果・順序は同一です。
永続的なrun-boundary indexは保持しません。

`WaveletMatrixView` でも同じAPIを利用できます。

### 2. SuccinctBitVector の bit run

`bitRunsItems` / `bitRuns` は、`1` または `0` が連続する極大区間を列挙します。

```nim
var bits = genSuccinctBitVector(8)
for pos in [1'i64, 2, 3, 5, 6]:
  bits[pos] = true
bits.build()

doAssert bits.bitRuns(true) == @[
  (left: 1'i64, right: 4'i64),
  (left: 5'i64, right: 7'i64)]

doAssert bits.bitRuns(false) == @[
  (left: 0'i64, right: 1'i64),
  (left: 4'i64, right: 5'i64),
  (left: 7'i64, right: 8'i64)]
```

範囲指定版もあります。

```nim
doAssert bits.bitRuns(true, 2, 6) == @[
  (left: 2'i64, right: 4'i64),
  (left: 5'i64, right: 6'i64)]
```

結果を逐次処理する場合は `bitRunsItems`、sequenceが必要な場合は `bitRuns` を使います。

### 3. WaveletSelectCursor による同一値の逐次 select

一致する物理positionをすべて1件ずつ取得したい場合は `WaveletSelectCursor` を使います。
同じvalueについて固定のterminal intervalを毎回計算し直さずに済みます。

```nim
let wm = genWaveletMatrix(@[5'u64, 1, 7, 5, 2, 5, 1])

var cursor = wm.initWaveletSelectCursor(5)
var positions: seq[int64]
while cursor.remaining > 0:
  positions.add wm.nextSelect(cursor)

doAssert positions == @[0'i64, 3, 5]
```

| API | 用途 |
| --- | --- |
| `initWaveletSelectCursor(value)` | terminal value interval と各levelのcursor stateを初期化します。 |
| `nextSelect(cursor)` | 次の物理positionを返し、終了後は `-1` を返します。 |
| `remaining(cursor)` | 未取得occurrence数を返します。 |

準備済みintervalを使って任意のoccurrenceを取得する場合は `selectPrepared` を使えます。

```nim
let prepared = wm.initWaveletSelectCursor(5)
doAssert wm.selectPrepared(prepared, 1) == 3
```

### 4. advanced / unchecked Wavelet cursor API

`nextSelectUnchecked` は exhaustion check を省略するhot-path APIです。
`cursor.nextOccurrence < cursor.count` を呼び出し側が保証できる場合だけ使用します。

```nim
var cursor = wm.initWaveletSelectCursor(5)
while cursor.remaining > 0:
  let pos = wm.nextSelectUnchecked(cursor)
  discard pos
```

通常は `nextSelect` を優先してください。

### 5. BitVectorSelectCursor と monotonic select

`BitVectorSelectCursor` は `WaveletSelectCursor` の各level内部でも使われる低レベルcursorです。
selectする occurrence number が単調増加する処理で利用できます。

```nim
var bits = genSuccinctBitVector(128)
for pos in [3'i64, 5, 9, 65, 80]:
  bits[pos] = true
bits.build()

var cursor = initBitVectorSelectCursor(true)
doAssert bits.selectMonotonic(cursor, 0) == 3
doAssert bits.selectMonotonic(cursor, 1) == 5
doAssert bits.selectMonotonic(cursor, 3) == 65
```

`selectMonotonic` は前回positionからbounded forward scanを行い、範囲内に見つからなければ
通常のselect treeへfallbackします。occurrenceが単調増加でない場合もregular selectへfallbackし、
cursorを再配置します。

`selectMonotonicUnchecked` はvalidなoccurrenceを呼び出し側が保証するhot-path版です。

### 6. APIの使い分け

| 目的 | 推奨API |
| --- | --- |
| occurrence数を数える | `rank` |
| 任意の1 occurrenceのpositionを取得する | `select` |
| 1つの値の全occurrence positionを列挙する | `WaveletSelectCursor` + `nextSelect` |
| 1つの値の連続物理区間を列挙する | `matchingRunsItems` |
| 連続物理区間をsequenceで取得する | `matchingRuns` |
| BitVectorの `0` / `1` runを列挙する | `bitRunsItems` |
| 低レベルの単調増加bit select | `BitVectorSelectCursor` + `selectMonotonic` |

`matchingRunsItems` と `WaveletSelectCursor` は用途が異なります。
前者は物理run区間を返し、後者は一致positionを1件ずつ返します。
