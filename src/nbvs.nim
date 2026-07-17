## nbvs - Nim Bit Vector and Succinct Data Structures.
##
## This umbrella module re-exports the public APIs from:
##
## * `nbvs/bit_vector`
## * `nbvs/packed_array`
## * `nbvs/succinct_bit_vector`
## * `nbvs/elias_fano`
## * `nbvs/wavelet_matrix`
## * `nbvs/reversed_wavelet_matrix`
##
## Import this module when you want the complete `nbvs` API.

import nbvs/[bit_vector, packed_array, succinct_bit_vector, elias_fano,
  wavelet_matrix, reversed_wavelet_matrix]

export bit_vector
export packed_array
export succinct_bit_vector
export elias_fano
export wavelet_matrix
export reversed_wavelet_matrix
