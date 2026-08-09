## Path-compressed Radix Trieのcompactな不変表現。
##
## nodeはDFS preorder、edge labelと子一覧は連続領域へ格納します。

import std/[algorithm, bitops, strutils]
import packed_array, succinct_bit_vector

type
  SuccinctRadixTrie* = object
    ## byte列の完全一致、前方一致、IDからの復元を提供します。
    firstChild*: PackedArray         ## `childNodes`内の子一覧開始位置。
    childCount*: PackedArray         ## nodeごとの直接の子の数。
    childNodes*: PackedArray         ## 直接の子node IDを格納する連続領域。
    parent*: PackedArray             ## nodeから親nodeへのmapping。
    subtreeEnd*: PackedArray         ## DFS部分木の排他的終端node ID。
    edgeFirstBytes*: seq[byte]       ## root以外のedge label先頭byte。
    edgeSuffixBytes*: seq[byte]      ## edge labelの2 byte目以降を連結した領域。
    edgeSuffixOffsets*: PackedArray ## edge suffixの開始offset。末尾番兵を含みます。
    terminalBits*: SuccinctBitVector ## terminal nodeを示すbit vector。
    terminalIds*: PackedArray        ## terminal DFS順のDictionary ID。
    idToTerminal*: PackedArray       ## Dictionary IDからterminal nodeへのmapping。

  RadixTrieStats* = object
    ## Radix Trieの構造統計を表します。
    nodeCount*, edgeCount*, terminalCount*: int64
    totalEdgeLabelBytes*: int64
    averageEdgeLabelLength*: float
    maximumEdgeLabelLength*: int64
    averageTerminalDepth*: float
    maximumDepth*: int64
    degreeZeroCount*, degreeOneCount*: int64
    degreeTwoToFourCount*, degreeFiveToSixteenCount*: int64
    degreeSeventeenOrMoreCount*: int64

  RadixTrieMemoryUsage* = object
    ## Radix Trieの論理的な格納容量内訳をbyte単位で表します。
    topologyBytes*, edgeFirstBytes*, edgeSuffixBytes*: int64
    edgeBoundaryBytes*, terminalBitsBytes*, terminalIdsBytes*: int64
    idToTerminalBytes*, childNavigationBytes*, totalBytes*: int64

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
  var terminalCount = 0
  var maximumDegree = 0
  for node in nodes:
    childTotal += node.children.len
    maximumDegree = max(maximumDegree, node.children.len)
    if node.label.len > 0:
      suffixTotal += node.label.len - 1
    if node.terminalId >= 0:
      inc terminalCount

  result.firstChild = genPackedArray(nodeCount,
    requiredBitWidth(uint64(childTotal)))
  result.childCount = genPackedArray(nodeCount,
    requiredBitWidth(uint64(maximumDegree)))
  result.childNodes = genPackedArray(childTotal,
    requiredBitWidth(uint64(max(0, nodeCount - 1))))
  result.parent = genPackedArray(nodeCount,
    requiredBitWidth(uint64(max(0, nodeCount - 1))))
  result.subtreeEnd = genPackedArray(nodeCount,
    requiredBitWidth(uint64(nodeCount)))
  result.edgeFirstBytes = newSeq[byte](nodeCount)
  result.edgeSuffixBytes = newSeq[byte](suffixTotal)
  result.edgeSuffixOffsets = genPackedArray(nodeCount + 1,
    requiredBitWidth(uint64(suffixTotal)))
  result.terminalBits = genSuccinctBitVector(int64(nodeCount))
  result.terminalIds = genPackedArray(terminalCount,
    requiredBitWidth(uint64(strings.len)))
  result.idToTerminal = genPackedArray(strings.len,
    requiredBitWidth(uint64(max(0, nodeCount - 1))))

  var childPosition = 0
  var suffixPosition = 0
  var terminalPosition = 0
  for flatNode, buildNode in order:
    let node = nodes[buildNode]
    result.firstChild[flatNode] = uint64(childPosition)
    result.childCount[flatNode] = uint64(node.children.len)
    for child in node.children:
      result.childNodes[childPosition] = uint64(buildToFlat[child])
      inc childPosition
    result.parent[flatNode] = if node.parent < 0: 0'u64
      else: uint64(buildToFlat[node.parent])
    result.subtreeEnd[flatNode] = uint64(subtreeEnds[flatNode])
    result.edgeSuffixOffsets[flatNode] = uint64(suffixPosition)
    if node.label.len > 0:
      result.edgeFirstBytes[flatNode] = byte(node.label[0])
      for index in 1..<node.label.len:
        result.edgeSuffixBytes[suffixPosition] = byte(node.label[index])
        inc suffixPosition
    if node.terminalId >= 0:
      result.terminalBits.setBit(int64(flatNode))
      result.terminalIds[terminalPosition] = uint64(node.terminalId)
      inc terminalPosition
  result.edgeSuffixOffsets[nodeCount] = uint64(suffixPosition)
  result.terminalBits.build()
  for dictionaryId, buildNode in idToBuildNode:
    result.idToTerminal[dictionaryId] = uint64(buildToFlat[buildNode])

func edgeSuffixStart(trie: SuccinctRadixTrie, node: int): int {.inline.} =
  int(trie.edgeSuffixOffsets.getUnchecked(node))

func edgeSuffixEnd(trie: SuccinctRadixTrie, node: int): int {.inline.} =
  int(trie.edgeSuffixOffsets.getUnchecked(node + 1))

func findChild(trie: SuccinctRadixTrie, node: int, firstByte: byte): int =
  let first = int(trie.firstChild.getUnchecked(node))
  let count = int(trie.childCount.getUnchecked(node))
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
    let suffixStart = trie.edgeSuffixStart(child)
    let suffixEnd = trie.edgeSuffixEnd(child)
    for suffixPosition in suffixStart..<suffixEnd:
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
      not trie.terminalBits.access(int64(traversal.node)):
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
  let firstOrdinal = trie.terminalBits.rank1(int64(traversal.node))
  let endNode = int(trie.subtreeEnd.getUnchecked(traversal.node))
  let endOrdinal = trie.terminalBits.rank1(int64(endNode))
  for ordinal in firstOrdinal..<endOrdinal:
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
    length += 1 + trie.edgeSuffixEnd(current) - trie.edgeSuffixStart(current)
    current = int(trie.parent.getUnchecked(current))
  output.setLen(length)
  var writePosition = length
  while node != 0:
    let suffixStart = trie.edgeSuffixStart(node)
    let suffixEnd = trie.edgeSuffixEnd(node)
    let edgeLength = 1 + suffixEnd - suffixStart
    writePosition -= edgeLength
    output[writePosition] = char(trie.edgeFirstBytes[node])
    for offset in 0..<suffixEnd - suffixStart:
      output[writePosition + 1 + offset] =
        char(trie.edgeSuffixBytes[suffixStart + offset])
    node = int(trie.parent.getUnchecked(node))

proc getString*(trie: SuccinctRadixTrie, id: uint32): string =
  ## Dictionary IDから元の文字列を復元します。
  trie.getStringInto(id, result)

func packedBytes(values: PackedArray): int64 {.inline.} =
  int64(values.data.len) * int64(sizeof(uint64))

func succinctBytes(values: SuccinctBitVector): int64 =
  int64(values.data.len + values.selectStorage.len) * int64(sizeof(uint64)) +
    int64(values.blockPairPrefix.len + values.wordPairPrefix.len) *
      int64(sizeof(uint32))

func memoryUsage*(trie: SuccinctRadixTrie): RadixTrieMemoryUsage =
  ## Radix Trieが所有する各構造の論理的な格納容量を返します。
  result.topologyBytes = packedBytes(trie.parent) + packedBytes(trie.subtreeEnd)
  result.edgeFirstBytes = int64(trie.edgeFirstBytes.len)
  result.edgeSuffixBytes = int64(trie.edgeSuffixBytes.len)
  result.edgeBoundaryBytes = packedBytes(trie.edgeSuffixOffsets)
  result.terminalBitsBytes = succinctBytes(trie.terminalBits)
  result.terminalIdsBytes = packedBytes(trie.terminalIds)
  result.idToTerminalBytes = packedBytes(trie.idToTerminal)
  result.childNavigationBytes = packedBytes(trie.firstChild) +
    packedBytes(trie.childCount) + packedBytes(trie.childNodes)
  result.totalBytes = result.topologyBytes + result.edgeFirstBytes +
    result.edgeSuffixBytes + result.edgeBoundaryBytes +
    result.terminalBitsBytes + result.terminalIdsBytes +
    result.idToTerminalBytes + result.childNavigationBytes

func stats*(trie: SuccinctRadixTrie): RadixTrieStats =
  ## node数、edge長、terminal depth、degree分布を集計して返します。
  result.nodeCount = int64(trie.edgeFirstBytes.len)
  result.edgeCount = max(0'i64, result.nodeCount - 1)
  result.terminalCount = trie.terminalBits.totalOnes
  var depthSum = 0'i64
  var depths = newSeq[int64](int(result.nodeCount))
  for node in 0..<int(result.nodeCount):
    let suffixLength = trie.edgeSuffixEnd(node) - trie.edgeSuffixStart(node)
    if node > 0:
      let labelLength = int64(1 + suffixLength)
      result.totalEdgeLabelBytes += labelLength
      result.maximumEdgeLabelLength = max(result.maximumEdgeLabelLength,
        labelLength)
      let parent = int(trie.parent.getUnchecked(node))
      depths[node] = depths[parent] + 1
    if trie.terminalBits.access(int64(node)):
      depthSum += depths[node]
      result.maximumDepth = max(result.maximumDepth, depths[node])
    let degree = int(trie.childCount.getUnchecked(node))
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
