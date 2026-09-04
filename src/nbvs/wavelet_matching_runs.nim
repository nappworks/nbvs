## Contiguous physical-position runs for equality predicates on Wavelet Matrix.
##
## `matchingRuns` follows the known target value from the most-significant
## Wavelet level downward. At each level, rank is used to reject ranges with no
## matching target bits and to accept homogeneous ranges without enumerating
## positions. Only mixed ranges are split. Accepted ranges are then mapped to
## the next Wavelet level with the same rank transform used by equality rank.

import wavelet_matrix
import succinct_bit_vector

type
  MatchingRun* = tuple[left, right: int64]
    ## A maximal half-open physical-position interval `[left, right)` whose
    ## values equal the requested target.

  MatchingRunCandidate = tuple[
    physicalLeft: int64,
    currentLeft: int64,
    currentRight: int64]

func valueFits(bitWidth: int, value: uint64): bool {.inline.} =
  if bitWidth == 0:
    value == 0
  elif bitWidth == 64:
    true
  else:
    (value shr bitWidth) == 0

iterator matchingBitRuns[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, targetOne: bool, left, right: int64): MatchingRun =
  ## Emits maximal sub-ranges in `[left, right)` whose bits all equal
  ## `targetOne`. Rank rejects or accepts whole ranges; only mixed ranges are
  ## recursively subdivided.
  if left >= right:
    return

  var stack: seq[MatchingRun] = @[(left: left, right: right)]
  var pending = false
  var pendingLeft = 0'i64
  var pendingRight = 0'i64

  while stack.len > 0:
    let node = stack.pop()
    let ones = bits.rank1Unchecked(node.right) - bits.rank1Unchecked(node.left)
    let length = node.right - node.left
    let matching = if targetOne: ones else: length - ones

    if matching == 0:
      continue

    if matching == length:
      if pending and pendingRight == node.left:
        pendingRight = node.right
      else:
        if pending:
          yield (left: pendingLeft, right: pendingRight)
        pending = true
        pendingLeft = node.left
        pendingRight = node.right
      continue

    let middle = node.left + (length shr 1)
    # LIFO: push right first so matching intervals are observed left-to-right.
    stack.add (left: middle, right: node.right)
    stack.add (left: node.left, right: middle)

  if pending:
    yield (left: pendingLeft, right: pendingRight)

iterator matchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, left, right: int64): MatchingRun =
  ## Emits maximal physical-position runs equal to `value` inside
  ## `[left, right)`.
  ##
  ## The traversal never calls Wavelet `select`. Candidate intervals are
  ## narrowed top-down by the known target bits, using rank both for homogeneous
  ## interval detection and for mapping surviving intervals to the next level.
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")
  if left == right or wm.n == 0 or not valueFits(wm.bitWidth, value):
    return

  if wm.bitWidth == 0:
    yield (left: left, right: right)
    return

  var candidates: seq[MatchingRunCandidate] = @[
    (physicalLeft: left, currentLeft: left, currentRight: right)]

  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let targetOne = ((value shr shift) and 1'u64) != 0
    var next: seq[MatchingRunCandidate]

    for candidate in candidates:
      for run in matchingBitRuns(wm.levels[level], targetOne,
          candidate.currentLeft, candidate.currentRight):
        let physicalLeft = candidate.physicalLeft +
          (run.left - candidate.currentLeft)
        let leftOnes = wm.levels[level].rank1Unchecked(run.left)
        let rightOnes = wm.levels[level].rank1Unchecked(run.right)

        var mappedLeft, mappedRight: int64
        if targetOne:
          mappedLeft = wm.zeroCounts[level] + leftOnes
          mappedRight = wm.zeroCounts[level] + rightOnes
        else:
          mappedLeft = run.left - leftOnes
          mappedRight = run.right - rightOnes

        next.add (
          physicalLeft: physicalLeft,
          currentLeft: mappedLeft,
          currentRight: mappedRight)

    candidates = move(next)
    if candidates.len == 0:
      return

  for candidate in candidates:
    yield (
      left: candidate.physicalLeft,
      right: candidate.physicalLeft +
        (candidate.currentRight - candidate.currentLeft))

iterator matchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): MatchingRun =
  ## Emits maximal physical-position runs equal to `value` over the full matrix.
  for run in wm.matchingRuns(value, 0, wm.n):
    yield run

func collectMatchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, left, right: int64): seq[MatchingRun] =
  ## Collects `matchingRuns(value, left, right)` into a sequence.
  for run in wm.matchingRuns(value, left, right):
    result.add run

func collectMatchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): seq[MatchingRun] =
  ## Collects full-range `matchingRuns(value)` into a sequence.
  wm.collectMatchingRuns(value, 0, wm.n)
