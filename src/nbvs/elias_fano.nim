## Elias-Fano encoding for nondecreasing `uint64` sequences.
##
## Elias-Fano is a succinct representation for sorted integer sequences.
## `nbvs` uses the following semantics:
##
## * `universe` is exclusive; every value `x` must satisfy `x < universe`.
## * The input sequence must be nondecreasing.
## * Duplicates are allowed.
## * Indexing and select/access are 0-based.
## * `lowerBound(v)` returns the smallest index `i` such that `ef[i] >= v`, or `ef.n`.
## * `upperBound(v)` returns the smallest index `i` such that `ef[i] > v`, or `ef.n`.
## * `predecessor(v)` returns the largest value `<= v`, or raises `ValueError`.

import std/bitops
import packed_array
import succinct_bit_vector

type
  EliasFano* = object
    ## Elias-Fano representation of a nondecreasing unsigned integer sequence.
    n*: int64 ## Number of encoded values.
    universe*: uint64 ## Exclusive upper bound for encoded values.
    lowBits*: int ## Number of low bits stored in `lows`.
    lowMask*: uint64 ## Mask for extracting low bits.
    maxHigh*: uint64 ## Maximum high-part value in the encoded sequence.
    lows*: PackedArray ## Packed low-bit array.
    highBits*: SuccinctBitVector ## Unary-coded high-bit vector.

func floorLog2*(x: uint64): int =
  ## Returns `floor(log2(x))`.
  ##
  ## `floorLog2(0)` is defined as `0` for convenience.
  if x == 0:
    return 0
  result = 63 - countLeadingZeroBits(x)

func calcLowBits*(universe: uint64, n: int64): int =
  ## Computes the standard Elias-Fano low-bit width.
  ##
  ## The value is `floor(log2(universe / n))`.  Returns `0` when `n <= 0` or
  ## when `universe / n == 0`.
  if n <= 0:
    return 0

  let q = universe div uint64(n)
  if q == 0:
    return 0

  result = floorLog2(q)

func maskForLowBits*(lowBits: int): uint64 =
  ## Returns a low-bit mask for Elias-Fano low parts.
  ##
  ## Valid `lowBits` range is `0 .. 64`.
  if lowBits < 0 or lowBits > 64:
    raise newException(ValueError, "lowBits must be in 0..64")

  if lowBits == 0:
    result = 0'u64
  elif lowBits == 64:
    result = uint64.high
  else:
    result = (1'u64 shl lowBits) - 1'u64

func genEliasFano*(xs: openArray[uint64], universe: uint64): EliasFano =
  ## Creates an Elias-Fano representation from a nondecreasing sequence.
  ##
  ## `universe` is exclusive.  For non-empty `xs`, `universe` must be positive
  ## and every value must be smaller than `universe`.
  ##
  ## Raises `ValueError` when the input is not nondecreasing or a value exceeds
  ## the universe.
  result.n = int64(xs.len)
  result.universe = universe
  result.lowBits = calcLowBits(universe, result.n)
  result.lowMask = maskForLowBits(result.lowBits)
  result.maxHigh = 0

  result.lows = genPackedArray(result.n, result.lowBits)

  if result.n == 0:
    result.highBits = genSuccinctBitVector(0)
    result.highBits.build()
    return

  if universe == 0:
    raise newException(ValueError, "universe must be positive when xs is non-empty")

  var prev = 0'u64

  for i, x in xs:
    if x >= universe:
      raise newException(ValueError, "value exceeds universe")

    if i > 0 and x < prev:
      raise newException(ValueError, "Elias-Fano input must be nondecreasing")

    prev = x

  result.maxHigh = xs[^1] shr result.lowBits

  let highBitsLen = int64(result.maxHigh) + result.n + 1
  result.highBits = genSuccinctBitVector(highBitsLen)

  for i, x in xs:
    let idx = int64(i)
    let low =
      if result.lowBits == 0:
        0'u64
      else:
        x and result.lowMask

    let high = x shr result.lowBits

    result.lows[idx] = low
    result.highBits[int64(high) + idx] = true

  result.highBits.build()

func checkIndex*(ef: EliasFano, i: int64) =
  ## Raises `IndexDefect` when `i` is outside `0 ..< ef.n`.
  if i < 0 or i >= ef.n:
    raise newException(IndexDefect, "Index out of bounds")

func access*(ef: EliasFano, i: int64): uint64 =
  ## Returns the encoded value at index `i`.
  ef.checkIndex(i)

  let pos = ef.highBits.select1(i)
  let high = uint64(pos - i)

  let low =
    if ef.lowBits == 0:
      0'u64
    else:
      ef.lows[i]

  result = (high shl ef.lowBits) or low

func `[]`*(ef: EliasFano, i: int64): uint64 =
  ## Alias for `access(ef, i)`.
  result = ef.access(i)

func select*(ef: EliasFano, i: int64): uint64 =
  ## Alias for Elias-Fano access/select.
  ##
  ## `i` is 0-based.
  result = ef.access(i)

func firstIndexWithHighAtLeast*(ef: EliasFano, high: uint64): int64 =
  ## Returns the smallest index `i` such that `high(i) >= high`.
  ##
  ## Returns `0` for an empty sequence or `high == 0`; returns `ef.n` when
  ## `high > ef.maxHigh`.
  if ef.n == 0:
    return 0

  if high == 0:
    return 0

  if high > ef.maxHigh:
    return ef.n

  let zeroPos = ef.highBits.select0(int64(high - 1))
  result = ef.highBits.rank1(zeroPos)

func firstIndexWithHighGreaterThan*(ef: EliasFano, high: uint64): int64 =
  ## Returns the smallest index `i` such that `high(i) > high`.
  if ef.n == 0:
    return 0

  if high >= ef.maxHigh:
    return ef.n

  result = ef.firstIndexWithHighAtLeast(high + 1)

func lowerBoundByAccess*(ef: EliasFano, v: uint64): int64 =
  ## Returns `lowerBound(v)` using binary search over `access`.
  ##
  ## This is primarily useful as a simple reference implementation.
  var lo = 0'i64
  var hi = ef.n

  while lo < hi:
    let mid = (lo + hi) div 2
    if ef.access(mid) < v:
      lo = mid + 1
    else:
      hi = mid

  result = lo

func lowerBound*(ef: EliasFano, v: uint64): int64 =
  ## Returns the smallest index `i` such that `ef[i] >= v`.
  ##
  ## Returns `ef.n` if no such index exists.
  if ef.n == 0:
    return 0

  if v >= ef.universe:
    return ef.n

  let targetHigh = v shr ef.lowBits
  let targetLow =
    if ef.lowBits == 0:
      0'u64
    else:
      v and ef.lowMask

  let bucketStart = ef.firstIndexWithHighAtLeast(targetHigh)
  if bucketStart >= ef.n:
    return ef.n

  let firstHighAtStart = uint64(ef.highBits.select1(bucketStart) - bucketStart)

  if firstHighAtStart > targetHigh:
    return bucketStart

  let bucketEnd = ef.firstIndexWithHighGreaterThan(targetHigh)

  var lo = bucketStart
  var hi = bucketEnd

  while lo < hi:
    let mid = (lo + hi) div 2
    let low =
      if ef.lowBits == 0:
        0'u64
      else:
        ef.lows[mid]

    if low < targetLow:
      lo = mid + 1
    else:
      hi = mid

  result = lo

func upperBound*(ef: EliasFano, v: uint64): int64 =
  ## Returns the smallest index `i` such that `ef[i] > v`.
  ##
  ## Returns `ef.n` if no such index exists.  Handles `uint64.high` without
  ## overflow.
  if ef.n == 0:
    return 0

  if v == uint64.high:
    return ef.n

  result = ef.lowerBound(v + 1)

func lastLessEqual*(ef: EliasFano, v: uint64): int64 =
  ## Returns the largest index `i` such that `ef[i] <= v`.
  ##
  ## Returns `-1` when no such index exists.
  if ef.n == 0:
    return -1

  let ub = ef.upperBound(v)
  result = ub - 1

func predecessorIndex*(ef: EliasFano, v: uint64): int64 =
  ## Alias for `lastLessEqual(ef, v)`.
  result = ef.lastLessEqual(v)

func predecessor*(ef: EliasFano, v: uint64): uint64 =
  ## Returns the largest encoded value `<= v`.
  ##
  ## Raises `ValueError` when no predecessor exists.
  let i = ef.lastLessEqual(v)
  if i < 0:
    raise newException(ValueError, "predecessor does not exist")
  result = ef.access(i)

func countLessEqual*(ef: EliasFano, v: uint64): int64 =
  ## Returns the number of encoded values `<= v`.
  result = ef.upperBound(v)

func countLessThan*(ef: EliasFano, v: uint64): int64 =
  ## Returns the number of encoded values `< v`.
  result = ef.lowerBound(v)

iterator items*(ef: EliasFano): uint64 =
  ## Iterates over encoded values in order.
  for i in 0'i64..<ef.n:
    yield ef.access(i)

func toSeq*(ef: EliasFano): seq[uint64] =
  ## Converts the encoded sequence to an unpacked `seq[uint64]`.
  result = newSeq[uint64](int(ef.n))
  for i in 0'i64..<ef.n:
    result[int(i)] = ef.access(i)
