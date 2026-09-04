## Wavelet Matrixで同じ値を繰り返しselectするためのcursorです。
##
## `WaveletMatrix.select(value, k)`を繰り返すと、出現位置ごとに値区間をrootから
## 再計算します。このmoduleは固定のforward traversalと、出現位置ごとのreverse
## select pathを分離します。
##
## さらに逐次`nextSelect`では各Wavelet levelにBitVector select cursorを保持し、
## 単調増加するselect targetについてprefix treeの再探索を避けます。
## Cursorはquery中だけ存在する小さな非所有型です。

import wavelet_matrix
import succinct_bit_vector
import bit_vector_select_cursor

type
  WaveletSelectCursor* = object
    ## 1つの値について準備済みの出現区間を表します。
    value*: uint64
    intervalStart*: int64
    count*: int64
    nextOccurrence*: int64
    valid*: bool
    targetOnes: array[64, bool]
    levelCursors: array[64, BitVectorSelectCursor]

func valueFits(bitWidth: int, value: uint64): bool {.inline.} =
  bitWidth == 64 or (bitWidth > 0 and (value shr bitWidth) == 0)

func initWaveletSelectCursor*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): WaveletSelectCursor =
  ## `value`の最終Wavelet区間を1回だけ準備します。
  ##
  ## 値がmatrixのdomain外にある場合、またはmatrixが空の場合は`count == 0`と
  ## なり、空のcursorとして反復できます。
  result.value = value
  result.valid = true
  if wm.n == 0 or not valueFits(wm.bitWidth, value):
    return

  var left = 0'i64
  var right = wm.n
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let targetOne = ((value shr shift) and 1'u64) != 0
    result.targetOnes[level] = targetOne
    result.levelCursors[level] = initBitVectorSelectCursor(targetOne)
    if targetOne:
      left = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(left)
      right = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(right)
    else:
      left -= wm.levels[level].rank1Unchecked(left)
      right -= wm.levels[level].rank1Unchecked(right)

  result.intervalStart = left
  result.count = right - left

func selectPrepared*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, cursor: WaveletSelectCursor, occurrence: int64): int64 =
  ## 準備済みの値区間を使用し、0-basedの出現位置を1つ選択します。
  ##
  ## ランダムなoccurrence取得用のstateless pathです。逐次取得では`nextSelect`を
  ## 使用するとlevelごとのselect stateを再利用できます。
  if not cursor.valid or occurrence < 0 or occurrence >= cursor.count:
    return -1

  var pos = cursor.intervalStart + occurrence
  for level in countdown(wm.bitWidth - 1, 0):
    if cursor.targetOnes[level]:
      pos = wm.levels[level].select1(pos - wm.zeroCounts[level])
    else:
      pos = wm.levels[level].select0(pos)
  result = pos

proc nextSelectUnchecked*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, cursor: var WaveletSelectCursor): int64 =
  ## 次の出現位置を境界検査なしで返します。
  ##
  ## `cursor.valid`かつ`cursor.nextOccurrence < cursor.count`のときだけ呼び出して
  ## ください。各levelのselect targetは出現順では単調増加するため、
  ## `BitVectorSelectCursor`の前回位置からforward scanできます。
  var pos = cursor.intervalStart + cursor.nextOccurrence
  for level in countdown(wm.bitWidth - 1, 0):
    if cursor.targetOnes[level]:
      pos = wm.levels[level].selectMonotonicUnchecked(
        cursor.levelCursors[level], pos - wm.zeroCounts[level])
    else:
      pos = wm.levels[level].selectMonotonicUnchecked(
        cursor.levelCursors[level], pos)
  inc cursor.nextOccurrence
  result = pos

proc nextSelect*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, cursor: var WaveletSelectCursor): int64 =
  ## 次の出現位置を返し、cursorを消費し終えた場合は`-1`を返します。
  if not cursor.valid or cursor.nextOccurrence >= cursor.count:
    return -1
  result = wm.nextSelectUnchecked(cursor)

func remaining*(cursor: WaveletSelectCursor): int64 {.inline.} =
  ## `nextSelect`がまだ消費していない出現数を返します。
  max(0'i64, cursor.count - cursor.nextOccurrence)
