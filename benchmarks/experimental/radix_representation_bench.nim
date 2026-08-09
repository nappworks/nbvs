## Radix Trieのtopologyとedge境界表現を比較する実験benchmark。
##
## 本番のDFS + PackedArray実装を基準に、同じ木からLOUDS、DFUDS、
## delimiter付きSBV edge境界を構築します。

import std/[bitops, monotimes, os, parseutils, strformat, strutils, times]
import nbvs

const QueryIterations = 1_000_000

type
  TopologyExperiment = object
    louds, dfuds: SuccinctBitVector
    bfsToDfs, dfsToBfs: PackedArray
    edgeSuffixDelimiters: SuccinctBitVector

var sink {.volatile.}: uint64

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

func requiredBitWidth(maximum: uint64): int =
  if maximum == 0: 0 else: 64 - countLeadingZeroBits(maximum)

func packedBytes(values: PackedArray): int64 =
  int64(values.data.len) * 8

func sbvBytes(values: SuccinctBitVector): int64 =
  int64(values.data.len + values.selectStorage.len) * 8 +
    int64(values.blockPairPrefix.len + values.wordPairPrefix.len) * 4

proc buildExperiment(trie: SuccinctRadixTrie): TopologyExperiment =
  let nodeCount = trie.edgeFirstBytes.len
  result.bfsToDfs = genPackedArray(nodeCount,
    requiredBitWidth(uint64(max(0, nodeCount - 1))))
  result.dfsToBfs = genPackedArray(nodeCount,
    requiredBitWidth(uint64(max(0, nodeCount - 1))))

  var bfsNodes = newSeqOfCap[int](nodeCount)
  bfsNodes.add 0
  var position = 0
  while position < bfsNodes.len:
    let node = bfsNodes[position]
    let first = trie.firstChildOffset(node)
    let count = trie.childCountAt(node)
    for offset in 0..<count:
      bfsNodes.add int(trie.childNodes.getUnchecked(first + offset))
    inc position
  doAssert bfsNodes.len == nodeCount
  for bfsNode, dfsNode in bfsNodes:
    result.bfsToDfs[bfsNode] = uint64(dfsNode)
    result.dfsToBfs[dfsNode] = uint64(bfsNode)

  result.louds = genSuccinctBitVector(int64(2 * nodeCount - 1))
  position = 0
  for dfsNode in bfsNodes:
    let degree = trie.childCountAt(dfsNode)
    for _ in 0..<degree:
      result.louds.setBit(int64(position))
      inc position
    inc position
  doAssert position == 2 * nodeCount - 1
  result.louds.build()

  # 先頭のsuper-root open bitを含むDFUDS degree sequence。
  result.dfuds = genSuccinctBitVector(int64(2 * nodeCount))
  result.dfuds.setBit(0)
  position = 1
  for dfsNode in 0..<nodeCount:
    let degree = trie.childCountAt(dfsNode)
    for _ in 0..<degree:
      result.dfuds.setBit(int64(position))
      inc position
    inc position
  doAssert position == 2 * nodeCount
  result.dfuds.build()

  # delimiterを各edge後に1つ置くため、長さ0のsuffixも一意な境界を持てる。
  let suffixBytes = trie.edgeSuffixBytes.len
  result.edgeSuffixDelimiters = genSuccinctBitVector(
    int64(suffixBytes + nodeCount))
  var runningSuffixEnd = 0
  for node in 0..<nodeCount:
    let suffix = trie.edgeSuffixRange(node)
    if suffix.last > suffix.first:
      doAssert suffix.first == runningSuffixEnd
      runningSuffixEnd = suffix.last
    result.edgeSuffixDelimiters.setBit(int64(runningSuffixEnd + node))
  result.edgeSuffixDelimiters.build()

func loudsChildRange(experiment: TopologyExperiment,
                     bfsNode: int): tuple[first, count: int] =
  let start = if bfsNode == 0: 0'i64
    else: experiment.louds.select0(int64(bfsNode - 1)) + 1
  let finish = experiment.louds.select0(int64(bfsNode))
  result.count = int(finish - start)
  result.first = int(experiment.louds.rank1(start)) + 1

func loudsParent(experiment: TopologyExperiment, bfsNode: int): int =
  if bfsNode == 0:
    return 0
  let edgePosition = experiment.louds.select1(int64(bfsNode - 1))
  int(experiment.louds.rank0(edgePosition))

func dfudsDegree(experiment: TopologyExperiment, dfsNode: int): int =
  let start = if dfsNode == 0: 1'i64
    else: experiment.dfuds.select0(int64(dfsNode - 1)) + 1
  let finish = experiment.dfuds.select0(int64(dfsNode))
  int(finish - start)

func sbvSuffixRange(experiment: TopologyExperiment,
                    node: int): tuple[first, last: int] =
  let encodedStart = if node == 0: 0'i64
    else: experiment.edgeSuffixDelimiters.select1(int64(node - 1)) + 1
  let encodedEnd = experiment.edgeSuffixDelimiters.select1(int64(node))
  result.first = int(encodedStart) - node
  result.last = int(encodedEnd) - node

func loudsFindChild(trie: SuccinctRadixTrie,
                    experiment: TopologyExperiment, bfsNode: int,
                    firstByte: byte): int =
  let children = experiment.loudsChildRange(bfsNode)
  var left = children.first
  var right = children.first + children.count
  while left < right:
    let middle = (left + right) shr 1
    let dfsChild = int(experiment.bfsToDfs.getUnchecked(middle))
    if trie.edgeFirstBytes[dfsChild] < firstByte:
      left = middle + 1
    else:
      right = middle
  if left < children.first + children.count:
    let dfsChild = int(experiment.bfsToDfs.getUnchecked(left))
    if trie.edgeFirstBytes[dfsChild] == firstByte:
      return left
  -1

func loudsLocate(trie: SuccinctRadixTrie, experiment: TopologyExperiment,
                 pattern: string): tuple[bfsNode: int, atBoundary: bool] =
  result = (bfsNode: 0, atBoundary: true)
  var position = 0
  while position < pattern.len:
    let child = trie.loudsFindChild(experiment, result.bfsNode,
      byte(pattern[position]))
    if child < 0:
      return (bfsNode: -1, atBoundary: false)
    let dfsChild = int(experiment.bfsToDfs.getUnchecked(child))
    inc position
    let suffix = trie.edgeSuffixRange(dfsChild)
    for suffixPosition in suffix.first..<suffix.last:
      if position == pattern.len:
        return (bfsNode: child, atBoundary: false)
      if byte(pattern[position]) != trie.edgeSuffixBytes[suffixPosition]:
        return (bfsNode: -1, atBoundary: false)
      inc position
    result = (bfsNode: child, atBoundary: true)

func loudsFindExact(trie: SuccinctRadixTrie,
                    experiment: TopologyExperiment, value: string): int64 =
  let location = trie.loudsLocate(experiment, value)
  if location.bfsNode < 0 or not location.atBoundary:
    return -1
  let dfsNode = int(experiment.bfsToDfs.getUnchecked(location.bfsNode))
  if not trie.terminalBits.access(int64(dfsNode)):
    return -1
  let ordinal = trie.terminalBits.rank1(int64(dfsNode))
  int64(trie.terminalIds.getUnchecked(int(ordinal)))

proc loudsGetStringInto(trie: SuccinctRadixTrie,
                        experiment: TopologyExperiment, id: uint32,
                        output: var string) =
  var bfsNode = int(experiment.dfsToBfs.getUnchecked(
    int(trie.idToTerminal.getUnchecked(int(id)))))
  var length = 0
  var current = bfsNode
  while current != 0:
    let dfsNode = int(experiment.bfsToDfs.getUnchecked(current))
    let suffix = trie.edgeSuffixRange(dfsNode)
    length += 1 + suffix.last - suffix.first
    current = experiment.loudsParent(current)
  output.setLen(length)
  var writePosition = length
  while bfsNode != 0:
    let dfsNode = int(experiment.bfsToDfs.getUnchecked(bfsNode))
    let suffix = trie.edgeSuffixRange(dfsNode)
    let edgeLength = 1 + suffix.last - suffix.first
    writePosition -= edgeLength
    output[writePosition] = char(trie.edgeFirstBytes[dfsNode])
    for offset in 0..<suffix.last - suffix.first:
      output[writePosition + offset + 1] =
        char(trie.edgeSuffixBytes[suffix.first + offset])
    bfsNode = experiment.loudsParent(bfsNode)

proc validate(trie: SuccinctRadixTrie, experiment: TopologyExperiment,
              values: openArray[string]) =
  for dfsNode in 0..<trie.edgeFirstBytes.len:
    let bfsNode = int(experiment.dfsToBfs.getUnchecked(dfsNode))
    let childRange = experiment.loudsChildRange(bfsNode)
    doAssert childRange.count == trie.childCountAt(dfsNode)
    doAssert experiment.dfudsDegree(dfsNode) == childRange.count
    if bfsNode > 0:
      let parentBfs = experiment.loudsParent(bfsNode)
      doAssert int(experiment.bfsToDfs.getUnchecked(parentBfs)) ==
        trie.parentAt(dfsNode)
    let suffixRange = experiment.sbvSuffixRange(dfsNode)
    let sparseSuffix = trie.edgeSuffixRange(dfsNode)
    doAssert suffixRange.last - suffixRange.first ==
      sparseSuffix.last - sparseSuffix.first
    if sparseSuffix.last > sparseSuffix.first:
      doAssert suffixRange == sparseSuffix
  var restored: string
  for id, value in values:
    doAssert trie.loudsFindExact(experiment, value) == id
    trie.loudsGetStringInto(experiment, uint32(id), restored)
    doAssert restored == value

proc makeValues(count, averageLength: int): seq[string] =
  for index in 0..<count:
    let identifier = $index
    result.add "v" & repeat('a', max(0,
      averageLength - identifier.len - 1)) & identifier

proc run(count, averageLength: int) =
  let values = makeValues(count, averageLength)
  let trie = genSuccinctRadixTrie(values)
  let experiment = buildExperiment(trie)
  validate(trie, experiment, values)
  let nodeCount = trie.edgeFirstBytes.len

  var started = getMonoTime()
  for query in 0..<QueryIterations:
    let node = query mod nodeCount
    sink = sink xor uint64(trie.firstChildOffset(node) + 1) xor
      uint64(trie.childCountAt(node))
  let packedChildrenNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    let dfsNode = query mod nodeCount
    let bfsNode = int(experiment.dfsToBfs.getUnchecked(dfsNode))
    let childRange = experiment.loudsChildRange(bfsNode)
    sink = sink xor uint64(childRange.first) xor uint64(childRange.count)
  let loudsChildrenNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    let node = query mod nodeCount
    sink = sink xor uint64(experiment.dfudsDegree(node))
  let dfudsDegreeNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    let node = query mod nodeCount
    let boundary = trie.edgeSuffixRange(node)
    sink = sink xor uint64(boundary.first) xor uint64(boundary.last)
  let packedBoundaryNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    let node = query mod nodeCount
    let boundary = experiment.sbvSuffixRange(node)
    sink = sink xor uint64(boundary.first) xor uint64(boundary.last)
  let sbvBoundaryNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    let id = query mod count
    sink = sink xor uint64(trie.findExact(values[id]))
  let dfsExactNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    let id = query mod count
    sink = sink xor uint64(trie.loudsFindExact(experiment, values[id]))
  let loudsExactNs = elapsedNs(started)

  var restored: string
  started = getMonoTime()
  for query in 0..<QueryIterations:
    trie.getStringInto(uint32(query mod count), restored)
    sink = sink xor uint64(restored.len)
  let dfsRestoreNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    trie.loudsGetStringInto(experiment, uint32(query mod count), restored)
    sink = sink xor uint64(restored.len)
  let loudsRestoreNs = elapsedNs(started)

  let packedTopologyBytes = sbvBytes(trie.internalBits) +
    packedBytes(trie.internalFirstChild) +
    packedBytes(trie.internalChildCount) + packedBytes(trie.childNodes) +
    int64(trie.parents.bitWidths.len) +
    int64(trie.parents.wordOffsets.len) * 4 +
    int64(trie.parents.data.len) * 8
  echo "representation,bytes,ns_per_operation"
  echo &"dfs_packed_topology,{packedTopologyBytes}," &
    &"{float(packedChildrenNs) / QueryIterations.float:.2f}"
  echo &"louds,{sbvBytes(experiment.louds) + packedBytes(experiment.bfsToDfs) + packedBytes(experiment.dfsToBfs)}," &
    &"{float(loudsChildrenNs) / QueryIterations.float:.2f}"
  echo &"dfuds,{sbvBytes(experiment.dfuds)}," &
    &"{float(dfudsDegreeNs) / QueryIterations.float:.2f}"
  echo &"packed_edge_boundaries,{packedBytes(trie.edgeSuffixOffsets)}," &
    &"{float(packedBoundaryNs) / QueryIterations.float:.2f}"
  echo &"sbv_edge_boundaries,{sbvBytes(experiment.edgeSuffixDelimiters)}," &
    &"{float(sbvBoundaryNs) / QueryIterations.float:.2f}"
  echo "query,dfs_packed_ns,louds_ns"
  echo &"exact,{float(dfsExactNs) / QueryIterations.float:.2f}," &
    &"{float(loudsExactNs) / QueryIterations.float:.2f}"
  echo &"restore,{float(dfsRestoreNs) / QueryIterations.float:.2f}," &
    &"{float(loudsRestoreNs) / QueryIterations.float:.2f}"

when isMainModule:
  var count = 100_000
  var averageLength = 16
  if paramCount() >= 1:
    discard parseInt(paramStr(1), count)
  if paramCount() >= 2:
    discard parseInt(paramStr(2), averageLength)
  if count <= 0 or averageLength <= 0:
    raise newException(ValueError, "count and averageLength must be positive")
  run(count, averageLength)
  stderr.writeLine("sink=", sink)
