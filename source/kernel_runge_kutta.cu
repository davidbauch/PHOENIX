#include <cuComplex.h>
#include <cuda_runtime_api.h> // cudaMalloc, cudaMemcpy, etc.
#include <cuda.h>
#include <device_launch_parameters.h>
#include <cuda_runtime.h>
#include <cufft.h>
#include <complex>
#include <omp.h>

// Include Cuda Kernel headers
#include "cuda_complex.cuh"
#include "kernel_runge_function.cuh"
#include "kernel_summation.cuh"
#include "kernel_ringstate.cuh"
#include "kernel_fft.cuh"
#include "system.hpp"
#include "kernel.hpp"
#include "helperfunctions.hpp"

#include <thrust/reduce.h>
#include <thrust/execution_policy.h>

/*
TODOs for Optimization:
- remove shift kernel and combine it in mask
- remove index to row/col calculation, instead use map index->row and index->col to avoid expensive % modulo operator
- cache pump and pulse shapes
- cache fft mask -> shift mask array
- calculate everything in one big kernel; no need for intermediate arrays and multiple kernel calls
*/

/*
 * Helper variable for caching the current time for FFT evaluations.
 * We dont need this variable anywhere else, so we just create it
 * locally to this file here.
 */
real_number cached_t = 0.0;

/*
 * This function iterates the Runge Kutta Kernel using a fixed time step.
 * A 4th order Runge-Kutta method is used. This function calls a single
 * rungeFuncSum function with varying delta-t. Calculation of the inputs
 * for the next rungeFuncKernel call is done in the rungeFuncSum function.
 * The general implementation of the RK4 method goes as follows:
 * ------------------------------------------------------------------------------
 * k1 = f(t, y) = rungeFuncKernel(current)
 * input_for_k2 = current + 0.5 * dt * k1
 * k2 = f(t + 0.5 * dt, input_for_k2) = rungeFuncKernel(input_for_k2)
 * input_for_k3 = current + 0.5 * dt * k2
 * k3 = f(t + 0.5 * dt, input_for_k3) = rungeFuncKernel(input_for_k3)
 * input_for_k4 = current + dt * k3
 * k4 = f(t + dt, input_for_k4) = rungeFuncKernel(input_for_k4)
 * next = current + dt * (1/6 * k1 + 1/3 * k2 + 1/3 * k3 + 1/6 * k4)
 * ------------------------------------------------------------------------------
 * @param system The system to iterate
 * @param evaluate_pulse If true, the pulse is evaluated at the current time step
 */
void iterateFixedTimestepRungeKutta( System& system, bool evaluate_pulse, dim3 block_size, dim3 grid_size ) {
    // Iterate the Runge Function on the current Psi and Calculate K1
    rungeFuncKernel<<<grid_size, block_size>>>( system.t, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
    CHECK_CUDA_ERROR( {}, "K1" );

    // Sum K1 to get next_Psi_Plus, next_Psi_Minus, next_n_Plus, next_n_Minus
    rungeFuncSum<<<grid_size, block_size>>>( 0.5, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus );
    CHECK_CUDA_ERROR( {}, "Sum(K1)" );

    // Iterate the Runge Function on next_Psi and Calculate K2
    rungeFuncKernel<<<grid_size, block_size>>>( system.t + 0.5 * system.dt, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_k2_Psi_Plus, dev_k2_Psi_Minus, dev_k2_n_Plus, dev_k2_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
    CHECK_CUDA_ERROR( {}, "K2" );

    // Sum K2 to get next_Psi_Plus, next_Psi_Minus, next_n_Plus, next_n_Minus
    rungeFuncSum<<<grid_size, block_size>>>( 0.5, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k2_Psi_Plus, dev_k2_Psi_Minus, dev_k2_n_Plus, dev_k2_n_Minus );
    CHECK_CUDA_ERROR( {}, "Sum(K2)" );

    // Iterate the Runge Function on next_Psi and Calculate K3
    rungeFuncKernel<<<grid_size, block_size>>>( system.t + 0.5 * system.dt, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_k3_Psi_Plus, dev_k3_Psi_Minus, dev_k3_n_Plus, dev_k3_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
    CHECK_CUDA_ERROR( {}, "K3" );

    // Sum K3 to get next_Psi_Plus, next_Psi_Minus, next_n_Plus, next_n_Minus
    rungeFuncSum<<<grid_size, block_size>>>( 1.0, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k3_Psi_Plus, dev_k3_Psi_Minus, dev_k3_n_Plus, dev_k3_n_Minus );
    CHECK_CUDA_ERROR( {}, "Sum(K3)" );

    // Iterate the Runge Function on next_Psi and Calculate K4
    rungeFuncKernel<<<grid_size, block_size>>>( system.t + system.dt, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_k4_Psi_Plus, dev_k4_Psi_Minus, dev_k4_n_Plus, dev_k4_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
    CHECK_CUDA_ERROR( {}, "K4" );

    // Calculate the final Runge Kutta sum, saving the result in dev_in_Psi
    rungeFuncSumToFinalFixed<<<grid_size, block_size>>>( dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus, dev_k2_Psi_Plus, dev_k2_Psi_Minus, dev_k2_n_Plus, dev_k2_n_Minus, dev_k3_Psi_Plus, dev_k3_Psi_Minus, dev_k3_n_Plus, dev_k3_n_Minus, dev_k4_Psi_Plus, dev_k4_Psi_Minus, dev_k4_n_Plus, dev_k4_n_Minus );
    CHECK_CUDA_ERROR( {}, "Final Sum" );
    return;
}

/*
* This function iterates the Runge Kutta Kernel using a variable time step.
* A 4th order Runge-Kutta method is used to calculate
* the next y iteration; a 5th order solution is
* used to calculate the iteration error.
* This function calls multiple different rungeFuncSum functions with varying
* delta-t and coefficients. Calculation of the inputs for the next
* rungeFuncKernel call is done in the rungeFuncSum function.
* The general implementation of the RK45 method goes as follows:
* ------------------------------------------------------------------------------
* k1 = f(t, y) = rungeFuncKernel(current)
* input_for_k2 = current + b11 * dt * k1
* k2 = f(t + a2 * dt, input_for_k2) = rungeFuncKernel(input_for_k2)
* input_for_k3 = current + b21 * dt * k1 + b22 * dt * k2
* k3 = f(t + a3 * dt, input_for_k3) = rungeFuncKernel(input_for_k3)
* input_for_k4 = current + b31 * dt * k1 + b32 * dt * k2 + b33 * dt * k3
* k4 = f(t + a4 * dt, input_for_k4) = rungeFuncKernel(input_for_k4)
* input_for_k5 = current + b41 * dt * k1 + b42 * dt * k2 + b43 * dt * k3
                 + b44 * dt * k4
* k5 = f(t + a5 * dt, input_for_k5) = rungeFuncKernel(input_for_k5)
* input_for_k6 = current + b51 * dt * k1 + b52 * dt * k2 + b53 * dt * k3
                 + b54 * dt * k4 + b55 * dt * k5
* k6 = f(t + a6 * dt, input_for_k6) = rungeFuncKernel(input_for_k6)
* next = current + dt * (b61 * k1 + b63 * k3 + b64 * k4 + b65 * k5 + b66 * k6)
* k7 = f(t + a7 * dt, next) = rungeFuncKernel(next)
* error = dt * (e1 * k1 + e3 * k3 + e4 * k4 + e5 * k5 + e6 * k6 + e7 * k7)
* ------------------------------------------------------------------------------
* The error is then used to update the timestep; If the error is below threshold,
* the iteration is accepted and the total time is increased by dt. If the error
* is above threshold, the iteration is rejected and the timestep is decreased.
* The timestep is always bounded by dt_min and dt_max and will only increase
* using whole multiples of dt_min.
* ------------------------------------------------------------------------------
* @param system The system to iterate
* @param evaluate_pulse If true, the pulse is evaluated at the current time step
*/
void iterateVariableTimestepRungeKutta( System& system, bool evaluate_pulse, dim3 block_size, dim3 grid_size ) {
    bool accept = false;
    do {
        // Iterate the Runge Function on the current Psi and Calculate K1
        rungeFuncKernel<<<grid_size, block_size>>>( system.t, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
        CHECK_CUDA_ERROR( {}, "K1" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Sum K1 to get next_Psi_Plus, next_Psi_Minus, next_n_Plus, next_n_Minus
        rungeFuncSumToK2<<<grid_size, block_size>>>( dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus );
        CHECK_CUDA_ERROR( {}, "Sum(K1)" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Iterate the Runge Function on next_Psi and Calculate K2
        rungeFuncKernel<<<grid_size, block_size>>>( system.t + RKCoefficients::a2 * system.dt, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_k2_Psi_Plus, dev_k2_Psi_Minus, dev_k2_n_Plus, dev_k2_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
        CHECK_CUDA_ERROR( {}, "K2" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Sum K2 to get next_Psi_Plus, next_Psi_Minus, next_n_Plus, next_n_Minus
        rungeFuncSumToK3<<<grid_size, block_size>>>( dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus, dev_k2_Psi_Plus, dev_k2_Psi_Minus, dev_k2_n_Plus, dev_k2_n_Minus );
        CHECK_CUDA_ERROR( {}, "Sum(K1,K2)" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Iterate the Runge Function on next_Psi and Calculate K3
        rungeFuncKernel<<<grid_size, block_size>>>( system.t + RKCoefficients::a3 * system.dt, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_k3_Psi_Plus, dev_k3_Psi_Minus, dev_k3_n_Plus, dev_k3_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
        CHECK_CUDA_ERROR( {}, "K3" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Sum K3 to get next_Psi_Plus, next_Psi_Minus, next_n_Plus, next_n_Minus
        rungeFuncSumToK4<<<grid_size, block_size>>>( dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus, dev_k2_Psi_Plus, dev_k2_Psi_Minus, dev_k2_n_Plus, dev_k2_n_Minus, dev_k3_Psi_Plus, dev_k3_Psi_Minus, dev_k3_n_Plus, dev_k3_n_Minus );
        CHECK_CUDA_ERROR( {}, "Sum(K1,K2,K3)" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Iterate the Runge Function on next_Psi and Calculate K4
        rungeFuncKernel<<<grid_size, block_size>>>( system.t + RKCoefficients::a4 * system.dt, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_k4_Psi_Plus, dev_k4_Psi_Minus, dev_k4_n_Plus, dev_k4_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
        CHECK_CUDA_ERROR( {}, "K4" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Sum K4 to get next_Psi_Plus, next_Psi_Minus, next_n_Plus, next_n_Minus
        rungeFuncSumToK5<<<grid_size, block_size>>>( dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus, dev_k2_Psi_Plus, dev_k2_Psi_Minus, dev_k2_n_Plus, dev_k2_n_Minus, dev_k3_Psi_Plus, dev_k3_Psi_Minus, dev_k3_n_Plus, dev_k3_n_Minus, dev_k4_Psi_Plus, dev_k4_Psi_Minus, dev_k4_n_Plus, dev_k4_n_Minus );
        CHECK_CUDA_ERROR( {}, "Sum(K1,K2,K3,K4)" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Iterate the Runge Function on next_Psi and Calculate K4
        rungeFuncKernel<<<grid_size, block_size>>>( system.t + RKCoefficients::a5 * system.dt, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_k5_Psi_Plus, dev_k5_Psi_Minus, dev_k5_n_Plus, dev_k5_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
        CHECK_CUDA_ERROR( {}, "K5" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Sum K5 to get next_Psi_Plus, next_Psi_Minus, next_n_Plus, next_n_Minus
        rungeFuncSumToK6<<<grid_size, block_size>>>( dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus, dev_k2_Psi_Plus, dev_k2_Psi_Minus, dev_k2_n_Plus, dev_k2_n_Minus, dev_k3_Psi_Plus, dev_k3_Psi_Minus, dev_k3_n_Plus, dev_k3_n_Minus, dev_k4_Psi_Plus, dev_k4_Psi_Minus, dev_k4_n_Plus, dev_k4_n_Minus, dev_k5_Psi_Plus, dev_k5_Psi_Minus, dev_k5_n_Plus, dev_k5_n_Minus );
        CHECK_CUDA_ERROR( {}, "Sum(K1,K2,K3,K4,K5)" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Iterate the Runge Function on next_Psi and Calculate K6
        rungeFuncKernel<<<grid_size, block_size>>>( system.t + RKCoefficients::a6 * system.dt, dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_k6_Psi_Plus, dev_k6_Psi_Minus, dev_k6_n_Plus, dev_k6_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
        CHECK_CUDA_ERROR( {}, "K6" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Calculate the final Runge Kutta sum , saving the result in dev_in_Psi
        rungeFuncSumToFinal<<<grid_size, block_size>>>( dev_next_Psi_Plus, dev_next_Psi_Minus, dev_next_n_Plus, dev_next_n_Minus, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus, dev_k3_Psi_Plus, dev_k3_Psi_Minus, dev_k3_n_Plus, dev_k3_n_Minus, dev_k4_Psi_Plus, dev_k4_Psi_Minus, dev_k4_n_Plus, dev_k4_n_Minus, dev_k5_Psi_Plus, dev_k5_Psi_Minus, dev_k5_n_Plus, dev_k5_n_Minus, dev_k6_Psi_Plus, dev_k6_Psi_Minus, dev_k6_n_Plus, dev_k6_n_Minus );
        CHECK_CUDA_ERROR( {}, "Final Sum First" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Calculate the Error Contribution Matrix K7 from dev_in_Psi
        rungeFuncKernel<<<grid_size, block_size>>>( system.t + RKCoefficients::a7 * system.dt, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k7_Psi_Plus, dev_k7_Psi_Minus, dev_k7_n_Plus, dev_k7_n_Minus, dev_pump_amp, dev_pump_width, dev_pump_X, dev_pump_Y, dev_pump_pol, dev_pulse_t0, dev_pulse_amp, dev_pulse_freq, dev_pulse_sigma, dev_pulse_m, dev_pulse_pol, dev_pulse_width, dev_pulse_X, dev_pulse_Y, evaluate_pulse );
        CHECK_CUDA_ERROR( {}, "K7" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

        // Calculate the Runge Kutta Error. Since we dont need it here anymore, we use one of the K2 cache arrays to do this.
        rungeFuncFinalError<<<grid_size, block_size>>>( dev_rk_error, dev_current_Psi_Plus, dev_current_Psi_Minus, dev_current_n_Plus, dev_current_n_Minus, dev_k1_Psi_Plus, dev_k1_Psi_Minus, dev_k1_n_Plus, dev_k1_n_Minus, dev_k3_Psi_Plus, dev_k3_Psi_Minus, dev_k3_n_Plus, dev_k3_n_Minus, dev_k4_Psi_Plus, dev_k4_Psi_Minus, dev_k4_n_Plus, dev_k4_n_Minus, dev_k5_Psi_Plus, dev_k5_Psi_Minus, dev_k5_n_Plus, dev_k5_n_Minus, dev_k6_Psi_Plus, dev_k6_Psi_Minus, dev_k6_n_Plus, dev_k6_n_Minus, dev_k7_Psi_Plus, dev_k7_Psi_Minus, dev_k7_n_Plus, dev_k7_n_Minus );
        CHECK_CUDA_ERROR( {}, "Final Sum Error" );
        // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );
        // sum <<<1, system.s_N*system.s_N / 2 >>>(dev_k2_Psi_Minus);

        // Use thrust::reduce to calculate the sum of the error matrix
        real_number final_error = thrust::reduce( thrust::device, dev_rk_error, dev_rk_error + system.s_N * system.s_N, 0.0, thrust::plus<real_number>() );
        // complex_number normalizing_factor = thrust::reduce(thrust::device, dev_current_Psi_Plus, dev_current_Psi_Plus + system.s_N*system.s_N, complex_number{0,0}, thrust::plus<complex_number>());
        auto plus_max = std::get<1>( minmax( dev_current_Psi_Plus, system.s_N * system.s_N, true ) );
        final_error = final_error / plus_max;

        // Calculate dh
        real_number dh = pow( system.tolerance / 2. / max( final_error, 1E-15 ), 0.25 );
        // Check if dh is nan
        if ( std::isnan( dh ) ) {
            dh = 1.0;
        }
        if ( std::isnan( final_error ) )
            dh = 0.5;
        // std::cout << " t = " << system.t << " dt = " << system.dt << ", current dh is " << dh << ", new dt would be " << system.dt*dh << ", error is " << final_error << ", which should be less than " << system.tolerance << ", accept? " << (final_error < system.tolerance) << std::endl;
        //  Set new timestep
        // system.dt = min(system.dt * dh, system.dt_max);
        if ( dh < 1.0 )
            system.dt = max( system.dt - system.dt_min * std::floor( 1.0 / dh ), system.dt_min );
        else
            system.dt = min( system.dt + system.dt_min * std::floor( dh ), system.dt_max );
        CHECK_CUDA_ERROR( cudaMemcpyToSymbol( dev_s_dt, &system.dt, sizeof( real_number ) ), "cudaMemcpyToSymbol dt" );
        // Accept step if error is below tolerance
        if ( final_error < system.tolerance ) {
            accept = true;
            // Copy current_Psi to next_Psi
            swap_symbol( dev_current_Psi_Minus, dev_next_Psi_Minus );
            swap_symbol( dev_current_Psi_Plus, dev_next_Psi_Plus );
            swap_symbol( dev_current_n_Minus, dev_next_n_Minus );
            swap_symbol( dev_current_n_Plus, dev_next_n_Plus );
        }
    } while ( !accept );
}

/*
 * This function calculates the Fast Fourier Transformation of Psi+ and Psi-
 * and saves the result in dev_fft_plus and dev_fft_minus. These values can
 * then be grabbed using the getDeviceArrays() function. The FFT is then
 * shifted such that k = 0 is in the center of the FFT matrix. Then, the
 * FFT Filter is applied to the FFT, and the FFT is shifted back. Finally,
 * the inverse FFT is calculated and the result is saved in dev_current_Psi_Plus
 * and dev_current_Psi_Minus. The FFT Arrays are shifted once again for
 * visualization purposes.
 * NOTE/OPTIMIZATION: The Shift->Filter->Shift function will be changed later
 * to a cached filter mask, which itself will be shifted.
 */
void calculateFFT( System& system, dim3 block_size, dim3 grid_size ) {
    CHECK_CUDA_ERROR( FFTSOLVER( plan, (fft_complex_number*)dev_current_Psi_Plus, (fft_complex_number*)dev_fft_plus, CUFFT_FORWARD ), "FFT Exec" );
    CHECK_CUDA_ERROR( FFTSOLVER( plan, (fft_complex_number*)dev_current_Psi_Minus, (fft_complex_number*)dev_fft_minus, CUFFT_FORWARD ), "FFT Exec" );
    // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );
    fftshift_2D<<<grid_size, block_size>>>( dev_fft_plus, dev_fft_minus, system.s_N / 2 );
    // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );
    CHECK_CUDA_ERROR( {}, "FFT Shift" );
    kernel_maskFFT<<<grid_size, block_size>>>( dev_fft_plus, dev_fft_minus, system.fft_power, system.fft_mask_area, false );
    CHECK_CUDA_ERROR( {}, "FFT Filter" );
    // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );
    fftshift_2D<<<grid_size, block_size>>>( dev_fft_plus, dev_fft_minus, system.s_N / 2 );
    CHECK_CUDA_ERROR( {}, "FFT Shift" );
    // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );
    //// Transform back.
    CHECK_CUDA_ERROR( FFTSOLVER( plan, dev_fft_plus, dev_current_Psi_Plus, CUFFT_INVERSE ), "iFFT Exec" );
#ifdef TETMSPLITTING
    CHECK_CUDA_ERROR( FFTSOLVER( plan, dev_fft_minus, dev_current_Psi_Minus, CUFFT_INVERSE ), "iFFT Exec" );
#endif
    // CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );
    //  Shift FFT Once again for visualization
    fftshift_2D<<<grid_size, block_size>>>( dev_fft_plus, dev_fft_minus, system.s_N / 2 );
    CHECK_CUDA_ERROR( {}, "FFT Shift" );
}

/**
 * Iterates the Runge-Kutta-Method on the GPU
 * Note, that all device arrays and variables have to be initialized at this point
 * @param evaluate_pulse If true, the pulse is evaluated at the current time step
 * @param t Current time, will be updated to t + dt
 * @param dt Time step, will be updated to the next time step
 * @param s_N Number of grid points in one dimension
 */
void rungeFunctionIterate( System& system, bool evaluate_pulse ) {
    dim3 block_size( 16, 16 );
    dim3 grid_size( ( system.s_N + block_size.x ) / block_size.x, ( system.s_N + block_size.y ) / block_size.y );

    if ( system.fixed_time_step )
        iterateFixedTimestepRungeKutta( system, evaluate_pulse, block_size, grid_size );
    else
        iterateVariableTimestepRungeKutta( system, evaluate_pulse, block_size, grid_size );

    // Increase t.
    system.t = system.t + system.dt;

    // For statistical purposes, increase the iteration counter
    system.iteration++;

    // Syncronize
    CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );

    // Test: Calculate the FFT of dev_current_Psi_Plus using cufft
    if ( system.t - cached_t < system.fft_every )
        return;
    cached_t = system.t;
    calculateFFT( system, block_size, grid_size );

    // Syncronize
    CHECK_CUDA_ERROR( cudaDeviceSynchronize(), "Sync" );
}