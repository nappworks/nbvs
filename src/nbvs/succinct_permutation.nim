## Packed static permutation with a sparse inverse index.
##
## `SuccinctPermutation` stores the forward permutation once in a
## `PackedArray`.  Inverse lookup is accelerated by sparse cycle landmarks:
##
## * cycles whose length is at most `inverseStride` store no inverse metadata;
## * longer cycles mark every `inverseStride`-th node;
## * each landmark stores the previous landmark on that cycle.
##
## `access(i)` is O(1).  `inverse(value)` follows at most one stride to a
## landmark and at most one additional stride from the previous landmark to the
## predecessor.  The default stride is 32.
##
## `SuccinctPermutationView` composes `PackedArrayView` and
## `SuccinctBitVectorView` instances.  It does not own backing memory.

import packed_array
import succinct_bit_vector

const
  DefaultSuccinctPermutationInverseStride* = 32

type
  SuccinctPermutation* = object
    ## Owning static permutation.
    n*: int64
    inverseStride*: int
    values*: PackedArray
    landmarks*: SuccinctBitVector
    previousLandmarks*: PackedArray

  SuccinctPermutationView* = object
    ## Non-owning view over a static permutation and its sparse inverse index.
    ##
    ## The caller must keep all backing memory alive and at stable addresses for
    ## the lifetime of this view.
    n*: int64
    inverseStride*: int
    values*: PackedArrayView
    landmarks*: SuccinctBitVectorView
    previousLandmarks*: PackedArrayView

func permutationBitWidth*(n: int64): int =
  ## Returns the minimum fixed width required to store values in `0 ..< n`.
  ##
  ## Empty and singleton permutations use width 0.
  if n < 0:
    raise newException(ValueError, "n must be non-negative")
  if n <= 1:
    return 0

  var value = uint64(n - 1)
  while value != 0:
    inc result
    value = value shr 1

func initSuccinctPermutationView*(n: int64, inverseStride: int,
    values: PackedArrayView, landmarks: SuccinctBitVectorView,
    previousLandmarks: PackedArrayView): SuccinctPermutationView =
  ## Creates a non-owning permutation view from already initialized subviews.
  ##
  ## This validates structural metadata only.  It does not scan the packed
  ## permutation or inverse metadata.
  if n < 0:
    raise newException(ValueError, "n must be non-negative")
  if inverseStride <= 0:
    raise newException(ValueError, "inverseStride must be positive")

  let width = permutationBitWidth(n)
  if values.len != n or values.bitWidth != width:
    raise newException(ValueError, "forward permutation view metadata does not match")
  if landmarks.lenOfBits != n:
    raise newException(ValueError, "landmark bit vector length does not match")
  if not landmarks.isCalced:
    raise newException(ValueError, "landmark rank/select dictionary is not built")
  if previousLandmarks.len != landmarks.totalOnes:
    raise newException(ValueError, "landmark predecessor count does not match")
  if previousLandmarks.bitWidth != width:
    raise newException(ValueError, "landmark predecessor width does not match")

  result.n = n
  result.inverseStride = inverseStride
  result.values = values
  result.landmarks = landmarks
  result.previousLandmarks = previousLandmarks

func genSuccinctPermutation*(xs: openArray[uint64],
    inverseStride = DefaultSuccinctPermutationInverseStride):
    SuccinctPermutation =
  ## Builds a packed static permutation over `0 ..< xs.len`.
  ##
  ## `xs[i]` is the forward image of `i`.  Every value must occur exactly
  ## once.  `inverseStride` controls the inverse-space/time trade-off and must
  ## be positive.
  if inverseStride <= 0:
    raise newException(ValueError, "inverseStride must be positive")

  result.n = int64(xs.len)
  result.inverseStride = inverseStride
  let width = permutationBitWidth(result.n)
  result.values = genPackedArray(result.n, width)

  var seen = newSeq[bool](xs.len)
  for i, value in xs:
    if value >= uint64(xs.len):
      raise newException(ValueError, "permutation value is out of range")
    let index = int(value)
    if seen[index]:
      raise newException(ValueError, "permutation contains duplicate values")
    seen[index] = true
    result.values[int64(i)] = value

  result.landmarks = genSuccinctBitVector(result.n)

  type LandmarkPair = tuple[node, previous: uint64]
  var landmarkPairs: seq[LandmarkPair]
  var visited = newSeq[bool](xs.len)

  for start in 0..<xs.len:
    if visited[start]:
      continue

    var cycle: seq[uint64]
    var current = uint64(start)
    while not visited[int(current)]:
      visited[int(current)] = true
      cycle.add current
      current = xs[int(current)]

    # A validated permutation can only close the cycle at its starting node.
    if current != uint64(start):
      raise newException(ValueError, "permutation cycle structure is inconsistent")

    # Short cycles are cheap enough to invert by walking until they close, so
    # they need no inverse metadata.
    if cycle.len <= inverseStride:
      continue

    var markIndices: seq[int]
    var cycleIndex = 0
    while cycleIndex < cycle.len:
      markIndices.add cycleIndex
      cycleIndex += inverseStride

    for markIndex in 0..<markIndices.len:
      let node = cycle[markIndices[markIndex]]
      let previousMarkIndex =
        markIndices[(markIndex + markIndices.len - 1) mod markIndices.len]
      let previous = cycle[previousMarkIndex]
      result.landmarks.setBit(int64(node))
      landmarkPairs.add (node: node, previous: previous)

  result.landmarks.build()
  result.previousLandmarks =
    genPackedArray(int64(landmarkPairs.len), width)

  for pair in landmarkPairs:
    # rank1(node) is the 0-based ordinal of a set bit at node because rank1 is
    # defined on the half-open range [0, node).
    let ordinal = result.landmarks.rank1(int64(pair.node))
    result.previousLandmarks[ordinal] = pair.previous

func checkIndex*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, index: int64) =
  ## Raises `IndexDefect` when `index` is outside `0 ..< n`.
  if index < 0 or index >= permutation.n:
    raise newException(IndexDefect, "Index out of bounds")

func checkValue[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, value: uint64) =
  if value >= uint64(permutation.n):
    raise newException(IndexDefect, "Permutation value out of bounds")

func access*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, index: int64): uint64 =
  ## Returns the forward image at `index`.
  permutation.checkIndex(index)
  result = permutation.values[index]

func accessUnchecked*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, index: int): uint64 {.inline.} =
  ## Returns the forward image without checking `index`.
  ##
  ## The caller must guarantee `index in 0 ..< n`.
  result = permutation.values.getUnchecked(index)

func `[]`*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, index: int64): uint64 =
  ## Alias for `access(permutation, index)`.
  result = permutation.access(index)

func landmarkCount*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P): int64 {.inline.} =
  ## Returns the number of sparse inverse landmarks.
  result = permutation.landmarks.totalOnes

func scanFromPreviousLandmark[
    P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, target, landmark: uint64): uint64 =
  let ordinal = permutation.landmarks.rank1(int64(landmark))
  if ordinal < 0 or ordinal >= permutation.previousLandmarks.len:
    raise newException(ValueError, "inverse landmark metadata is inconsistent")

  var current = permutation.previousLandmarks[ordinal]
  for _ in 0..<permutation.inverseStride:
    let next = permutation.values[int64(current)]
    if next == target:
      return current
    current = next

  raise newException(ValueError, "inverse landmark traversal exceeded stride")

func inverseUnchecked*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, value: uint64): uint64 =
  ## Returns the unique index whose forward image is `value`.
  ##
  ## The caller must guarantee `value < n`.  Generated permutations complete
  ## inverse lookup in fewer than `2 * inverseStride` forward traversals.
  if permutation.n <= 1:
    return value

  if permutation.landmarks.access(int64(value)):
    return permutation.scanFromPreviousLandmark(value, value)

  var current = value
  for _ in 0..<permutation.inverseStride:
    let next = permutation.values[int64(current)]
    if next == value:
      # This is a short cycle with no inverse landmarks.
      return current

    current = next
    if permutation.landmarks.access(int64(current)):
      return permutation.scanFromPreviousLandmark(value, current)

  raise newException(ValueError, "inverse traversal exceeded stride")

func inverse*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, value: uint64): uint64 =
  ## Returns the unique index whose forward image is `value`.
  permutation.checkValue(value)
  result = permutation.inverseUnchecked(value)

iterator items*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P): uint64 =
  ## Iterates over forward permutation values in index order.
  for index in 0'i64..<permutation.n:
    yield permutation.values[index]

func toSeq*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P): seq[uint64] =
  ## Decodes the forward permutation into an unpacked sequence.
  result = newSeq[uint64](int(permutation.n))
  for index in 0'i64..<permutation.n:
    result[int(index)] = permutation.values[index]
