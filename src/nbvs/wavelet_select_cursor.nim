## Wavelet Matrixで同じ値を繰り返しselectするためのcursorです。
##
## `WaveletMatrix.select(value, k)`を繰り返すと、出現位置ごとに値区間をrootから
## 再計算します。このmoduleは固定のforward traversalと、出現位置ごとのreverse
## select pathを分離します。
##
## Cursorは小さな非所有型です。初期化に使用したmatrixが有効な間、
## `WaveletMatrix`と`WaveletMatrixView`の双方で利用できます。

import wavelet_matrix
import succinct_bit_vector

type
  WaveletSelectCursor* = object
    ## 1つの値について準備済みの出現区間を表します。
    value*: uint64
    intervalStart*: int64
    count*: int64
    nextOccurrence*: int64
    valid*: bool

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
    if ((value shr shift) and 1'u64) == 0:
      left -= wm.levels[level].rank1Unchecked(left)
      right -= wm.levels[level].rank1Unchecked(right)
    else:
      left = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(left)
      right = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(right)

  result.intervalStart = left
  result.count = right - left

func selectPrepared*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, cursor: WaveletSelectCursor, occurrence: int64): int64 =
  ## 準備済みの値区間を使用し、0-basedの出現位置を1つ選択します。
  ##
  ## `occurrence`が準備済み区間外の場合は`-1`を返します。Cursorは呼び出し対象と
  ## 同じmatrixと値の組み合わせで準備されている必要があります。
  if not cursor.valid or occurrence < 0 or occurrence >= cursor.count:
    return -1

  var pos = cursor.intervalStart + occurrence
  for level in countdown(wm.bitWidth - 1, 0):
    let shift = wm.bitWidth - level - 1
    if ((cursor.value shr shift) and 1'u64) == 0:
      pos = wm.levels[level].select0(pos)
    else:
      pos = wm.levels[level].select1(pos - wm.zeroCounts[level])
  result = pos

proc nextSelect*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, cursor: var WaveletSelectCursor): int64 =
  ## 次の出現位置を返し、cursorを消費し終えた場合は`-1`を返します。
  if not cursor.valid or cursor.nextOccurrence >= cursor.count:
    return -1
  result = wm.selectPrepared(cursor, cursor.nextOccurrence)
  inc cursor.nextOccurrence

func remaining*(cursor: WaveletSelectCursor): int64 {.inline.} =
  ## `nextSelect`がまだ消費していない出現数を返します。
  max(0'i64, cursor.count - cursor.nextOccurrence)
