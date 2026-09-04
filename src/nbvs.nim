## nbvs - Nim Bit Vector and Succinct Data Structures.
##
## This umbrella module re-exports the public APIs from:
##
## * `nbvs/bit_vector`
## * `nbvs/packed_array`
## * `nbvs/succinct_bit_vector`
## * `nbvs/bit_vector_select_cursor`
## * `nbvs/elias_fano`
## * `nbvs/wavelet_matrix`
## * `nbvs/reversed_wavelet_matrix`
## * `nbvs/wavelet_position_match`
## * `nbvs/wavelet_select_cursor`
## * `nbvs/wavelet_matching_runs`
##
## Import this module when you want the complete `nbvs` API.

import nbvs/[bit_vector, packed_array, succinct_bit_vector,
  bit_vector_select_cursor, elias_fano, wavelet_matrix,
  reversed_wavelet_matrix, wavelet_position_match, wavelet_select_cursor,
  wavelet_matching_runs, run_length_bwt, succinct_radix_trie, fm_dictionary]

export bit_vector
export packed_array
export succinct_bit_vector
export bit_vector_select_cursor
export elias_fano
export wavelet_matrix
export reversed_wavelet_matrix
export wavelet_position_match
export wavelet_select_cursor
export wavelet_matching_runs
export run_length_bwt
export succinct_radix_trie
export fm_dictionary