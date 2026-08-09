## Path-compressed Radix Trieのcompactな不変表現。
##
## nodeはDFS preorder、edge labelと子一覧は連続領域へ格納します。

import std/[algorithm, bitops, math]
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
    highDegreeBitmapOffsets*: PackedArray ## 高degree nodeのbitmap番号+1。
    highDegreeBitmaps*: seq[uint64] ## degree 17以上だけが持つ256-bit bitmap。
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

  PrefixQueryWorkspace* = object
    ## 大きなprefix結果をID順へ整列するbitmap workspaceです。
    words: seq[uint64]
    touchedWords: seq[int]

  BuildNode = object
    parent: int32
    firstChild, nextSibling: int32
    sourceId, edgeStart, edgeLength: uint32
    terminalId: uint32 # 0は非terminal、Dictionary IDは+1で保持する。

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

iterator buildChildren(nodes: seq[BuildNode], node: int): int =
  var child = int(nodes[node].firstChild)
  while child >= 0:
    yield child
    child = int(nodes[child].nextSibling)

proc appendChild(nodes: var seq[BuildNode], parent, child: int) =
  if nodes[parent].firstChild < 0:
    nodes[parent].firstChild = int32(child)
  else:
    var last = int(nodes[parent].firstChild)
    while nodes[last].nextSibling >= 0:
      last = int(nodes[last].nextSibling)
    nodes[last].nextSibling = int32(child)

func buildChildCount(nodes: seq[BuildNode], parent: int): int =
  for _ in nodes.buildChildren(parent):
    inc result

proc sortedDictionaryIds(strings: openArray[string]): seq[uint32] =
  ## openArrayをclosure captureせず、IDだけをstable merge sortする。
  result = newSeq[uint32](strings.len)
  for id in 0..<strings.len:
    result[id] = uint32(id)
  var scratch = newSeq[uint32](strings.len)
  var width = 1
  while width < strings.len:
    var first = 0
    while first < strings.len:
      let middle = min(first + width, strings.len)
      let last = min(first + width * 2, strings.len)
      var left = first
      var right = middle
      for output in first..<last:
        if right >= last or (left < middle and
            (strings[int(result[left])] < strings[int(result[right])] or
             (strings[int(result[left])] == strings[int(result[right])] and
              result[left] <= result[right]))):
          scratch[output] = result[left]
          inc left
        else:
          scratch[output] = result[right]
          inc right
      first = last
    swap(result, scratch)
    width = width shl 1

proc buildSortedLcp(strings: openArray[string]): tuple[
    nodes: seq[BuildNode], idToBuildNode: seq[int]] =
  ## 辞書順と隣接LCPから、labelを参照だけで保持するflat topologyを構築する。
  let sortedIds = sortedDictionaryIds(strings)

  result.nodes = @[BuildNode(parent: -1, firstChild: -1,
    nextSibling: -1, sourceId: uint32.high)]
  result.idToBuildNode = newSeq[int](strings.len)
  var path = @[0]
  var previousId = -1
  var pathDepths = @[0'u32]
  for encodedId in sortedIds:
    let dictionaryId = int(encodedId)
    let value = strings[dictionaryId]
    let lcp = if previousId < 0: 0
      else: commonPrefixLength(strings[previousId], value)
    var splitChild = -1
    while int(pathDepths[^1]) > lcp:
      splitChild = path.pop()
      discard pathDepths.pop()
    if int(pathDepths[^1]) < lcp:
      let parent = path[^1]
      doAssert splitChild >= 0
      let branch = result.nodes.len
      result.nodes.add BuildNode(parent: int32(parent),
        firstChild: int32(splitChild), nextSibling: -1,
        sourceId: uint32(previousId),
        edgeStart: pathDepths[^1],
        edgeLength: uint32(lcp - int(pathDepths[^1])))
      if int(result.nodes[parent].firstChild) == splitChild:
        result.nodes[parent].firstChild = int32(branch)
      else:
        var previousSibling = int(result.nodes[parent].firstChild)
        while int(result.nodes[previousSibling].nextSibling) != splitChild:
          previousSibling = int(result.nodes[previousSibling].nextSibling)
        result.nodes[previousSibling].nextSibling = int32(branch)
      result.nodes[branch].nextSibling = result.nodes[splitChild].nextSibling
      result.nodes[splitChild].nextSibling = -1
      result.nodes[splitChild].parent = int32(branch)
      let consumed = uint32(lcp - int(pathDepths[^1]))
      result.nodes[splitChild].edgeStart += consumed
      result.nodes[splitChild].edgeLength -= consumed
      path.add branch
      pathDepths.add uint32(lcp)
    let parent = path[^1]
    if value.len == lcp:
      if result.nodes[parent].terminalId == 0:
        result.nodes[parent].terminalId = uint32(dictionaryId + 1)
      result.idToBuildNode[dictionaryId] = parent
    else:
      let leaf = result.nodes.len
      result.nodes.add BuildNode(parent: int32(parent), firstChild: -1,
        nextSibling: -1, sourceId: uint32(dictionaryId),
        edgeStart: uint32(lcp), edgeLength: uint32(value.len - lcp),
        terminalId: uint32(dictionaryId + 1))
      result.nodes.appendChild(parent, leaf)
      path.add leaf
      pathDepths.add uint32(value.len)
      result.idToBuildNode[dictionaryId] = leaf
    previousId = dictionaryId

proc genSuccinctRadixTrie*(strings: openArray[string]): SuccinctRadixTrie =
  ## 入力順のDictionary IDを維持したpath-compressed Radix Trieを構築します。
  ##
  ## 文字列はUTF-8文字ではなく任意のbyte列として扱います。構築時間と一時領域は
  ## edge探索を除いて `O(n)` です。完成後のTrieはimmutableです。
  var (nodes, idToBuildNode) = buildSortedLcp(strings)

  var order = newSeqOfCap[uint32](nodes.len)
  var stack = @[0]
  var reverseChildren = newSeqOfCap[int](256)
  while stack.len > 0:
    let current = stack.pop()
    order.add uint32(current)
    reverseChildren.setLen(0)
    for child in nodes.buildChildren(current):
      reverseChildren.add child
    for index in countdown(reverseChildren.high, 0):
      stack.add reverseChildren[index]

  var buildToFlat = newSeq[uint32](nodes.len)
  for flatNode, buildNode in order:
    buildToFlat[int(buildNode)] = uint32(flatNode)

  let nodeCount = nodes.len
  var subtreeEnds = newSeq[uint32](nodeCount)
  for flatNode in countdown(nodeCount - 1, 0):
    subtreeEnds[flatNode] = max(subtreeEnds[flatNode], uint32(flatNode + 1))
    let buildNode = int(order[flatNode])
    if nodes[buildNode].parent >= 0:
      let flatParent = int(buildToFlat[int(nodes[buildNode].parent)])
      subtreeEnds[flatParent] = max(subtreeEnds[flatParent], subtreeEnds[flatNode])

  var childTotal = 0
  var suffixTotal = 0
  var suffixBearingCount = 0
  var terminalCount = 0
  var internalCount = 0
  var maximumDegree = 0
  var highDegreeCount = 0
  for nodeIndex, node in nodes:
    let childCount = nodes.buildChildCount(nodeIndex)
    childTotal += childCount
    maximumDegree = max(maximumDegree, childCount)
    if childCount > 0:
      inc internalCount
      if childCount >= 17:
        inc highDegreeCount
    if node.edgeLength > 0:
      suffixTotal += int(node.edgeLength) - 1
      if node.edgeLength > 1:
        inc suffixBearingCount
    if node.terminalId > 0:
      inc terminalCount

  var terminalPrefixes = newSeq[uint32](nodeCount + 1)
  for flatNode, buildNode in order:
    terminalPrefixes[flatNode + 1] = terminalPrefixes[flatNode]
    if nodes[int(buildNode)].terminalId > 0:
      inc terminalPrefixes[flatNode + 1]

  result.internalBits = genSuccinctBitVector(int64(nodeCount))
  result.internalFirstChild = genPackedArray(internalCount,
    requiredBitWidth(uint64(childTotal)))
  result.internalChildCount = genPackedArray(internalCount,
    requiredBitWidth(uint64(maximumDegree)))
  result.childNodes = genPackedArray(childTotal,
    requiredBitWidth(uint64(max(0, nodeCount - 1))))
  result.highDegreeBitmapOffsets = genPackedArray(internalCount,
    requiredBitWidth(uint64(highDegreeCount)))
  result.highDegreeBitmaps = newSeq[uint64](highDegreeCount * 4)
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
  var highDegreePosition = 0
  var flatParents = newSeq[int](nodeCount)
  for flatNode, buildNode in order:
    let buildNodeIndex = int(buildNode)
    let node = nodes[buildNodeIndex]
    let nodeChildCount = nodes.buildChildCount(buildNodeIndex)
    if nodeChildCount > 0:
      result.internalBits.setBit(int64(flatNode))
      result.internalFirstChild[internalPosition] = uint64(childPosition)
      result.internalChildCount[internalPosition] = uint64(nodeChildCount)
      let firstTerminal = terminalPrefixes[flatNode]
      let subtreeTerminalCount =
        terminalPrefixes[int(subtreeEnds[flatNode])] - firstTerminal
      result.internalFirstTerminal[internalPosition] = uint64(firstTerminal)
      result.internalTerminalCount[internalPosition] =
        uint64(subtreeTerminalCount)
      if nodeChildCount >= 17:
        result.highDegreeBitmapOffsets[internalPosition] =
          uint64(highDegreePosition + 1)
        for child in nodes.buildChildren(buildNodeIndex):
          let childNode = nodes[child]
          let firstByte = byte(strings[childNode.sourceId][childNode.edgeStart])
          let wordIndex = highDegreePosition * 4 + (int(firstByte) shr 6)
          result.highDegreeBitmaps[wordIndex] =
            result.highDegreeBitmaps[wordIndex] or
            (1'u64 shl (int(firstByte) and 63))
        inc highDegreePosition
      inc internalPosition
    for child in nodes.buildChildren(buildNodeIndex):
      result.childNodes[childPosition] = uint64(buildToFlat[child])
      inc childPosition
    flatParents[flatNode] = if node.parent < 0: 0
      else: int(buildToFlat[int(node.parent)])
    if not result.sparseSuffixes:
      result.edgeSuffixOffsets[flatNode] = uint64(suffixPosition)
    if node.edgeLength > 0:
      let source = strings[int(node.sourceId)]
      result.edgeFirstBytes[flatNode] = byte(source[int(node.edgeStart)])
      if node.edgeLength > 1:
        if result.sparseSuffixes:
          result.hasSuffixBits.setBit(int64(flatNode))
          result.edgeSuffixOffsets[suffixBearingPosition] = uint64(suffixPosition)
        for index in 1..<int(node.edgeLength):
          result.edgeSuffixBytes[suffixPosition] =
            byte(source[int(node.edgeStart) + index])
          inc suffixPosition
        inc suffixBearingPosition
    if node.terminalId > 0:
      result.terminalBits.setBit(int64(flatNode))
      result.terminalIds[terminalPosition] = uint64(node.terminalId - 1)
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
  if count >= 17:
    let encodedBitmap = int(
      trie.highDegreeBitmapOffsets.getUnchecked(internal))
    if encodedBitmap > 0:
      let bitmap = encodedBitmap - 1
      let targetWord = int(firstByte) shr 6
      let targetBit = int(firstByte) and 63
      let word = trie.highDegreeBitmaps[bitmap * 4 + targetWord]
      let mask = 1'u64 shl targetBit
      if (word and mask) == 0:
        return -1
      var ordinal = 0
      for wordIndex in 0..<targetWord:
        ordinal += countSetBits(
          trie.highDegreeBitmaps[bitmap * 4 + wordIndex])
      ordinal += countSetBits(word and (mask - 1))
      return int(trie.childNodes.getUnchecked(first + ordinal))
  template matches(offset: int): int =
    block:
      let child = int(trie.childNodes.getUnchecked(first + offset))
      if trie.edgeFirstBytes[child] == firstByte: child else: -1
  case count
  of 1:
    return matches(0)
  of 2:
    result = matches(0)
    if result < 0: result = matches(1)
    return
  of 3:
    result = matches(0)
    if result < 0: result = matches(1)
    if result < 0: result = matches(2)
    return
  of 4:
    result = matches(0)
    if result < 0: result = matches(1)
    if result < 0: result = matches(2)
    if result < 0: result = matches(3)
    return
  else: discard
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

proc findPrefixTrieOrderInto*(trie: SuccinctRadixTrie, prefix: string,
                              output: var seq[uint32]) =
  ## byte単位の前方一致IDをTrieのDFS順で格納します。
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

proc initPrefixQueryWorkspace*(dictionaryCount: int): PrefixQueryWorkspace =
  ## 指定件数向けのprefix bitmap workspaceを初期化します。
  if dictionaryCount < 0:
    raise newException(ValueError, "dictionary count must be non-negative")
  result.words = newSeq[uint64]((dictionaryCount + 63) shr 6)

proc findPrefixInto*(trie: SuccinctRadixTrie, prefix: string,
                     workspace: var PrefixQueryWorkspace,
                     output: var seq[uint32]) =
  ## workspaceを再利用し、前方一致IDを昇順で格納します。
  trie.findPrefixTrieOrderInto(prefix, output)
  if output.len < 256:
    output.sort()
    return
  let requiredWords = (int(trie.idToTerminal.len) + 63) shr 6
  if workspace.words.len != requiredWords:
    workspace = initPrefixQueryWorkspace(int(trie.idToTerminal.len))
  workspace.touchedWords.setLen(0)
  for id in output:
    let word = int(id) shr 6
    if workspace.words[word] == 0:
      workspace.touchedWords.add word
    workspace.words[word] = workspace.words[word] or
      (1'u64 shl (int(id) and 63))
  workspace.touchedWords.sort()
  output.setLen(0)
  for wordIndex in workspace.touchedWords:
    var bits = workspace.words[wordIndex]
    while bits != 0:
      let bit = countTrailingZeroBits(bits)
      output.add uint32((wordIndex shl 6) + bit)
      bits = bits and (bits - 1)
    workspace.words[wordIndex] = 0

proc findPrefixInto*(trie: SuccinctRadixTrie, prefix: string,
                     output: var seq[uint32]) =
  ## byte単位で前方一致するDictionary IDを昇順で `output` へ格納します。
  trie.findPrefixTrieOrderInto(prefix, output)
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
    packedBytes(trie.internalChildCount) + packedBytes(trie.childNodes) +
    packedBytes(trie.highDegreeBitmapOffsets) +
    int64(trie.highDegreeBitmaps.len * sizeof(uint64))
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
