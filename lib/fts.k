/ FTS

InvertedIndexTable: `term`id`pos

SegmentDirectory: 0N

SegmentBTrees: 0N

TermBlocks: 0N

/ 3. Posting Lists
/ term -> [docID1, docID2, docID3...]
/ Often includes: Word positions within the document & Token offsets

RunLength: {
  start: & x> 0,-1_x
  end: & x> 1_x,0
  len: 1+end-start
  start+ !' len
}

SimpleTokenizer: {
  x@ RunLength [~" "=x]
}

BagOfWords: {[tokens]
  &tokens
}

/ 5. Query Processing Algorithm:
/ Parse query into tokens
/ Find posting list for each token, ex: tokenize input string
/ Perform set operations:
/   AND → intersection
/   OR → union
/   NOT → difference
/ Rank results

SearchText:{[db;query]
  positions:
}

/ 6. Ranking Algorithm: BM25
/ Term frequency
/ Document length
/ Inverse document frequency
/ Formula (simplified): score = Σ IDF(term) * TF(term in doc)

/ FTS Table
/ ├── Content table
/ ├── Direct index
/ ├── Segment index
/ ├── Segment data
/ └── DocSize & Rank data
