#pragma once
#include "cuda/typedef.cuh"
#include "cuda/cuda_macro.cuh"
#include "solver/gpu_solver.hpp"

namespace PC3::Kernel::Compute {

static PULSE_GLOBAL PULSE_CPU_INLINE void gp_tetm( int i, Type::uint32 current_halo, Solver::VKernelArguments time, Solver::KernelArguments args, Solver::InputOutput io ) {
    GENERATE_SUBGRID_INDEX( i, current_halo );

    const Type::complex in_wf_plus = io.in_wf_plus[i];
    const Type::complex in_wf_minus = io.in_wf_minus[i];

    Type::complex horizontal_plus = ( io.in_wf_plus[i + 1] + io.in_wf_plus[i - 1] ) * args.p.one_over_dx2;
    Type::complex vertical_plus = ( io.in_wf_plus[i + args.p.subgrid_row_offset] + io.in_wf_plus[i - args.p.subgrid_row_offset] ) * args.p.one_over_dy2;
    Type::complex horizontal_minus = ( io.in_wf_minus[i + 1] + io.in_wf_minus[i - 1] ) * args.p.one_over_dx2;
    Type::complex vertical_minus = ( io.in_wf_minus[i + args.p.subgrid_row_offset] + io.in_wf_minus[i - args.p.subgrid_row_offset] ) * args.p.one_over_dy2;
    Type::complex hamilton_cross_plus = horizontal_minus - vertical_minus +
                                        args.p.half_i / args.p.dx / args.p.dy *
                                            ( io.in_wf_minus[i + args.p.subgrid_row_offset + 1] + io.in_wf_minus[i - args.p.subgrid_row_offset - 1] -
                                              io.in_wf_minus[i + args.p.subgrid_row_offset - 1] - io.in_wf_minus[i - args.p.subgrid_row_offset + 1] );
    Type::complex hamilton_cross_minus = horizontal_plus - vertical_plus -
                                         args.p.half_i / args.p.dx / args.p.dy *
                                             ( io.in_wf_plus[i + args.p.subgrid_row_offset + 1] + io.in_wf_plus[i - args.p.subgrid_row_offset - 1] -
                                               io.in_wf_plus[i + args.p.subgrid_row_offset - 1] - io.in_wf_plus[i - args.p.subgrid_row_offset + 1] );
    Type::complex hamilton_regular_plus = args.p.m2_over_dx2_p_dy2 * in_wf_plus + horizontal_plus + vertical_plus;
    Type::complex hamilton_regular_minus = args.p.m2_over_dx2_p_dy2 * in_wf_minus + horizontal_minus + vertical_minus;

    const Type::complex in_rv_plus = io.in_rv_plus[i];
    const Type::complex in_rv_minus = io.in_rv_minus[i];
    const Type::real in_psi_plus_norm = CUDA::abs2( in_wf_plus );
    const Type::real in_psi_minus_norm = CUDA::abs2( in_wf_minus );

    // MARK: Wavefunction Plus
    Type::complex result = args.p.minus_i_over_h_bar_s * args.p.m_eff_scaled * hamilton_regular_plus;

    for ( int k = 0; k < args.potential_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        const Type::complex potential = args.dev_ptrs.potential_plus[i + offset] * args.potential_pointers.amp[k];
        result += args.p.minus_i_over_h_bar_s * potential * in_wf_plus;
    }

    result += args.p.minus_i_over_h_bar_s * args.p.g_c * in_psi_plus_norm * in_wf_plus;
    result += args.p.minus_i_over_h_bar_s * args.p.g_r * in_rv_plus * in_wf_plus;
    result += Type::real( 0.5 ) * args.p.R * in_rv_plus * in_wf_plus;
    result -= Type::real( 0.5 ) * args.p.gamma_c * in_wf_plus;

    result += args.p.minus_i_over_h_bar_s * args.p.g_pm * in_psi_minus_norm * in_wf_plus;
    result += args.p.minus_i_over_h_bar_s * args.p.delta_LT * hamilton_cross_plus;

    // MARK: Pulse Plus
    for ( int k = 0; k < args.pulse_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        const Type::complex pulse = args.dev_ptrs.pulse_plus[i + offset];
        result += args.p.one_over_h_bar_s * pulse * args.pulse_pointers.amp[k];
    }

    // MARK: Stochastic
    if ( args.p.stochastic_amplitude > 0.0 ) {
        const Type::complex dw = args.dev_ptrs.random_number[i] * CUDA::sqrt( ( args.p.R * in_rv_plus + args.p.gamma_c ) / ( Type::real( 4.0 ) * args.p.dV ) );
        result -= args.p.minus_i_over_h_bar_s * args.p.g_c * in_wf_plus / args.p.dV;
    }

    io.out_wf_plus[i] = result;

    // MARK: Reservoir Plus
    result = -( args.p.gamma_r + args.p.R * in_psi_plus_norm ) * in_rv_plus;

    for ( int k = 0; k < args.pump_pointers.n; k++ ) {
        const auto gauss = args.pump_pointers.amp[k];
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        ;
        result += args.dev_ptrs.pump_plus[i + offset] * gauss;
    }

    // MARK: Stochastic-2
    if ( args.p.stochastic_amplitude > 0.0 )
        result += args.p.R * in_rv_plus / args.p.dV;

    io.out_rv_plus[i] = result;

    // MARK: Wavefunction Minus
    result = args.p.minus_i_over_h_bar_s * args.p.m_eff_scaled * hamilton_regular_minus;

    for ( int k = 0; k < args.potential_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        const Type::complex potential = args.dev_ptrs.potential_minus[i + offset] * args.potential_pointers.amp[k];
        result += args.p.minus_i_over_h_bar_s * potential * in_wf_minus;
    }

    result += args.p.minus_i_over_h_bar_s * args.p.g_c * in_psi_minus_norm * in_wf_minus;
    result += args.p.minus_i_over_h_bar_s * args.p.g_r * in_rv_minus * in_wf_minus;
    result += Type::real( 0.5 ) * args.p.R * in_rv_minus * in_wf_minus;
    result -= Type::real( 0.5 ) * args.p.gamma_c * in_wf_minus;

    result += args.p.minus_i_over_h_bar_s * args.p.g_pm * in_psi_plus_norm * in_wf_minus;
    result += args.p.minus_i_over_h_bar_s * args.p.delta_LT * hamilton_cross_minus;

    // MARK: Pulse Minus
    for ( int k = 0; k < args.pulse_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        const Type::complex pulse = args.dev_ptrs.pulse_minus[i + offset];
        result += args.p.one_over_h_bar_s * pulse * args.pulse_pointers.amp[k];
    }

    if ( args.p.stochastic_amplitude > 0.0 ) {
        const Type::complex dw = args.dev_ptrs.random_number[i] * CUDA::sqrt( ( args.p.R * in_rv_minus + args.p.gamma_c ) / ( Type::real( 4.0 ) * args.p.dV ) );
        result -= args.p.minus_i_over_h_bar_s * args.p.g_c * in_wf_minus / args.p.dV;
    }

    io.out_wf_minus[i] = result;

    // MARK: Reservoir Minus
    result = -( args.p.gamma_r + args.p.R * in_psi_minus_norm ) * in_rv_minus;

    for ( int k = 0; k < args.pump_pointers.n; k++ ) {
        const auto gauss = args.pump_pointers.amp[k];
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        result += args.dev_ptrs.pump_minus[i + offset] * gauss;
    }

    // MARK: Stochastic-2
    if ( args.p.stochastic_amplitude > 0.0 )
        result += args.p.R * in_rv_minus / args.p.dV;

    io.out_rv_minus[i] = result;
}

/**
     * Linear, Nonlinear and Independet parts of the upper Kernel
     * These isolated implementations serve for the Split Step
     * Fourier Method (SSFM)
    */

static PULSE_GLOBAL PULSE_CPU_INLINE void gp_tetm_linear_fourier( int i, Solver::VKernelArguments time, Solver::KernelArguments args, Solver::InputOutput io ) {
    GET_THREAD_INDEX( i, args.p.N2 );

    // We do some weird looking casting to avoid intermediate casts to Type::uint32
    Type::real row = Type::real( Type::uint32( i / args.p.N_c ) );
    Type::real col = Type::real( Type::uint32( i % args.p.N_c ) );

    const Type::real k_x = 2.0 * 3.1415926535 * Type::real( col <= args.p.N_c / 2 ? col : -Type::real( args.p.N_c ) + col ) / args.p.L_x;
    const Type::real k_y = 2.0 * 3.1415926535 * Type::real( row <= args.p.N_r / 2 ? row : -Type::real( args.p.N_r ) + row ) / args.p.L_y;

    Type::real linear = args.p.h_bar_s / 2.0 / args.p.m_eff * ( k_x * k_x + k_y * k_y );
    io.out_wf_plus[i] = io.in_wf_plus[i] / Type::real( args.p.N2 ) * CUDA::exp( args.p.minus_i * linear * time.dt / Type::real( 2.0 ) );
    io.out_wf_minus[i] = io.in_wf_minus[i] / Type::real( args.p.N2 ) * CUDA::exp( args.p.minus_i * linear * time.dt / Type::real( 2.0 ) );
}

static PULSE_GLOBAL PULSE_CPU_INLINE void gp_tetm_nonlinear( int i, Solver::VKernelArguments time, Solver::KernelArguments args, Solver::InputOutput io ) {
    GET_THREAD_INDEX( i, args.p.N2 );

    const Type::complex in_wf_plus = io.in_wf_plus[i];
    const Type::complex in_rv_plus = io.in_rv_plus[i];
    const Type::complex in_wf_minus = io.in_wf_minus[i];
    const Type::complex in_rv_minus = io.in_rv_minus[i];
    const Type::real in_psi_plus_norm = CUDA::abs2( in_wf_plus );
    const Type::real in_psi_minus_norm = CUDA::abs2( in_wf_minus );

    // MARK: Wavefunction Plus
    Type::complex result = { args.p.g_c * in_psi_plus_norm, -args.p.h_bar_s * Type::real( 0.5 ) * args.p.gamma_c };

    for ( int k = 0; k < args.potential_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        const Type::complex potential = args.dev_ptrs.potential_plus[i + offset] * args.potential_pointers.amp[k];
        result += potential;
    }

    result += args.p.g_r * in_rv_plus;
    result += args.p.i * args.p.h_bar_s * Type::real( 0.5 ) * args.p.R * in_rv_plus;

    Type::complex cross = args.p.g_pm * in_psi_minus_norm;
    //cross += args.p.delta_LT * hamilton_cross_plus;

    // MARK: Stochastic
    if ( args.p.stochastic_amplitude > 0.0 ) {
        const Type::complex dw = args.dev_ptrs.random_number[i] * CUDA::sqrt( ( args.p.R * in_rv_plus + args.p.gamma_c ) / ( Type::real( 4.0 ) * args.p.dV ) );
        result -= args.p.g_c / args.p.dV;
    }

    io.out_wf_plus[i] = in_wf_plus * CUDA::exp( args.p.minus_i_over_h_bar_s * ( result + cross ) * time.dt );

    // MARK: Reservoir
    result = -args.p.gamma_r * in_rv_plus;
    result -= args.p.R * in_psi_plus_norm * in_rv_plus;
    for ( int k = 0; k < args.pump_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        result += args.dev_ptrs.pump_plus[i + offset] * args.pump_pointers.amp[k];
    }
    // MARK: Stochastic-2
    if ( args.p.stochastic_amplitude > 0.0 )
        result += args.p.R * in_rv_plus / args.p.dV;
    io.out_rv_plus[i] = in_rv_plus + result * time.dt;

    // MARK: Wavefunction Minus
    result = Type::complex( args.p.g_c * in_psi_minus_norm, -args.p.h_bar_s * Type::real( 0.5 ) * args.p.gamma_c );

    for ( int k = 0; k < args.potential_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        const Type::complex potential = args.dev_ptrs.potential_minus[i + offset] * args.potential_pointers.amp[k];
        result += potential;
    }

    result += args.p.g_r * in_rv_minus;
    result += args.p.i * args.p.h_bar_s * Type::real( 0.5 ) * args.p.R * in_rv_minus;

    cross = args.p.g_pm * in_psi_plus_norm;
    //cross += args.p.delta_LT * hamilton_cross_minus;

    // MARK: Stochastic
    if ( args.p.stochastic_amplitude > 0.0 ) {
        const Type::complex dw = args.dev_ptrs.random_number[i] * CUDA::sqrt( ( args.p.R * in_rv_minus + args.p.gamma_c ) / ( Type::real( 4.0 ) * args.p.dV ) );
        result -= args.p.g_c / args.p.dV;
    }

    io.out_wf_minus[i] = in_wf_minus * CUDA::exp( args.p.minus_i_over_h_bar_s * ( result + cross ) * time.dt );

    // MARK: Reservoir
    result = -args.p.gamma_r * in_rv_minus;
    result -= args.p.R * in_psi_minus_norm * in_rv_minus;
    for ( int k = 0; k < args.pump_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        result += args.dev_ptrs.pump_minus[i + offset] * args.pump_pointers.amp[k];
    }
    // MARK: Stochastic-2
    if ( args.p.stochastic_amplitude > 0.0 )
        result += args.p.R * in_rv_minus / args.p.dV;
    io.out_rv_minus[i] = in_rv_minus + result * time.dt;
}

static PULSE_GLOBAL PULSE_CPU_INLINE void gp_tetm_independent( int i, Solver::VKernelArguments time, Solver::KernelArguments args, Solver::InputOutput io ) {
    GET_THREAD_INDEX( i, args.p.N2 );

    // MARK: Plus
    Type::complex result = { 0.0, 0.0 };

    // MARK: Pulse
    for ( int k = 0; k < args.pulse_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        const Type::complex pulse = args.dev_ptrs.pulse_plus[i + offset];
        result += args.p.minus_i_over_h_bar_s * time.dt * pulse *
                  args.pulse_pointers.amp[k]; //CUDA::gaussian_complex_oscillator(t, args.pulse_pointers.t0[k], args.pulse_pointers.sigma[k], args.pulse_pointers.freq[k]);
    }
    if ( args.p.stochastic_amplitude > 0.0 ) {
        const Type::complex in_rv = io.in_rv_plus[i];
        const Type::complex dw = args.dev_ptrs.random_number[i] * CUDA::sqrt( ( args.p.R * in_rv + args.p.gamma_c ) / ( Type::real( 4.0 ) * args.p.dV ) );
        result += dw;
    }
    io.out_wf_plus[i] = io.in_wf_plus[i] + result;

    // MARK: Minus
    result = 0.0;

    // MARK: Pulse
    for ( int k = 0; k < args.pulse_pointers.n; k++ ) {
        PC3::Type::uint32 offset = args.p.subgrid_N2_with_halo * k;
        const Type::complex pulse = args.dev_ptrs.pulse_minus[i + offset];
        result += args.p.minus_i_over_h_bar_s * time.dt * pulse *
                  args.pulse_pointers.amp[k]; //CUDA::gaussian_complex_oscillator(t, args.pulse_pointers.t0[k], args.pulse_pointers.sigma[k], args.pulse_pointers.freq[k]);
    }
    if ( args.p.stochastic_amplitude > 0.0 ) {
        const Type::complex in_rv = io.in_rv_minus[i];
        const Type::complex dw = args.dev_ptrs.random_number[i] * CUDA::sqrt( ( args.p.R * in_rv + args.p.gamma_c ) / ( Type::real( 4.0 ) * args.p.dV ) );
        result += dw;
    }
    io.out_wf_minus[i] = io.in_wf_minus[i] + result;
}

} // namespace PC3::Kernel::Compute