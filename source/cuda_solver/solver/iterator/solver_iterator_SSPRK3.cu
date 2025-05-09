#include <omp.h>

// Include Cuda Kernel headers
#include "cuda/typedef.cuh"
#include "kernel/kernel_compute.cuh"
#include "kernel/kernel_summation.cuh"
#include "kernel/kernel_halo.cuh"
#include "system/system_parameters.hpp"
#include "cuda/cuda_matrix.cuh"
#include "solver/gpu_solver.hpp"
#include "misc/commandline_io.hpp"

void PHOENIX::Solver::iterateFixedTimestepSSPRK3() {
    SOLVER_SEQUENCE( true /*Capture CUDA Graph*/,

                     CALCULATE_K( 1, Type::real( 0.0 ), wavefunction, reservoir );

                     INTERMEDIATE_SUM_K( 1, Type::real( 1.0 ) );

                     CALCULATE_K( 2, Type::real( 1.0 ), buffer_wavefunction, buffer_reservoir );

                     INTERMEDIATE_SUM_K( 2, Type::real( 1.0 / 4.0 ), Type::real( 1.0 / 4.0 ) );

                     CALCULATE_K( 3, Type::real( 1.0 ), buffer_wavefunction, buffer_reservoir );

                     FINAL_SUM_K( 3, Type::real( 1.0 / 6.0 ), Type::real( 1.0 / 6.0 ), Type::real( 2.0 / 3.0 ) );

    );
}
