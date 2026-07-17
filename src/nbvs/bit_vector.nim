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

func checkIndex(bv: BitVector, pos: int) =
  if pos < 0 or pos >= bv.maxOfBits:
    raise newException(IndexDefect, "Index out of bounds")

func setBit*(bv: var BitVector, pos: int) =
  ## Sets the bit at `pos` to `1`.
  bv.checkIndex(pos)
  let posOfBytes = pos div 8
  let posOfBits = pos mod 8
  bv.data[posOfBytes].setBit(posOfBits)
  if pos >= bv.lenOfBits:
    bv.lenOfBits = pos + 1

func clearBit*(bv: var BitVector, pos: int) =
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

func `[]=`*(bv: var BitVector, pos: int, b: bool) =
  ## Writes `b` to the bit at `pos`.
  if b:
    bv.setBit(pos)
  else:
    bv.clearBit(pos)

func access*(bv: BitVector, pos: int): bool =
  ## Returns the bit at `pos`.
  bv.checkIndex(pos)
  let posOfBytes = pos div 8
  let posOfBits = pos mod 8
  result = bv.data[posOfBytes].access(posOfBits)

func `[]`*(bv: BitVector, pos: int): bool =
  ## Alias for `access(bv, pos)`.
  result = access(bv, pos)

func `$`*(bv: BitVector): string =
  ## Returns the logical bit string from index `0` to `lenOfBits - 1`.
  for i in 0..<bv.lenOfBits:
    result.add(if bv[i]: '1' else: '0')
