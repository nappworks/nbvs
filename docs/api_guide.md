# nbvs API Guide / API 利用ガイド

[日本語](#日本語) | [English](#english)

このドキュメントは、`nbvs` の主要な公開APIのうち、特に run 列挙と repeated select に関する使い方をまとめたものです。
基本例は `import nbvs` で利用できます。

This guide covers the main public APIs for run enumeration and repeated select.
The examples use the umbrella import:

```nim
import nbvs
```

---

## 日本語

### 1. Wavelet Matrix の一致値を物理 run として取得する

`matchingRunsItems` / `matchingRuns` は、一致する position を1件ずつ返すのではなく、元配列上で連続する極大な半開区間 `[left, right)` を返します。

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

結果を逐次処理できる場合は `matchingRunsItems`、全runを保持したい場合は `matchingRuns` が適しています。
内部では fragmented な一致に sequential cursor、長い連続区間に terminal-to-root interval lifting を使うハイブリッド方式を自動選択します。選択は内部実装であり、返却結果と順序は同じです。永続的なrun-boundary indexは追加しません。

`WaveletMatrixView` でも同じAPIを利用できます。

### 2. SuccinctBitVector の 0 / 1 run を取得する

`bitRunsItems` / `bitRuns` は、`1` または `0` が連続する極大区間を返します。

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

### 3. WaveletSelectCursor で同じ値の occurrence を順次取得する

一致する物理positionを1件ずつすべて取得したい場合は `WaveletSelectCursor` を使います。
同じvalueに対する固定のterminal intervalを1回だけ準備し、各 occurrence の reverse select で再利用します。

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
| `initWaveletSelectCursor(value)` | terminal value interval と各levelのcursor stateを準備します。 |
| `nextSelect(cursor)` | 次の物理positionを返し、終了後は `-1` を返します。 |
| `remaining(cursor)` | 未取得occurrence数を返します。 |
| `selectPrepared(cursor, occurrence)` | 準備済みvalue intervalを使って任意occurrenceを取得します。 |

```nim
let prepared = wm.initWaveletSelectCursor(5)
doAssert wm.selectPrepared(prepared, 1) == 3
```

### 4. advanced / unchecked cursor API

`nextSelectUnchecked` は exhaustion check を省略するhot-path APIです。
`cursor.nextOccurrence < cursor.count` を呼び出し側が保証できる場合だけ使用してください。

```nim
var cursor = wm.initWaveletSelectCursor(5)
while cursor.remaining > 0:
  let pos = wm.nextSelectUnchecked(cursor)
  discard pos
```

通常は `nextSelect` を優先します。

### 5. BitVectorSelectCursor と monotonic select

`BitVectorSelectCursor` は、selectする occurrence number が単調増加する処理向けの低レベルcursorです。`WaveletSelectCursor` の各levelでも使われます。

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

`selectMonotonic` は前回positionからbounded forward scanを行い、見つからなければ通常のselect treeへfallbackします。occurrenceが単調増加でない場合もregular selectへfallbackし、cursorを再配置します。

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

`matchingRunsItems` と `WaveletSelectCursor` は用途が異なります。前者はrun区間を返し、後者は一致positionを1件ずつ返します。

---

## English

### 1. Get matching Wavelet Matrix values as physical runs

`matchingRunsItems` / `matchingRuns` return maximal contiguous physical ranges instead of returning every matching position individually. Ranges are half-open `[left, right)` intervals in original sequence order.

```nim
let wm = genWaveletMatrix(@[1'u64, 7, 7, 7, 1, 7, 7])

doAssert wm.matchingRuns(7) == @[
  (left: 1'i64, right: 4'i64),
  (left: 5'i64, right: 7'i64)]

for run in wm.matchingRunsItems(7):
  echo run.left, "..<", run.right
```

Range-restricted queries are also supported.

```nim
doAssert wm.matchingRuns(7, 2, 6) == @[
  (left: 2'i64, right: 4'i64),
  (left: 5'i64, right: 6'i64)]
```

| API | Use |
| --- | --- |
| `matchingRunsItems(value)` | Streams maximal matching runs without allocating the result sequence. |
| `matchingRunsItems(value, left, right)` | Restricts the iterator to `[left, right)`. |
| `matchingRuns(value)` | Returns all maximal matching runs as `seq[MatchingRun]`. |
| `matchingRuns(value, left, right)` | Sequence form restricted to `[left, right)`. |
| `collectMatchingRuns(...)` | Compatibility alias of `matchingRuns(...)`. |

Use `matchingRunsItems` when results can be consumed as a stream and `matchingRuns` when the complete run list is required.
Internally, a hybrid strategy selects sequential cursor processing for fragmented matches or terminal-to-root interval lifting for long contiguous groups. The choice is internal; both paths return the same results in the same order. No persistent run-boundary index is stored.

The same APIs are available on `WaveletMatrixView`.

### 2. Get 0 / 1 runs from SuccinctBitVector

`bitRunsItems` / `bitRuns` enumerate maximal runs of either `1` or `0` bits.

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

Range-restricted enumeration is also supported.

```nim
doAssert bits.bitRuns(true, 2, 6) == @[
  (left: 2'i64, right: 4'i64),
  (left: 5'i64, right: 6'i64)]
```

Use `bitRunsItems` to stream results and `bitRuns` when a sequence is required.

### 3. Enumerate same-value occurrences with WaveletSelectCursor

Use `WaveletSelectCursor` when every matching physical position is required individually. It prepares the fixed terminal value interval once and reuses it for reverse select on each occurrence.

```nim
let wm = genWaveletMatrix(@[5'u64, 1, 7, 5, 2, 5, 1])

var cursor = wm.initWaveletSelectCursor(5)
var positions: seq[int64]
while cursor.remaining > 0:
  positions.add wm.nextSelect(cursor)

doAssert positions == @[0'i64, 3, 5]
```

| API | Use |
| --- | --- |
| `initWaveletSelectCursor(value)` | Prepares the terminal value interval and per-level cursor state. |
| `nextSelect(cursor)` | Returns the next physical position, or `-1` after exhaustion. |
| `remaining(cursor)` | Returns the number of unconsumed occurrences. |
| `selectPrepared(cursor, occurrence)` | Gets an arbitrary occurrence using the prepared value interval. |

```nim
let prepared = wm.initWaveletSelectCursor(5)
doAssert wm.selectPrepared(prepared, 1) == 3
```

### 4. Advanced / unchecked cursor APIs

`nextSelectUnchecked` omits the exhaustion check. Use it only when the caller already guarantees `cursor.nextOccurrence < cursor.count`.

```nim
var cursor = wm.initWaveletSelectCursor(5)
while cursor.remaining > 0:
  let pos = wm.nextSelectUnchecked(cursor)
  discard pos
```

Prefer `nextSelect` for normal code.

### 5. BitVectorSelectCursor and monotonic select

`BitVectorSelectCursor` is a lower-level cursor for monotonically increasing select occurrence numbers. It is also used internally by `WaveletSelectCursor`.

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

`selectMonotonic` reuses the previous physical position and performs a bounded forward scan before falling back to the normal select tree. Non-increasing occurrence numbers also fall back to regular select and reposition the cursor.

`selectMonotonicUnchecked` is the unchecked hot-path variant for a caller-proven valid occurrence.

### 6. Choosing an API

| Goal | Recommended API |
| --- | --- |
| Count occurrences | `rank` |
| Get one arbitrary occurrence position | `select` |
| Enumerate every occurrence position for one value | `WaveletSelectCursor` + `nextSelect` |
| Enumerate contiguous physical ranges for one value | `matchingRunsItems` |
| Collect contiguous physical ranges as a sequence | `matchingRuns` |
| Enumerate `0` / `1` runs in a bit vector | `bitRunsItems` |
| Low-level monotonic bit select | `BitVectorSelectCursor` + `selectMonotonic` |

`matchingRunsItems` and `WaveletSelectCursor` solve different problems: the former returns physical run intervals, while the latter returns individual matching positions.
