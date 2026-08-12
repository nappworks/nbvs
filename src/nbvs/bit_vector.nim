## Basic mutable bit vector.
##
## `BitVector` is a small, byte-backed mutable bit vector.  It is useful as a
## simple building block and as a reference implementation for tests.
##
## Indexing is 0-based.  `setBit`, `clearBit`, `[]`, and `[]=` raise
## `IndexDefect` when the index is outside `0 ..< maxOfBits`.

import std/bitops

func ceilDiv[T: SomeInteger](x, y: T): T =
  result = (x + y - 1) div y

func access[T: SomeInteger](val: T, pos: int): bool =
  val.testBit(pos)

type
  BitVector* = object
    ## Mutable byte-backed bit vector.
    maxOfBits*: int ## Maximum number of addressable bits.
    lenOfBits*: int ## Logical length; grows to highest written position plus one.
    data*: seq[uint8] ## Raw little-endian byte storage.

  BitVectorView* = object
    ## 呼び出し側が所有するbyte領域を参照する非所有bit vectorです。
    ##
    ## backing memoryはViewより長く有効に保つ必要があります。
    maxOfBits*: int
    lenOfBits*: int
    data*: ptr UncheckedArray[uint8]
    dataBytes*: int

func genBitVector*(max: int): BitVector =
  ## Creates a `BitVector` that can address `max` bits.
  ##
  ## The initial logical length is `0`; writing a bit grows `lenOfBits`.
  ##
  ## Raises `ValueError` when `max` is negative.
  if max < 0:
    raise newException(ValueError, "max must be non-negative")
  result.maxOfBits = max
  result.lenOfBits = 0
  result.data = newSeq[uint8](ceilDiv(max, 8))

func initBitVectorView*(memory: pointer, memorySize, max: int,
                        len = 0): BitVectorView =
  ## 外部の連続byte領域から非所有Viewを作成します。
  ##
  ## `len` は論理bit長です。範囲、必要容量、nil pointerを検証し、不正な場合は
  ## `ValueError` を送出します。領域の所有権と有効期間は呼び出し側が管理します。
  if max < 0:
    raise newException(ValueError, "max must be non-negative")
  if len < 0 or len > max:
    raise newException(ValueError, "len must be in 0..max")
  if memorySize < 0:
    raise newException(ValueError, "memorySize must be non-negative")
  let bytes = ceilDiv(max, 8)
  if memorySize < bytes:
    raise newException(ValueError, "backing memory is too small")
  if bytes > 0 and memory == nil:
    raise newException(ValueError, "backing memory must not be nil")
  result = BitVectorView(maxOfBits: max, lenOfBits: len,
    data: cast[ptr UncheckedArray[uint8]](memory), dataBytes: bytes)

func checkIndex[B: BitVector | BitVectorView](bv: B, pos: int) =
  if pos < 0 or pos >= bv.maxOfBits:
    raise newException(IndexDefect, "Index out of bounds")

func setBit*[B: BitVector | BitVectorView](bv: var B, pos: int) =
  ## Sets the bit at `pos` to `1`.
  bv.checkIndex(pos)
  let posOfBytes = pos div 8
  let posOfBits = pos mod 8
  bv.data[posOfBytes].setBit(posOfBits)
  if pos >= bv.lenOfBits:
    bv.lenOfBits = pos + 1

func clearBit*[B: BitVector | BitVectorView](bv: var B, pos: int) =
  ## Clears the bit at `pos` to `0`.
  ##
  ## Clearing a previously unwritten but addressable position still grows the
  ## logical length to `pos + 1`.
  bv.checkIndex(pos)
  let posOfBytes = pos div 8
  let posOfBits = pos mod 8
  bv.data[posOfBytes].clearBit(posOfBits)
  if pos >= bv.lenOfBits:
    bv.lenOfBits = pos + 1

func `[]=`*[B: BitVector | BitVectorView](bv: var B, pos: int, b: bool) =
  ## Writes `b` to the bit at `pos`.
  if b:
    bv.setBit(pos)
  else:
    bv.clearBit(pos)

func access*[B: BitVector | BitVectorView](bv: B, pos: int): bool =
  ## Returns the bit at `pos`.
  bv.checkIndex(pos)
  let posOfBytes = pos div 8
  let posOfBits = pos mod 8
  result = bv.data[posOfBytes].access(posOfBits)

func `[]`*[B: BitVector | BitVectorView](bv: B, pos: int): bool =
  ## Alias for `access(bv, pos)`.
  result = access(bv, pos)

func toBitString[B: BitVector | BitVectorView](bv: B): string =
  for i in 0..<bv.lenOfBits:
    result.add(if bv[i]: '1' else: '0')

func `$`*(bv: BitVector): string =
  ## 論理bit列をindex順の文字列で返します。
  result = toBitString(bv)

func `$`*(bv: BitVectorView): string =
  ## 論理bit列をindex順の文字列で返します。
  result = toBitString(bv)
