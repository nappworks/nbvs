# PR #18 WM query optimization validation

## Environment

- Date: 2026-09-12
- CPU: Intel Core i5-8365U (4 cores / 8 threads, AVX2, BMI2)
- OS/architecture: Linux x86_64 (Microsoft hypervisor)
- Nim used by Nimble: 2.2.12
- Build flags: `-d:release --mm:arc`; SIMD additionally uses `-d:nbvsSimd`
- Each A/B task was run twice. Each task uses identical inputs and queries for both paths, alternates execution order, performs one warmup iteration, and reports the median of five measured iterations.

## Access + rank fusion

Raw results:

- [scalar](wm_access_rank_fusion_ab_scalar.csv)
- [AVX2/BMI2](wm_access_rank_fusion_ab_simd.csv)

The fused path improves several 65K cases, but regresses the 1M access cases and the main 16M cases repeatedly. At 16M, the second SIMD run reports speedups of 0.9721x/0.9575x for uniform access/accessRank and 0.9586x/0.9786x for skewed access/accessRank. The WM integration is therefore rejected. The SBV primitive and its correctness tests remain available for future experiments.

## Rank pair

Raw results:

- [scalar](wm_rank_pair_ab_scalar.csv)
- [AVX2/BMI2](wm_rank_pair_ab_simd.csv)

The scalar path is mostly beneficial, but the SIMD path has substantial and repeated 1M regressions. In the second SIMD run, uniform rankPair and quantile report 0.8082x and 0.7937x, while skewed countLessThan and quantile report 0.8691x and 0.8424x. Results at 16M are mixed and generally close to neutral. Maintaining backend-specific WM traversal paths is not justified by these results, so the WM integration is rejected. The SBV pair primitive and its correctness tests remain available.

## Final comparison

After rejecting both WM integrations, the final comparison tasks were rerun. The merge-decision inputs are:

- [scalar SBV/QV](sbv_quad_vector_scalar.csv)
- [AVX2/BMI2 SBV/QV](sbv_quad_vector_simd.csv)
- [scalar WM/QWM](wm_quad_wavelet_matrix_scalar.csv)
- [AVX2/BMI2 WM/QWM](wm_quad_wavelet_matrix_simd.csv)

The final implementation retains the fixed-depth rank dispatch, while WM uses separate bit/rank operations and separate fixed-depth rank calls.
