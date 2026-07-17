## Fixed-width packed unsigned integer array.
##
## `PackedArray` stores each value using exactly `bitWidth` bits.  It is a
## compact backing store for succinct data structures such as Elias-Fano.
##
## `bitWidth` may be `0 .. 64`.  When `bitWidth == 0`, every value is
## implicitly `0` and no backing words are allocated.

type
  PackedArray* = object
    ## Fixed-width packed array of unsigned 64-bit values.
    len*: int64 ## Number of elements.
    bitWidth*: int ## Number of bits used per element. Valid range is `0 .. 64`.
    data*: seq[uint64] ## Raw packed storage. Exposed for diagnostics and tests.

func ceilDiv*[T: SomeInteger](x, y: T): T =
  ## Returns `ceil(x / y)` for integer values.
  ##
  ## Returns `0` when `x <= 0`.  `y` must be positive.
  if x <= 0:
    return 0
  result = (x + y - 1) div y

func maskForWidth*(bitWidth: int): uint64 =
  ## Returns a low-bit mask for `bitWidth` bits.
  ##
  ## `maskForWidth(0) == 0` and `maskForWidth(64) == uint64.high`.
  if bitWidth < 0 or bitWidth > 64:
    raise newException(ValueError, "bitWidth must be in 0..64")

  if bitWidth == 0:
    return 0'u64
  elif bitWidth == 64:
    return uint64.high
  else:
    return (1'u64 shl bitWidth) - 1'u64

func genPackedArray*(len: int64, bitWidth: int): PackedArray =
  ## Creates a packed array with `len` elements and `bitWidth` bits per value.
  ##
  ## Raises `ValueError` when `len < 0` or `bitWidth` is outside `0 .. 64`.
  if len < 0:
    raise newException(ValueError, "len must be non-negative")
  if bitWidth < 0 or bitWidth > 64:
    raise newException(ValueError, "bitWidth must be in 0..64")

  result.len = len
  result.bitWidth = bitWidth

  if bitWidth == 0 or len == 0:
    result.data = @[]
  else:
    let totalBits = len * int64(bitWidth)
    result.data = newSeq[uint64](int(ceilDiv(totalBits, 64'i64)))

func checkIndex*(pa: PackedArray, i: int64) =
  ## Raises `IndexDefect` when `i` is outside `0 ..< pa.len`.
  if i < 0 or i >= pa.len:
    raise newException(IndexDefect, "Index out of bounds")

func maxValue*(pa: PackedArray): uint64 =
  ## Returns the maximum value representable by this array's bit width.
  result = maskForWidth(pa.bitWidth)

func get*(pa: PackedArray, i: int64): uint64 =
  ## Returns the value at index `i`.
  pa.checkIndex(i)

  if pa.bitWidth == 0:
    return 0'u64

  let bitPos = i * int64(pa.bitWidth)
  let wordIdx = int(bitPos div 64)
  let bitOff = int(bitPos mod 64)
  let mask = maskForWidth(pa.bitWidth)

  if pa.bitWidth == 64:
    return pa.data[wordIdx]

  if bitOff + pa.bitWidth <= 64:
    result = (pa.data[wordIdx] shr bitOff) and mask
  else:
    let loBits = 64 - bitOff
    let hiBits = pa.bitWidth - loBits

    let lo = pa.data[wordIdx] shr bitOff
    let hi = pa.data[wordIdx + 1] and ((1'u64 shl hiBits) - 1'u64)

    result = ((hi shl loBits) or lo) and mask

func `[]`*(pa: PackedArray, i: int64): uint64 =
  ## Alias for `get(pa, i)`.
  result = pa.get(i)

func set*(pa: var PackedArray, i: int64, value: uint64) =
  ## Stores `value` at index `i`.
  ##
  ## Raises `ValueError` when `value` cannot be represented by `pa.bitWidth`.
  pa.checkIndex(i)

  if pa.bitWidth == 0:
    if value != 0'u64:
      raise newException(ValueError, "value exceeds bitWidth")
    return

  let mask = maskForWidth(pa.bitWidth)
  if (value and not mask) != 0'u64:
    raise newException(ValueError, "value exceeds bitWidth")

  let bitPos = i * int64(pa.bitWidth)
  let wordIdx = int(bitPos div 64)
  let bitOff = int(bitPos mod 64)

  if pa.bitWidth == 64:
    pa.data[wordIdx] = value
    return

  if bitOff + pa.bitWidth <= 64:
    let clearMask = not (mask shl bitOff)
    pa.data[wordIdx] = (pa.data[wordIdx] and clearMask) or ((value and mask) shl bitOff)
  else:
    let loBits = 64 - bitOff
    let hiBits = pa.bitWidth - loBits

    let loMask = (1'u64 shl loBits) - 1'u64
    let hiMask = (1'u64 shl hiBits) - 1'u64

    pa.data[wordIdx] =
      (pa.data[wordIdx] and not (loMask shl bitOff)) or
      ((value and loMask) shl bitOff)

    pa.data[wordIdx + 1] =
      (pa.data[wordIdx + 1] and not hiMask) or
      ((value shr loBits) and hiMask)

func `[]=`*(pa: var PackedArray, i: int64, value: uint64) =
  ## Alias for `set(pa, i, value)`.
  pa.set(i, value)

func fill*(pa: var PackedArray, value: uint64) =
  ## Fills every element with `value`.
  ##
  ## Raises `ValueError` when `value` cannot be represented by `pa.bitWidth`.
  if pa.bitWidth == 0:
    if value != 0'u64:
      raise newException(ValueError, "value exceeds bitWidth")
    return

  let mask = maskForWidth(pa.bitWidth)
  if (value and not mask) != 0'u64:
    raise newException(ValueError, "value exceeds bitWidth")

  for i in 0'i64..<pa.len:
    pa[i] = value

func toSeq*(pa: PackedArray): seq[uint64] =
  ## Converts the packed array to an unpacked `seq[uint64]`.
  result = newSeq[uint64](int(pa.len))
  for i in 0'i64..<pa.len:
    result[int(i)] = pa[i]

func `$`*(pa: PackedArray): string =
  ## Returns a Nim-like sequence literal representation.
  result = "@["
  for i in 0'i64..<pa.len:
    if i > 0:
      result.add ", "
    result.add $pa[i]
  result.add "]"
