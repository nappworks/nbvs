## 疎な逆引きindexを持つpacked static permutationです。
##
## `SuccinctPermutation` はforward permutationを1本の
## `PackedArray` に保持し、疎なcycle landmarkでinverse lookupを高速化します。
##
## * 長さが `inverseStride` 以下のcycleにはinverse metadataを持ちません。
## * 長いcycleでは `inverseStride` ごとにnodeをlandmarkとして記録します。
## * 各landmarkは同じcycle上の直前のlandmarkを保持します。
##
## `access(i)` はO(1)です。生成されたinverse indexでは `inverse(value)` は
## 最大 `inverseStride` 回のforward traversalで完了します。既定strideは32です。
##
## `SuccinctPermutationView` は `PackedArrayView` と
## `SuccinctBitVectorView` を合成する非所有Viewです。backing memoryは所有しません。

import packed_array
import succinct_bit_vector

const
  DefaultSuccinctPermutationInverseStride* = 32

type
  SuccinctPermutation* = object
    ## backing storageを所有する静的permutationです。
    n*: int64
    inverseStride*: int
    values*: PackedArray
    landmarks*: SuccinctBitVector
    previousLandmarks*: PackedArray

  SuccinctPermutationView* = object
    ## 静的permutationと疎なinverse indexを参照する非所有Viewです。
    ##
    ## 呼び出し側は、このViewの使用中すべてのbacking memoryを有効かつ
    ## 同じaddressに保つ必要があります。
    n*: int64
    inverseStride*: int
    values*: PackedArrayView
    landmarks*: SuccinctBitVectorView
    previousLandmarks*: PackedArrayView

func permutationBitWidth*(n: int64): int =
  ## `0 ..< n` の値を保持するために必要な最小固定bit幅を返します。
  ##
  ## 空permutationと1要素permutationではbit幅0を使用します。
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
  ## 初期化済みの下位Viewから非所有permutation Viewを構築します。
  ##
  ## 構造metadataだけを検証します。packed permutationやinverse metadataの
  ## 全走査は行いません。
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
  ## `0 ..< xs.len` 上のpacked static permutationを構築します。
  ##
  ## `xs[i]` は `i` のforward imageです。各値はちょうど1回だけ出現する必要が
  ## あります。`inverseStride` はinverse lookupの容量/時間trade-offを制御し、
  ## 正の値でなければなりません。
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

    # 検証済みpermutationではcycleは開始nodeにだけ戻ります。
    if current != uint64(start):
      raise newException(ValueError, "permutation cycle structure is inconsistent")

    # 短いcycleは閉じるまでforwardに辿っても十分安価なので、
    # inverse metadataを持ちません。
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
    # rank1は半開区間 [0, node) を数えるため、set bitであるnodeに対する
    # rank1(node) はそのlandmarkの0-based ordinalになります。
    let ordinal = result.landmarks.rank1(int64(pair.node))
    result.previousLandmarks[ordinal] = pair.previous

func checkIndex*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, index: int64) =
  ## `index` が `0 ..< n` の範囲外なら `IndexDefect` を送出します。
  if index < 0 or index >= permutation.n:
    raise newException(IndexDefect, "Index out of bounds")

func checkValue[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, value: uint64) =
  if value >= uint64(permutation.n):
    raise newException(IndexDefect, "Permutation value out of bounds")

func access*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, index: int64): uint64 =
  ## `index` のforward imageを返します。
  permutation.checkIndex(index)
  result = permutation.values[index]

func accessUnchecked*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, index: int): uint64 {.inline.} =
  ## `index` の境界検査を行わずforward imageを返します。
  ##
  ## 呼び出し側は `index in 0 ..< n` を保証する必要があります。
  result = permutation.values.getUnchecked(index)

func `[]`*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, index: int64): uint64 =
  ## `access(permutation, index)` のaliasです。
  result = permutation.access(index)

func landmarkCount*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P): int64 {.inline.} =
  ## 疎なinverse landmark数を返します。
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
  ## forward imageが `value` になる一意なindexを返します。
  ##
  ## 呼び出し側は `value < n` を保証する必要があります。生成されたpermutationでは
  ## inverse lookupは最大 `inverseStride` 回のforward traversalで完了します。
  if permutation.n <= 1:
    return value

  if permutation.landmarks.access(int64(value)):
    return permutation.scanFromPreviousLandmark(value, value)

  var current = value
  for _ in 0..<permutation.inverseStride:
    let next = permutation.values[int64(current)]
    if next == value:
      # inverse landmarkを持たない短いcycleです。
      return current

    current = next
    if permutation.landmarks.access(int64(current)):
      return permutation.scanFromPreviousLandmark(value, current)

  raise newException(ValueError, "inverse traversal exceeded stride")

func inverse*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P, value: uint64): uint64 =
  ## forward imageが `value` になる一意なindexを返します。
  permutation.checkValue(value)
  result = permutation.inverseUnchecked(value)

iterator items*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P): uint64 =
  ## forward permutationの値をindex順にiterateします。
  for index in 0'i64..<permutation.n:
    yield permutation.values[index]

func toSeq*[P: SuccinctPermutation | SuccinctPermutationView](
    permutation: P): seq[uint64] =
  ## forward permutationをunpackedなsequenceへdecodeします。
  result = newSeq[uint64](int(permutation.n))
  for index in 0'i64..<permutation.n:
    result[int(index)] = permutation.values[index]
