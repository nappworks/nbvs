## Path-compressed Radix Trieのcompactな不変表現。
##
## nodeはDFS preorder、edge labelと子一覧は連続領域へ格納します。

import std/[algorithm, bitops, math, strutils]
import packed_array, succinct_bit_vector

type
  BlockPackedParents* = object
    ## 256 node単位のbit幅で `node - parent` を圧縮します。
    bitWidths*: seq[uint8]
    wordOffsets*: seq[uint32]
    data*: seq[uint64]

  SuccinctRadixTrie* = object
    ## byte列の完全一致、前方一致、IDからの復元を提供します。
    internalBits*: SuccinctBitVector    ## 子を持つnodeを示すbit vector。
    internalFirstChild*: PackedArray    ## internal nodeごとの子一覧開始位置。
    internalChildCount*: PackedArray    ## internal nodeごとの直接の子の数。
    childNodes*: PackedArray            ## 直接の子node IDを格納する連続領域。
    parents*: BlockPackedParents        ## nodeから親nodeへのdelta圧縮mapping。
    edgeFirstBytes*: seq[byte]          ## root以外のedge label先頭byte。
    edgeSuffixBytes*: seq[byte]         ## edge labelの2 byte目以降を連結した領域。
    sparseSuffixes*: bool ## suffixが疎な場合にsparse metadataを使います。
    hasSuffixBits*: SuccinctBitVector   ## suffixを持つedgeを示すbit vector。
    edgeSuffixOffsets*: PackedArray ## adaptiveなsuffix offset。末尾番兵を含みます。
    terminalBits*: SuccinctBitVector    ## terminal nodeを示すbit vector。
    terminalIds*: PackedArray           ## terminal DFS順のDictionary ID。
    idToTerminal*: PackedArray          ## Dictionary IDからterminal nodeへのmapping。
    internalFirstTerminal*: PackedArray ## internal部分木の先頭terminal ordinal。
    internalTerminalCount*: PackedArray ## internal部分木のterminal数。

  RadixTrieStats* = object
    ## Radix Trieの構造統計を表します。
    nodeCount*, edgeCount*, terminalCount*: int64
    totalEdgeLabelBytes*: int64
    averageEdgeLabelLength*: float
    maximumEdgeLabelLength*: int64
    averageTerminalDepth*: float
    maximumDepth*: int64
    internalNodeCount*: int64
    leafRatio*: float
    suffixBearingEdgeCount*: int64
    suffixBearingEdgeRatio*: float
    parentDeltaAverage*, parentDeltaMedian*: float
    parentDeltaP90*, parentDeltaP99*, parentDeltaMaximum*: int64
    parentDeltaBitWidthHistogram*: array[5, int64]
    suffixLengthHistogram*: array[5, int64]
    terminalIdCorrelation*: float
    degreeZeroCount*, degreeOneCount*: int64
    degreeTwoToFourCount*, degreeFiveToSixteenCount*: int64
    degreeSeventeenOrMoreCount*: int64

  RadixTrieMemoryUsage* = object
    ## Radix Trieの論理的な格納容量内訳をbyte単位で表します。
    topologyBytes*, edgeFirstBytes*, edgeSuffixBytes*: int64
    edgeBoundaryBytes*, terminalBitsBytes*, terminalIdsBytes*: int64
    idToTerminalBytes*, childNavigationBytes*, terminalRangeBytes*: int64
    totalBytes*: int64

  BuildNode = object
    label: string
    parent: int
    children: seq[int]
    terminalId: int64

  TraverseResult = object
    node: int
    atBoundary: bool

func requiredBitWidth(maximum: uint64): int {.inline.} =
  if maximum == 0: 0 else: 64 - countLeadingZeroBits(maximum)

func accessUnchecked(bits: SuccinctBitVector, node: int): bool {.inline.} =
  ## 呼び出し側は `node` がbit vector範囲内であることを保証する。
  (bits.data[node shr 6] and (1'u64 shl (node and 63))) != 0

const ParentBlockSize = 256

proc genBlockPackedParents(parents: openArray[int]): BlockPackedParents =
  let blockCount = (parents.len + ParentBlockSize - 1) div ParentBlockSize
  result.bitWidths = newSeq[uint8](blockCount)
  result.wordOffsets = newSeq[uint32](blockCount + 1)
  var totalWords = 0
  for blockIndex in 0..<blockCount:
    let first = blockIndex * ParentBlockSize
    let last = min(parents.len, first + ParentBlockSize)
    var maximumDelta = 0'u64
    for node in first..<last:
      maximumDelta = max(maximumDelta, uint64(node - parents[node]))
    let bitWidth = requiredBitWidth(maximumDelta)
    result.bitWidths[blockIndex] = uint8(bitWidth)
    result.wordOffsets[blockIndex] = uint32(totalWords)
    let totalBits = (last - first) * bitWidth
    totalWords += (totalBits + 63) div 64
  result.wordOffsets[blockCount] = uint32(totalWords)
  result.data = newSeq[uint64](totalWords)
  for node, parent in parents:
    let blockIndex = node div ParentBlockSize
    let local = node mod ParentBlockSize
    let bitWidth = int(result.bitWidths[blockIndex])
    if bitWidth == 0:
      continue
    let delta = uint64(node - parent)
    let bitPosition = local * bitWidth
    let word = int(result.wordOffsets[blockIndex]) + (bitPosition shr 6)
    let offset = bitPosition and 63
    result.data[word] = result.data[word] or (delta shl offset)
    if offset + bitWidth > 64:
      result.data[word + 1] = result.data[word + 1] or
        (delta shr (64 - offset))

func parentAt*(parents: BlockPackedParents, node: int): int {.inline.} =
  ## 指定nodeの親node IDを返します。rootの親はroot自身です。
  let blockIndex = node div ParentBlockSize
  let bitWidth = int(parents.bitWidths[blockIndex])
  if bitWidth == 0:
    return node
  let bitPosition = (node mod ParentBlockSize) * bitWidth
  let word = int(parents.wordOffsets[blockIndex]) + (bitPosition shr 6)
  let offset = bitPosition and 63
  var delta = parents.data[word] shr offset
  if offset + bitWidth > 64:
    delta = delta or (parents.data[word + 1] shl (64 - offset))
  delta = delta and maskForWidth(bitWidth)
  node - int(delta)

func parentAt*(trie: SuccinctRadixTrie, node: int): int {.inline.} =
  ## 指定nodeの親node IDを返します。
  trie.parents.parentAt(node)

func commonPrefixLength(left, right: string): int {.inline.} =
  let limit = min(left.len, right.len)
  while result < limit and left[result] == right[result]:
    inc result

proc insert(nodes: var seq[BuildNode], value: string, dictionaryId: int) =
  var node = 0
  var position = 0
  while position < value.len:
    var matchingChild = -1
    for child in nodes[node].children:
      if nodes[child].label[0] == value[position]:
        matchingChild = child
        break
    if matchingChild < 0:
      let leaf = nodes.len
      nodes.add BuildNode(label: value[position..^1], parent: node,
        terminalId: int64(dictionaryId))
      nodes[node].children.add leaf
      return

    let remainder = value[position..^1]
    let shared = commonPrefixLength(nodes[matchingChild].label, remainder)
    if shared == nodes[matchingChild].label.len:
      position += shared
      node = matchingChild
      continue

    let oldLabel = nodes[matchingChild].label
    let branch = nodes.len
    nodes.add BuildNode(label: oldLabel[0..<shared], parent: node,
      children: @[matchingChild], terminalId: -1)
    for index, child in nodes[node].children.mpairs:
      if child == matchingChild:
        child = branch
        break
    nodes[matchingChild].label = oldLabel[shared..^1]
    nodes[matchingChild].parent = branch
    position += shared
    if position == value.len:
      nodes[branch].terminalId = int64(dictionaryId)
    else:
      let leaf = nodes.len
      nodes.add BuildNode(label: value[position..^1], parent: branch,
        terminalId: int64(dictionaryId))
      nodes[branch].children.add leaf
    return

  # 重複検査を省略した場合、完全一致は最初のIDを返し、各IDは同じterminalを参照する。
  if nodes[node].terminalId < 0:
    nodes[node].terminalId = int64(dictionaryId)

proc genSuccinctRadixTrie*(strings: openArray[string]): SuccinctRadixTrie =
  ## 入力順のDictionary IDを維持したpath-compressed Radix Trieを構築します。
  ##
  ## 文字列はUTF-8文字ではなく任意のbyte列として扱います。構築時間と一時領域は
  ## edge探索を除いて `O(n)` です。完成後のTrieはimmutableです。
  var nodes = @[BuildNode(parent: -1, terminalId: -1)]
  var idToBuildNode = newSeq[int](strings.len)
  for dictionaryId, value in strings:
    nodes.insert(value, dictionaryId)
    # terminalは後続の挿入によるedge split後も同じBuildNodeに残る。
    var current = 0
    var position = 0
    while position < value.len:
      for child in nodes[current].children:
        if value.continuesWith(nodes[child].label, position):
          position += nodes[child].label.len
          current = child
          break
    idToBuildNode[dictionaryId] = current

  for node in nodes.mitems:
    node.children.sort(proc(left, right: int): int =
      cmp(nodes[left].label[0], nodes[right].label[0]))

  var order = newSeqOfCap[int](nodes.len)
  var stack = @[0]
  while stack.len > 0:
    let current = stack.pop()
    order.add current
    for index in countdown(nodes[current].children.high, 0):
      stack.add nodes[current].children[index]

  var buildToFlat = newSeq[int](nodes.len)
  for flatNode, buildNode in order:
    buildToFlat[buildNode] = flatNode

  let nodeCount = nodes.len
  var subtreeEnds = newSeq[int](nodeCount)
  for flatNode in countdown(nodeCount - 1, 0):
    subtreeEnds[flatNode] = max(subtreeEnds[flatNode], flatNode + 1)
    let buildNode = order[flatNode]
    if nodes[buildNode].parent >= 0:
      let flatParent = buildToFlat[nodes[buildNode].parent]
      subtreeEnds[flatParent] = max(subtreeEnds[flatParent], subtreeEnds[flatNode])

  var childTotal = 0
  var suffixTotal = 0
  var suffixBearingCount = 0
  var terminalCount = 0
  var internalCount = 0
  var maximumDegree = 0
  for node in nodes:
    childTotal += node.children.len
    maximumDegree = max(maximumDegree, node.children.len)
    if node.children.len > 0:
      inc internalCount
    if node.label.len > 0:
      suffixTotal += node.label.len - 1
      if node.label.len > 1:
        inc suffixBearingCount
    if node.terminalId >= 0:
      inc terminalCount

  var terminalPrefixes = newSeq[int](nodeCount + 1)
  for flatNode, buildNode in order:
    terminalPrefixes[flatNode + 1] = terminalPrefixes[flatNode]
    if nodes[buildNode].terminalId >= 0:
      inc terminalPrefixes[flatNode + 1]

  result.internalBits = genSuccinctBitVector(int64(nodeCount))
  result.internalFirstChild = genPackedArray(internalCount,
    requiredBitWidth(uint64(childTotal)))
  result.internalChildCount = genPackedArray(internalCount,
    requiredBitWidth(uint64(maximumDegree)))
  result.childNodes = genPackedArray(childTotal,
    requiredBitWidth(uint64(max(0, nodeCount - 1))))
  result.edgeFirstBytes = newSeq[byte](nodeCount)
  result.edgeSuffixBytes = newSeq[byte](suffixTotal)
  result.sparseSuffixes = suffixBearingCount * 4 <= nodeCount
  if result.sparseSuffixes:
    result.hasSuffixBits = genSuccinctBitVector(int64(nodeCount))
  let suffixOffsetCount = if result.sparseSuffixes:
    suffixBearingCount + 1
  else:
    nodeCount + 1
  result.edgeSuffixOffsets = genPackedArray(suffixOffsetCount,
    requiredBitWidth(uint64(suffixTotal)))
  result.terminalBits = genSuccinctBitVector(int64(nodeCount))
  result.terminalIds = genPackedArray(terminalCount,
    requiredBitWidth(uint64(strings.len)))
  result.idToTerminal = genPackedArray(strings.len,
    requiredBitWidth(uint64(max(0, nodeCount - 1))))
  result.internalFirstTerminal = genPackedArray(internalCount,
    requiredBitWidth(uint64(terminalCount)))
  result.internalTerminalCount = genPackedArray(internalCount,
    requiredBitWidth(uint64(terminalCount)))

  var childPosition = 0
  var suffixPosition = 0
  var suffixBearingPosition = 0
  var terminalPosition = 0
  var internalPosition = 0
  var flatParents = newSeq[int](nodeCount)
  for flatNode, buildNode in order:
    let node = nodes[buildNode]
    if node.children.len > 0:
      result.internalBits.setBit(int64(flatNode))
      result.internalFirstChild[internalPosition] = uint64(childPosition)
      result.internalChildCount[internalPosition] = uint64(node.children.len)
      let firstTerminal = terminalPrefixes[flatNode]
      let subtreeTerminalCount =
        terminalPrefixes[subtreeEnds[flatNode]] - firstTerminal
      result.internalFirstTerminal[internalPosition] = uint64(firstTerminal)
      result.internalTerminalCount[internalPosition] =
        uint64(subtreeTerminalCount)
      inc internalPosition
    for child in node.children:
      result.childNodes[childPosition] = uint64(buildToFlat[child])
      inc childPosition
    flatParents[flatNode] = if node.parent < 0: 0
      else: buildToFlat[node.parent]
    if not result.sparseSuffixes:
      result.edgeSuffixOffsets[flatNode] = uint64(suffixPosition)
    if node.label.len > 0:
      result.edgeFirstBytes[flatNode] = byte(node.label[0])
      if node.label.len > 1:
        if result.sparseSuffixes:
          result.hasSuffixBits.setBit(int64(flatNode))
          result.edgeSuffixOffsets[suffixBearingPosition] = uint64(suffixPosition)
        for index in 1..<node.label.len:
          result.edgeSuffixBytes[suffixPosition] = byte(node.label[index])
          inc suffixPosition
        inc suffixBearingPosition
    if node.terminalId >= 0:
      result.terminalBits.setBit(int64(flatNode))
      result.terminalIds[terminalPosition] = uint64(node.terminalId)
      inc terminalPosition
  result.edgeSuffixOffsets[suffixOffsetCount - 1] = uint64(suffixPosition)
  result.internalBits.build()
  if result.sparseSuffixes:
    result.hasSuffixBits.build()
  result.terminalBits.build()
  result.parents = genBlockPackedParents(flatParents)
  for dictionaryId, buildNode in idToBuildNode:
    result.idToTerminal[dictionaryId] = uint64(buildToFlat[buildNode])

func internalIndex(trie: SuccinctRadixTrie, node: int): int {.inline.} =
  if not trie.internalBits.accessUnchecked(node):
    return -1
  int(trie.internalBits.rank1Unchecked(int64(node)))

func childCountAt*(trie: SuccinctRadixTrie, node: int): int {.inline.} =
  ## 指定nodeの直接の子の数を返します。
  let index = trie.internalIndex(node)
  if index < 0: 0
  else: int(trie.internalChildCount.getUnchecked(index))

func firstChildOffset*(trie: SuccinctRadixTrie, node: int): int {.inline.} =
  ## internal nodeの `childNodes` 内の開始位置を返します。
  ##
  ## leafの場合は `-1` を返します。
  let index = trie.internalIndex(node)
  if index < 0: -1
  else: int(trie.internalFirstChild.getUnchecked(index))

func edgeSuffixRange*(trie: SuccinctRadixTrie,
                      node: int): tuple[first, last: int] {.inline.} =
  ## 指定nodeへ入るedgeのsuffix範囲を返します。
  if not trie.sparseSuffixes:
    return (first: int(trie.edgeSuffixOffsets.getUnchecked(node)),
      last: int(trie.edgeSuffixOffsets.getUnchecked(node + 1)))
  if not trie.hasSuffixBits.accessUnchecked(node):
    return (first: 0, last: 0)
  let ordinal = int(trie.hasSuffixBits.rank1Unchecked(int64(node)))
  result.first = int(trie.edgeSuffixOffsets.getUnchecked(ordinal))
  result.last = int(trie.edgeSuffixOffsets.getUnchecked(ordinal + 1))

func findChild(trie: SuccinctRadixTrie, node: int, firstByte: byte): int =
  let internal = trie.internalIndex(node)
  if internal < 0:
    return -1
  let first = int(trie.internalFirstChild.getUnchecked(internal))
  let count = int(trie.internalChildCount.getUnchecked(internal))
  if count <= 4:
    for offset in 0..<count:
      let child = int(trie.childNodes.getUnchecked(first + offset))
      if trie.edgeFirstBytes[child] == firstByte:
        return child
    return -1
  var left = first
  var right = first + count
  while left < right:
    let middle = (left + right) shr 1
    let child = int(trie.childNodes.getUnchecked(middle))
    if trie.edgeFirstBytes[child] < firstByte:
      left = middle + 1
    else:
      right = middle
  if left < first + count:
    let child = int(trie.childNodes.getUnchecked(left))
    if trie.edgeFirstBytes[child] == firstByte:
      return child
  -1

func traversePattern(trie: SuccinctRadixTrie, pattern: string): TraverseResult =
  result = TraverseResult(node: 0, atBoundary: true)
  var position = 0
  while position < pattern.len:
    let child = trie.findChild(result.node, byte(pattern[position]))
    if child < 0:
      return TraverseResult(node: -1)
    inc position
    let suffix = trie.edgeSuffixRange(child)
    for suffixPosition in suffix.first..<suffix.last:
      if position == pattern.len:
        return TraverseResult(node: child, atBoundary: false)
      if byte(pattern[position]) != trie.edgeSuffixBytes[suffixPosition]:
        return TraverseResult(node: -1)
      inc position
    result = TraverseResult(node: child, atBoundary: true)

func findExact*(trie: SuccinctRadixTrie, value: string): int64 =
  ## 完全一致するDictionary IDを返し、存在しない場合は `-1` を返します。
  let traversal = trie.traversePattern(value)
  if traversal.node < 0 or not traversal.atBoundary or
      not trie.terminalBits.accessUnchecked(traversal.node):
    return -1
  let ordinal = trie.terminalBits.rank1(int64(traversal.node))
  int64(trie.terminalIds.getUnchecked(int(ordinal)))

proc findPrefixInto*(trie: SuccinctRadixTrie, prefix: string,
                     output: var seq[uint32]) =
  ## byte単位で前方一致するDictionary IDを昇順で `output` へ格納します。
  output.setLen(0)
  let traversal = trie.traversePattern(prefix)
  if traversal.node < 0:
    return
  var firstOrdinal, terminalCount: int64
  let internal = trie.internalIndex(traversal.node)
  if internal >= 0:
    firstOrdinal = int64(trie.internalFirstTerminal.getUnchecked(internal))
    terminalCount = int64(trie.internalTerminalCount.getUnchecked(internal))
  elif trie.terminalBits.accessUnchecked(traversal.node):
    firstOrdinal = trie.terminalBits.rank1Unchecked(int64(traversal.node))
    terminalCount = 1
  else:
    return
  for ordinal in firstOrdinal..<firstOrdinal + terminalCount:
    output.add uint32(trie.terminalIds.getUnchecked(int(ordinal)))
  output.sort()

proc getStringInto*(trie: SuccinctRadixTrie, id: uint32,
                    output: var string) =
  ## Dictionary IDから文字列を復元し、既存の `output` capacityを再利用します。
  if int64(id) >= trie.idToTerminal.len:
    raise newException(IndexDefect, "dictionary ID out of range")
  var node = int(trie.idToTerminal.getUnchecked(int(id)))
  var length = 0
  var current = node
  while current != 0:
    let suffix = trie.edgeSuffixRange(current)
    length += 1 + suffix.last - suffix.first
    current = trie.parentAt(current)
  output.setLen(length)
  var writePosition = length
  while node != 0:
    let suffix = trie.edgeSuffixRange(node)
    let edgeLength = 1 + suffix.last - suffix.first
    writePosition -= edgeLength
    output[writePosition] = char(trie.edgeFirstBytes[node])
    for offset in 0..<suffix.last - suffix.first:
      output[writePosition + 1 + offset] =
        char(trie.edgeSuffixBytes[suffix.first + offset])
    node = trie.parentAt(node)

proc getString*(trie: SuccinctRadixTrie, id: uint32): string =
  ## Dictionary IDから元の文字列を復元します。
  trie.getStringInto(id, result)

func packedBytes(values: PackedArray): int64 {.inline.} =
  int64(values.data.len) * int64(sizeof(uint64))

func succinctBytes(values: SuccinctBitVector): int64 =
  int64(values.data.len + values.selectStorage.len) * int64(sizeof(uint64)) +
    int64(values.blockPairPrefix.len + values.wordPairPrefix.len) *
      int64(sizeof(uint32))

func parentBytes(values: BlockPackedParents): int64 =
  int64(values.bitWidths.len) + int64(values.wordOffsets.len) * 4 +
    int64(values.data.len) * 8

func memoryUsage*(trie: SuccinctRadixTrie): RadixTrieMemoryUsage =
  ## Radix Trieが所有する各構造の論理的な格納容量を返します。
  result.topologyBytes = parentBytes(trie.parents)
  result.edgeFirstBytes = int64(trie.edgeFirstBytes.len)
  result.edgeSuffixBytes = int64(trie.edgeSuffixBytes.len)
  result.edgeBoundaryBytes = succinctBytes(trie.hasSuffixBits) +
    packedBytes(trie.edgeSuffixOffsets)
  result.terminalBitsBytes = succinctBytes(trie.terminalBits)
  result.terminalIdsBytes = packedBytes(trie.terminalIds)
  result.idToTerminalBytes = packedBytes(trie.idToTerminal)
  result.childNavigationBytes = succinctBytes(trie.internalBits) +
    packedBytes(trie.internalFirstChild) +
    packedBytes(trie.internalChildCount) + packedBytes(trie.childNodes)
  result.terminalRangeBytes = packedBytes(trie.internalFirstTerminal) +
    packedBytes(trie.internalTerminalCount)
  result.totalBytes = result.topologyBytes + result.edgeFirstBytes +
    result.edgeSuffixBytes + result.edgeBoundaryBytes +
    result.terminalBitsBytes + result.terminalIdsBytes +
    result.idToTerminalBytes + result.childNavigationBytes +
    result.terminalRangeBytes

func stats*(trie: SuccinctRadixTrie): RadixTrieStats =
  ## node数、edge長、terminal depth、degree分布を集計して返します。
  result.nodeCount = int64(trie.edgeFirstBytes.len)
  result.edgeCount = max(0'i64, result.nodeCount - 1)
  result.terminalCount = trie.terminalBits.totalOnes
  var depthSum = 0'i64
  var depths = newSeq[int64](int(result.nodeCount))
  var parentDeltas = newSeqOfCap[int64](max(0, int(result.nodeCount) - 1))
  var terminalOrdinal = 0'i64
  var sumOrdinal, sumId, sumOrdinalSquared, sumIdSquared, sumProduct: float
  for node in 0..<int(result.nodeCount):
    let suffix = trie.edgeSuffixRange(node)
    let suffixLength = suffix.last - suffix.first
    if node > 0:
      let labelLength = int64(1 + suffixLength)
      result.totalEdgeLabelBytes += labelLength
      result.maximumEdgeLabelLength = max(result.maximumEdgeLabelLength,
        labelLength)
      let parent = trie.parentAt(node)
      depths[node] = depths[parent] + 1
      let delta = int64(node - parent)
      parentDeltas.add delta
      let bitWidth = requiredBitWidth(uint64(delta))
      if bitWidth <= 4: inc result.parentDeltaBitWidthHistogram[0]
      elif bitWidth <= 8: inc result.parentDeltaBitWidthHistogram[1]
      elif bitWidth <= 12: inc result.parentDeltaBitWidthHistogram[2]
      elif bitWidth <= 16: inc result.parentDeltaBitWidthHistogram[3]
      else: inc result.parentDeltaBitWidthHistogram[4]
    if suffixLength == 0: inc result.suffixLengthHistogram[0]
    elif suffixLength <= 4: inc result.suffixLengthHistogram[1]
    elif suffixLength <= 8: inc result.suffixLengthHistogram[2]
    elif suffixLength <= 16: inc result.suffixLengthHistogram[3]
    else: inc result.suffixLengthHistogram[4]
    if suffixLength > 0:
      inc result.suffixBearingEdgeCount
    if trie.terminalBits.accessUnchecked(node):
      depthSum += depths[node]
      result.maximumDepth = max(result.maximumDepth, depths[node])
      let dictionaryId = float(trie.terminalIds.getUnchecked(
        int(terminalOrdinal)))
      let ordinal = float(terminalOrdinal)
      sumOrdinal += ordinal
      sumId += dictionaryId
      sumOrdinalSquared += ordinal * ordinal
      sumIdSquared += dictionaryId * dictionaryId
      sumProduct += ordinal * dictionaryId
      inc terminalOrdinal
    let degree = trie.childCountAt(node)
    case degree
    of 0: inc result.degreeZeroCount
    of 1: inc result.degreeOneCount
    of 2..4: inc result.degreeTwoToFourCount
    of 5..16: inc result.degreeFiveToSixteenCount
    else: inc result.degreeSeventeenOrMoreCount
  if result.edgeCount > 0:
    result.averageEdgeLabelLength =
      float(result.totalEdgeLabelBytes) / float(result.edgeCount)
  if result.terminalCount > 0:
    result.averageTerminalDepth =
      float(depthSum) / float(result.terminalCount)
    let count = float(result.terminalCount)
    let numerator = count * sumProduct - sumOrdinal * sumId
    let denominator = sqrt((count * sumOrdinalSquared - sumOrdinal *
      sumOrdinal) * (count * sumIdSquared - sumId * sumId))
    if denominator > 0:
      result.terminalIdCorrelation = numerator / denominator
  result.internalNodeCount = trie.internalBits.totalOnes
  if result.nodeCount > 0:
    result.leafRatio =
      float(result.nodeCount - result.internalNodeCount) / float(
          result.nodeCount)
  if result.edgeCount > 0:
    result.suffixBearingEdgeRatio =
      float(result.suffixBearingEdgeCount) / float(result.edgeCount)
  if parentDeltas.len > 0:
    parentDeltas.sort()
    var deltaSum = 0'i64
    for delta in parentDeltas:
      deltaSum += delta
    result.parentDeltaAverage = float(deltaSum) / float(parentDeltas.len)
    result.parentDeltaMedian = if (parentDeltas.len and 1) == 0:
      float(parentDeltas[parentDeltas.len div 2 - 1] +
        parentDeltas[parentDeltas.len div 2]) / 2.0
    else:
      float(parentDeltas[parentDeltas.len div 2])
    result.parentDeltaP90 = parentDeltas[
      min(parentDeltas.high, (parentDeltas.len * 90) div 100)]
    result.parentDeltaP99 = parentDeltas[
      min(parentDeltas.high, (parentDeltas.len * 99) div 100)]
    result.parentDeltaMaximum = parentDeltas[^1]
