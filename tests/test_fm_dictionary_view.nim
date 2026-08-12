import std/[math, strutils]
import nbvs/[fm_dictionary, packed_array, succinct_bit_vector,
  wavelet_matrix, run_length_bwt, succinct_radix_trie]

type
  WaveletBacking = object
    levels: seq[seq[uint64]]
    views: seq[SuccinctBitVectorView]
    zeros: seq[int64]

  TrieBacking = object
    internalBits, hasSuffixBits, terminalBits: seq[uint64]
    internalFirstChild, internalChildCount, childNodes: seq[uint64]
    highDegreeBitmapOffsets, edgeSuffixOffsets: seq[uint64]
    terminalIds, idToTerminal: seq[uint64]
    internalFirstTerminal, internalTerminalCount: seq[uint64]
    highDegreeBitmaps: seq[uint64]
    parentBitWidths: seq[uint8]
    parentWordOffsets: seq[uint32]
    parentData: seq[uint64]
    edgeFirstBytes, edgeSuffixBytes: seq[byte]

  FmViewBacking = object
    bwt, runIndex: WaveletBacking
    runStarts: seq[uint64]
    runSymbols: seq[FmSymbol]
    symbolOffsets, symbolPrefixes: seq[uint32]
    cTable, startAnchors, endAnchors: seq[uint64]
    trie: TrieBacking

proc memory[T](values: var seq[T]): pointer =
  if values.len == 0: nil else: addr values[0]

proc span[T](values: var seq[T]): ExternalSpan[T] =
  ExternalSpan[T](data: cast[ptr UncheckedArray[T]](values.memory),
    len: values.len)

proc packedView(source: PackedArray, storage: var seq[uint64]): PackedArrayView =
  storage = source.data
  initPackedArrayView(storage.memory, storage.len * sizeof(uint64),
    source.len, source.bitWidth)

proc succinctView(source: SuccinctBitVector,
                  storage: var seq[uint64]): SuccinctBitVectorView =
  storage = newSeq[uint64]((requiredSuccinctBitVectorViewBytes(
    source.lenOfBits) + 7) div 8)
  result = initSuccinctBitVectorView(storage.memory,
    storage.len * sizeof(uint64), source.lenOfBits)
  for position in 0'i64..<source.lenOfBits:
    if source[position]: result.setBit(position)
  result.build()

proc waveletView(source: WaveletMatrix,
                 backing: var WaveletBacking): WaveletMatrixView =
  backing.levels.setLen(source.bitWidth)
  backing.views.setLen(source.bitWidth)
  for level in 0..<source.bitWidth:
    backing.views[level] = succinctView(source.levels[level],
      backing.levels[level])
  backing.zeros = source.zeroCounts
  initWaveletMatrixView(source.n, source.bitWidth,
    cast[ptr UncheckedArray[SuccinctBitVectorView]](backing.views.memory),
    backing.views.len, backing.zeros.memory,
    backing.zeros.len * sizeof(int64))

proc trieView(source: SuccinctRadixTrie,
              backing: var TrieBacking): SuccinctRadixTrieView =
  let internalBits = succinctView(source.internalBits, backing.internalBits)
  let hasSuffixBits = succinctView(source.hasSuffixBits,
    backing.hasSuffixBits)
  let terminalBits = succinctView(source.terminalBits, backing.terminalBits)
  backing.highDegreeBitmaps = source.highDegreeBitmaps
  backing.parentBitWidths = source.parents.bitWidths
  backing.parentWordOffsets = source.parents.wordOffsets
  backing.parentData = source.parents.data
  backing.edgeFirstBytes = source.edgeFirstBytes
  backing.edgeSuffixBytes = source.edgeSuffixBytes
  initSuccinctRadixTrieView(SuccinctRadixTrieViewParts(
    internalBits: internalBits,
    internalFirstChild: packedView(source.internalFirstChild,
      backing.internalFirstChild),
    internalChildCount: packedView(source.internalChildCount,
      backing.internalChildCount),
    childNodes: packedView(source.childNodes, backing.childNodes),
    highDegreeBitmapOffsets: packedView(source.highDegreeBitmapOffsets,
      backing.highDegreeBitmapOffsets),
    highDegreeBitmaps: backing.highDegreeBitmaps.span,
    parents: BlockPackedParentsView(
      bitWidths: backing.parentBitWidths.span,
      wordOffsets: backing.parentWordOffsets.span,
      data: backing.parentData.span),
    edgeFirstBytes: backing.edgeFirstBytes.span,
    edgeSuffixBytes: backing.edgeSuffixBytes.span,
    sparseSuffixes: source.sparseSuffixes,
    hasSuffixBits: hasSuffixBits,
    edgeSuffixOffsets: packedView(source.edgeSuffixOffsets,
      backing.edgeSuffixOffsets),
    terminalBits: terminalBits,
    terminalIds: packedView(source.terminalIds, backing.terminalIds),
    idToTerminal: packedView(source.idToTerminal, backing.idToTerminal),
    internalFirstTerminal: packedView(source.internalFirstTerminal,
      backing.internalFirstTerminal),
    internalTerminalCount: packedView(source.internalTerminalCount,
      backing.internalTerminalCount)))

proc fmView(source: FmDictionary,
            backing: var FmViewBacking): FmDictionaryView =
  var bwt: WaveletMatrixView
  var runLengthBwt: RunLengthBwtView
  if source.backendKind == fbWavelet:
    bwt = waveletView(source.bwt, backing.bwt)
  else:
    let runStarts = succinctView(source.runLengthBwt.runStarts,
      backing.runStarts)
    let runIndex = waveletView(source.runLengthBwt.runSymbolIndex,
      backing.runIndex)
    backing.runSymbols = source.runLengthBwt.runSymbols
    backing.symbolOffsets = @(source.runLengthBwt.symbolOffsets)
    backing.symbolPrefixes = source.runLengthBwt.symbolPrefixes
    runLengthBwt = initRunLengthBwtView(source.runLengthBwt.n,
      backing.runSymbols.memory,
      backing.runSymbols.len * sizeof(FmSymbol), runStarts, runIndex,
      backing.symbolOffsets.memory,
      backing.symbolOffsets.len * sizeof(uint32),
      backing.symbolPrefixes.memory,
      backing.symbolPrefixes.len * sizeof(uint32))
  initFmDictionaryView(FmDictionaryViewParts(
    bwt: bwt, runLengthBwt: runLengthBwt,
    backendKind: source.backendKind,
    bwtRunCount: source.bwtRunCount,
    maximumBwtRunLength: source.maximumBwtRunLength,
    estimatedWaveletBytes: source.estimatedWaveletBytes,
    estimatedRunLengthBytes: source.estimatedRunLengthBytes,
    cTable: packedView(source.cTable, backing.cTable),
    startAnchorToEncodedId: packedView(source.startAnchorToEncodedId,
      backing.startAnchors),
    dictionaryIdToEndAnchor: packedView(source.dictionaryIdToEndAnchor,
      backing.endAnchors),
    dictionaryCount: source.dictionaryCount,
    maxEncodedStringLength: source.maxEncodedStringLength,
    radixTrie: trieView(source.radixTrie, backing.trie)))

proc assertSameQueries(heap: FmDictionary, view: FmDictionaryView,
                       patterns: openArray[string]) =
  doAssert heap.len == view.len
  let heapUsage = heap.memoryUsage
  let viewUsage = view.memoryUsage
  doAssert heapUsage.fmBackendKind == viewUsage.fmBackendKind
  doAssert heapUsage.cTableBytes == viewUsage.cTableBytes
  doAssert heapUsage.anchorBytes == viewUsage.anchorBytes
  doAssert viewUsage.totalBytes > 0
  let heapStats = heap.stats
  let viewStats = view.stats
  doAssert heapStats.fmBackendKind == viewStats.fmBackendKind
  doAssert heapStats.bwtLength == viewStats.bwtLength
  doAssert heapStats.runCount == viewStats.runCount
  doAssert heapStats.maximumRunLength == viewStats.maximumRunLength
  doAssert abs(heapStats.runRatio - viewStats.runRatio) < 1e-12
  var heapSubstringWorkspace = initFmQueryWorkspace(heap)
  var viewSubstringWorkspace = initFmQueryWorkspace(view)
  var heapPrefixWorkspace = initPrefixQueryWorkspace(heap)
  var viewPrefixWorkspace = initPrefixQueryWorkspace(view)
  for pattern in patterns:
    doAssert heap.findExact(pattern) == view.findExact(pattern)
    doAssert heap.findExactFm(pattern) == view.findExactFm(pattern)
    doAssert heap.findExactRadix(pattern) == view.findExactRadix(pattern)
    doAssert heap.contains(pattern) == view.contains(pattern)
    doAssert heap.findPrefix(pattern) == view.findPrefix(pattern)
    doAssert heap.findSuffix(pattern) == view.findSuffix(pattern)
    doAssert heap.findSubstring(pattern) == view.findSubstring(pattern)
    doAssert heap.findSubstringOccurrences(pattern) ==
      view.findSubstringOccurrences(pattern)
    var heapOutput, viewOutput: seq[DictionaryId]
    heap.findPrefixIntoFm(pattern, heapOutput)
    view.findPrefixIntoFm(pattern, viewOutput)
    doAssert heapOutput == viewOutput
    heap.findPrefixIntoRadix(pattern, heapPrefixWorkspace, heapOutput)
    view.findPrefixIntoRadix(pattern, viewPrefixWorkspace, viewOutput)
    doAssert heapOutput == viewOutput
    heap.findSuffixInto(pattern, heapOutput)
    view.findSuffixInto(pattern, viewOutput)
    doAssert heapOutput == viewOutput
    heap.findSubstringInto(pattern, heapSubstringWorkspace, heapOutput)
    view.findSubstringInto(pattern, viewSubstringWorkspace, viewOutput)
    doAssert heapOutput == viewOutput
  for id in 0..<heap.len:
    var heapValue, viewValue: string
    heap.getStringIntoFm(DictionaryId(id), heapValue)
    view.getStringIntoFm(DictionaryId(id), viewValue)
    doAssert heapValue == viewValue
    heap.getStringInto(DictionaryId(id), heapValue)
    view.getStringInto(DictionaryId(id), viewValue)
    doAssert heapValue == viewValue
    doAssert heap.getString(DictionaryId(id)) == view.getString(DictionaryId(id))

let corpus = @["", "a", "apple", "application", "banana", "bandana",
  "hana", "東京", repeat('x', 300), "\0\xFF"]
let patterns = ["", "a", "app", "apple", "ana", "na", "missing",
  "東京", "\0", repeat('x', 299), repeat('x', 301)]

for preference in [fbpWavelet, fbpRunLength, fbpAuto]:
  let heap = genFmDictionary(corpus, FmDictionaryBuildOptions(
    validateDistinct: true, fmBackend: preference))
  var backing: FmViewBacking
  let view = fmView(heap, backing)
  assertSameQueries(heap, view, patterns)

block invalidMetadata:
  var raised = false
  try:
    discard initFmDictionaryView(default(FmDictionaryViewParts))
  except ValueError:
    raised = true
  doAssert raised
