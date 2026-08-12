## Fixed-width packed unsigned integer array.
##
## `PackedArray` はbacking storageを所有し、`PackedArrayView` は呼び出し側が
## 所有する連続メモリを参照します。どちらも値の操作には同じAPIを使用します。

type
  PackedArray* = object
    ## 固定bit幅の符号なし整数配列を表します。
    len*: int64        ## 要素数。
    bitWidth*: int     ## 1要素のbit数。有効範囲は `0 .. 64` です。
    data*: seq[uint64] ## 所有するpacked storage。

  PackedArrayView* = object
    ## 外部の連続メモリを参照する、所有権を持たないpacked arrayです。
    ##
    ## backing memoryは `uint64` のalignmentを満たす必要があります。Viewより
    ## 長く有効に保ち、Viewの使用中に移動または解放してはなりません。
    len*: int64
    bitWidth*: int
    data*: ptr UncheckedArray[uint64]
    dataWords*: int

func ceilDiv*[T: SomeInteger](x, y: T): T =
  ## 整数値について `ceil(x / y)` を返します。
  ##
  ## `x <= 0` の場合は `0` を返します。`y` は正でなければなりません。
  if x <= 0:
    return 0
  result = (x + y - 1) div y

func maskForWidth*(bitWidth: int): uint64 =
  ## `bitWidth` bit分の下位bit maskを返します。
  ##
  ## `maskForWidth(0) == 0`、`maskForWidth(64) == uint64.high` です。
  if bitWidth < 0 or bitWidth > 64:
    raise newException(ValueError, "bitWidth must be in 0..64")

  if bitWidth == 0:
    return 0'u64
  elif bitWidth == 64:
    return uint64.high
  else:
    return (1'u64 shl bitWidth) - 1'u64

func requiredWords(len: int64, bitWidth: int): int =
  if len == 0 or bitWidth == 0:
    return 0

  # 先に64要素単位へ分解し、len * bitWidthのint64 overflowを避ける。
  let fullBlocks = len div 64
  let tailWords = ceilDiv((len mod 64) * int64(bitWidth), 64'i64)
  if fullBlocks > (int64.high - tailWords) div int64(bitWidth):
    raise newException(ValueError, "packed storage size is too large")
  let words = fullBlocks * int64(bitWidth) + tailWords
  if words > int64(int.high):
    raise newException(ValueError, "packed storage size is too large")
  result = int(words)

func genPackedArray*(len: int64, bitWidth: int): PackedArray =
  ## `len` 要素、1要素 `bitWidth` bitの所有配列を作成します。
  ##
  ## `len < 0` または `bitWidth` が `0 .. 64` の範囲外の場合は
  ## `ValueError` を送出します。
  if len < 0:
    raise newException(ValueError, "len must be non-negative")
  if bitWidth < 0 or bitWidth > 64:
    raise newException(ValueError, "bitWidth must be in 0..64")

  result.len = len
  result.bitWidth = bitWidth
  result.data = newSeq[uint64](requiredWords(len, bitWidth))

func initPackedArrayView*(memory: pointer, memorySize: int, len: int64,
                          bitWidth: int): PackedArrayView =
  ## 外部の連続メモリから、所有権を持たないpacked array viewを作成します。
  ##
  ## `memorySize` は `memory` から利用可能なbyte数です。必要な領域が0 byteの
  ## 場合に限り `memory` は `nil` にできます。必要な領域が不足する場合、
  ## pointerがnilの場合、または `uint64` のalignmentを満たさない場合は
  ## `ValueError` を送出します。backing memoryの有効期間は呼び出し側の責任です。
  if len < 0:
    raise newException(ValueError, "len must be non-negative")
  if bitWidth < 0 or bitWidth > 64:
    raise newException(ValueError, "bitWidth must be in 0..64")
  if memorySize < 0:
    raise newException(ValueError, "memorySize must be non-negative")

  let words = requiredWords(len, bitWidth)
  if words > int.high div sizeof(uint64) or
      memorySize < words * sizeof(uint64):
    raise newException(ValueError, "backing memory is too small")
  if words > 0:
    if memory == nil:
      raise newException(ValueError, "backing memory must not be nil")
    if cast[uint](memory) mod uint(alignof(uint64)) != 0'u:
      raise newException(ValueError, "backing memory is not uint64-aligned")

  result.len = len
  result.bitWidth = bitWidth
  result.data = cast[ptr UncheckedArray[uint64]](memory)
  result.dataWords = words

template dataPointer(pa: PackedArray): ptr UncheckedArray[uint64] =
  (if pa.data.len == 0: nil
   else: cast[ptr UncheckedArray[uint64]](unsafeAddr pa.data[0]))

func checkIndexImpl(len, index: int64) {.inline.} =
  if index < 0 or index >= len:
    raise newException(IndexDefect, "Index out of bounds")

func checkIndex*(pa: PackedArray, i: int64) =
  ## `i` が `0 ..< pa.len` の範囲外なら `IndexDefect` を送出します。
  checkIndexImpl(pa.len, i)

func checkIndex*(pa: PackedArrayView, i: int64) =
  ## `i` が `0 ..< pa.len` の範囲外なら `IndexDefect` を送出します。
  checkIndexImpl(pa.len, i)

func maxValue*(pa: PackedArray): uint64 =
  ## この配列で表現可能な最大値を返します。
  result = maskForWidth(pa.bitWidth)

func maxValue*(pa: PackedArrayView): uint64 =
  ## このViewで表現可能な最大値を返します。
  result = maskForWidth(pa.bitWidth)

func getImpl(data: ptr UncheckedArray[uint64], bitWidth: int,
             index: int64): uint64 {.inline.} =
  if bitWidth == 0:
    return 0'u64

  let bitPos = index * int64(bitWidth)
  let wordIdx = int(bitPos shr 6)
  let bitOff = int(bitPos and 63)
  if bitWidth == 64:
    return data[wordIdx]

  let mask = maskForWidth(bitWidth)
  result = data[wordIdx] shr bitOff
  if bitOff + bitWidth > 64:
    result = result or (data[wordIdx + 1] shl (64 - bitOff))
  result = result and mask

func get*(pa: PackedArray, i: int64): uint64 =
  ## index `i` の値を返します。
  pa.checkIndex(i)
  result = getImpl(dataPointer(pa), pa.bitWidth, i)

func get*(pa: PackedArrayView, i: int64): uint64 =
  ## index `i` の値を返します。
  pa.checkIndex(i)
  result = getImpl(pa.data, pa.bitWidth, i)

func getUnchecked*(pa: PackedArray, index: int): uint64 {.inline.} =
  ## 境界検査を行わず、`index` の値を返します。
  ##
  ## 呼び出し側は `index in 0 ..< pa.len` を保証する必要があります。
  result = getImpl(dataPointer(pa), pa.bitWidth, int64(index))

func getUnchecked*(pa: PackedArrayView, index: int): uint64 {.inline.} =
  ## 境界検査を行わず、`index` の値を返します。
  ##
  ## 呼び出し側は `index in 0 ..< pa.len` を保証する必要があります。
  result = getImpl(pa.data, pa.bitWidth, int64(index))

func `[]`*(pa: PackedArray, i: int64): uint64 =
  ## `get(pa, i)` のaliasです。
  result = pa.get(i)

func `[]`*(pa: PackedArrayView, i: int64): uint64 =
  ## `get(pa, i)` のaliasです。
  result = pa.get(i)

func validateValue(bitWidth: int, value: uint64): uint64 {.inline.} =
  result = maskForWidth(bitWidth)
  if (value and not result) != 0'u64:
    raise newException(ValueError, "value exceeds bitWidth")

func setImpl(data: ptr UncheckedArray[uint64], bitWidth: int, index: int64,
             value: uint64) {.inline.} =
  let mask = validateValue(bitWidth, value)
  if bitWidth == 0:
    return

  let bitPos = index * int64(bitWidth)
  let wordIdx = int(bitPos shr 6)
  let bitOff = int(bitPos and 63)
  if bitWidth == 64:
    data[wordIdx] = value
  elif bitOff + bitWidth <= 64:
    let clearMask = not (mask shl bitOff)
    data[wordIdx] = (data[wordIdx] and clearMask) or (value shl bitOff)
  else:
    let loBits = 64 - bitOff
    let hiBits = bitWidth - loBits
    let loMask = (1'u64 shl loBits) - 1'u64
    let hiMask = (1'u64 shl hiBits) - 1'u64
    data[wordIdx] = (data[wordIdx] and not (loMask shl bitOff)) or
      ((value and loMask) shl bitOff)
    data[wordIdx + 1] = (data[wordIdx + 1] and not hiMask) or
      ((value shr loBits) and hiMask)

func set*(pa: var PackedArray, i: int64, value: uint64) =
  ## index `i` に `value` を格納します。
  ##
  ## 値が `pa.bitWidth` で表現できない場合は `ValueError` を送出します。
  pa.checkIndex(i)
  setImpl(dataPointer(pa), pa.bitWidth, i, value)

func set*(pa: var PackedArrayView, i: int64, value: uint64) =
  ## index `i` に `value` を格納します。
  ##
  ## 値が `pa.bitWidth` で表現できない場合は `ValueError` を送出します。
  pa.checkIndex(i)
  setImpl(pa.data, pa.bitWidth, i, value)

func `[]=`*(pa: var PackedArray, i: int64, value: uint64) =
  ## `set(pa, i, value)` のaliasです。
  pa.set(i, value)

func `[]=`*(pa: var PackedArrayView, i: int64, value: uint64) =
  ## `set(pa, i, value)` のaliasです。
  pa.set(i, value)

func gcdPositive(x, y: int): int =
  var a = x
  var b = y
  while b != 0:
    let remainder = a mod b
    a = b
    b = remainder
  result = a

func fillImpl(data: ptr UncheckedArray[uint64], dataWords: int, len: int64,
              bitWidth: int, value: uint64) =
  discard validateValue(bitWidth, value)
  if bitWidth == 0 or dataWords == 0:
    return

  if len <= 8:
    for i in 0'i64..<len:
      setImpl(data, bitWidth, i, value)
    return

  # 同じ値のbit列が64-bit境界へ戻る最小周期を、一度だけ構築する。
  let periodElements = 64 div gcdPositive(64, bitWidth)
  let periodWords = periodElements * bitWidth div 64
  var pattern: array[64, uint64]
  for i in 0..<periodElements:
    let bitPos = i * bitWidth
    let wordIdx = bitPos div 64
    let bitOff = bitPos mod 64
    pattern[wordIdx] = pattern[wordIdx] or (value shl bitOff)
    if bitOff + bitWidth > 64:
      pattern[wordIdx + 1] =
        pattern[wordIdx + 1] or (value shr (64 - bitOff))

  let initialWords = min(periodWords, dataWords)
  for i in 0..<initialWords:
    data[i] = pattern[i]

  var filledWords = initialWords
  while filledWords < dataWords:
    let copiedWords = min(filledWords, dataWords - filledWords)
    # sourceとdestinationは有効な非重複範囲で、copy長は残りword数以下です。
    copyMem(addr data[filledWords], addr data[0],
      copiedWords * sizeof(uint64))
    filledWords += copiedWords

  let tailBits = int((len * int64(bitWidth)) mod 64)
  if tailBits != 0:
    data[dataWords - 1] = data[dataWords - 1] and maskForWidth(tailBits)

func fill*(pa: var PackedArray, value: uint64) =
  ## 全要素を `value` で埋めます。
  ##
  ## 値が `pa.bitWidth` で表現できない場合は `ValueError` を送出します。
  fillImpl(dataPointer(pa), pa.data.len, pa.len, pa.bitWidth, value)

func fill*(pa: var PackedArrayView, value: uint64) =
  ## 全要素を `value` で埋めます。
  ##
  ## 値が `pa.bitWidth` で表現できない場合は `ValueError` を送出します。
  fillImpl(pa.data, pa.dataWords, pa.len, pa.bitWidth, value)

func toSeqImpl(data: ptr UncheckedArray[uint64], len: int64,
               bitWidth: int): seq[uint64] =
  result = newSeq[uint64](int(len))
  if bitWidth == 0 or len == 0:
    return
  if bitWidth == 64:
    # sourceとdestinationは別領域で、len個のuint64が双方で有効です。
    copyMem(addr result[0], addr data[0], result.len * sizeof(uint64))
    return

  let mask = maskForWidth(bitWidth)
  var wordIdx = 0
  var bitOff = 0
  for i in 0..<result.len:
    if bitOff + bitWidth <= 64:
      result[i] = (data[wordIdx] shr bitOff) and mask
    else:
      let loBits = 64 - bitOff
      let lo = data[wordIdx] shr bitOff
      let hi = data[wordIdx + 1] shl loBits
      result[i] = (hi or lo) and mask

    bitOff += bitWidth
    if bitOff >= 64:
      bitOff -= 64
      inc wordIdx

func toSeq*(pa: PackedArray): seq[uint64] =
  ## unpackedな `seq[uint64]` へ変換します。
  result = toSeqImpl(dataPointer(pa), pa.len, pa.bitWidth)

func toSeq*(pa: PackedArrayView): seq[uint64] =
  ## unpackedな `seq[uint64]` へ変換します。
  result = toSeqImpl(pa.data, pa.len, pa.bitWidth)

func toStringImpl(data: ptr UncheckedArray[uint64], len: int64,
                  bitWidth: int): string =
  result = "@["
  for i in 0'i64..<len:
    if i > 0:
      result.add ", "
    result.add $getImpl(data, bitWidth, i)
  result.add "]"

func `$`*(pa: PackedArray): string =
  ## Nimのsequence literal形式の文字列表現を返します。
  result = toStringImpl(dataPointer(pa), pa.len, pa.bitWidth)

func `$`*(pa: PackedArrayView): string =
  ## Nimのsequence literal形式の文字列表現を返します。
  result = toStringImpl(pa.data, pa.len, pa.bitWidth)
