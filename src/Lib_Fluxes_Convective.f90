!> @ingroup Library
!> @{
!> @defgroup Lib_Fluxes_ConvectiveLibrary Lib_Fluxes_Convective
!> @}

!> @ingroup PublicProcedure
!> @{
!> @defgroup Lib_Fluxes_ConvectivePublicProcedure Lib_Fluxes_Convective
!> @}

!> @ingroup PrivateProcedure
!> @{
!> @defgroup Lib_Fluxes_ConvectivePrivateProcedure Lib_Fluxes_Convective
!> @}

!> This module contains the definition of procedures for computing convective fluxes (hyperbolic operator).
!> This is a library module.
!> @todo \b DocComplete: Complete the documentation of internal procedures
!> @todo \b RotatedRieman: Implement Rotated Rieman Solver technique
!> @ingroup Lib_Fluxes_ConvectiveLibrary
module Lib_Fluxes_Convective
!-----------------------------------------------------------------------------------------------------------------------------------
USE IR_Precision                                              ! Integers and reals precision definition.
USE Data_Type_Cell                                            ! Definition of Type_Cell.
USE Data_Type_Conservative                                    ! Definition of Type_Conservative.
USE Data_Type_Face                                            ! Definition of Type_Face.
USE Data_Type_Primitive                                       ! Definition of Type_Primitive.
USE Data_Type_Vector                                          ! Definition of Type_Vector.
USE Lib_Riemann, only: &
#ifdef SMSWliu
                       chk_smooth_liu,        &               ! Liu's smoothness function.
#elif defined SMSWvanleer || defined SMSWvanalbada || defined SMSWharten
                       chk_smooth_limiter,    &               ! Slope limiter-based smoothness function.
#else
                       chk_smooth_z,          &               ! Riemann-Solver-like smoothness function.
#endif
#if defined RSHLLCb || defined RSHLLCc || defined RSHLLCp || defined RSHLLCt || defined RSHLLCz
                       Riem_Solver=>Riem_Solver_HLLC          ! HLLC Riemann solver.
#elif RSEXA
                       Riem_Solver=>Riem_Solver_Exact_U       ! Exact Riemann solver.
#elif RSPVL
                       Riem_Solver=>Riem_Solver_PVL           ! PVL Riemann solver.
#elif RSTR
                       Riem_Solver=>Riem_Solver_TR            ! TR Riemann solver.
#elif RSTS
                       Riem_Solver=>Riem_Solver_TS            ! TS Riemann solver.
#elif RSAPRS
                       Riem_Solver=>Riem_Solver_APRS          ! APRS Riemann solver.
#elif RSALFR
                       Riem_Solver=>Riem_Solver_ALFR          ! ALFR Riemann solver.
#elif defined RSLFp || defined RSLFz
                       Riem_Solver=>Riem_Solver_LaxFriedrichs ! Lax-Friedrichs Riemann solver.
#elif RSROE
                       Riem_Solver=>Riem_Solver_Roe           ! Roe Riemann solver.
#else
                       Riem_Solver=>Riem_Solver_HLLC          ! HLLC Riemann solver.
#endif
USE Lib_WENO,    only: &
#ifdef HYBRIDC
                       noweno_central, &                      ! Function for comp. central diff. reconstruction.
#elif HYBRID
                       weno_optimal,   &                      ! Function for comp. optimal WENO reconstruction.
#endif
                       weno                                   ! Function for computing WENO reconstruction.
USE Lib_Thermodynamic_Laws_Ideal, only: a                     ! Function for computing speed of sound.
!-----------------------------------------------------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------------------------------------------------
implicit none
save
private
public:: fluxes_convective
!-----------------------------------------------------------------------------------------------------------------------------------
contains
  !> Subroutine for computing interfaces convective fluxes (hyperbolic operator). Taking in input the primitive variables along a
  !> 1D slice of N+2*gc cells the subroutine returns in ouput the N+1 convective fluxes at cells interfaces.
  !> @note For avoiding the creation of temporary arrays (improving the efficiency) the arrays \b NF, \b P and \b F are declared as
  !> assumed-shape with only the lower bound defined. Their extentions are: NF [0-gc:N+gc], P [1-gc:N+gc], F [0:N].
  !> @note The 3D primitive variables are projected (and remapped) in a 1D array as following:
  !>  - 1)    density of species 1    (r1)
  !>  - 2)    density of species 2    (r2)
  !>  - ...
  !>  - s)    density of species s-th (rs)
  !>  - ...
  !>  - Ns)   density of species Ns   (rNs)
  !>  - Ns+1) velocity                (velocity vector module along a specific direction...)
  !>  - Ns+2) pressure                (p)
  !>  - Ns+3) density                 (r=sum(rs))
  !>  - Ns+4) specific heats ratio    (g)
  !> @ingroup Lib_Fluxes_ConvectivePublicProcedure
  pure subroutine fluxes_convective(gc,N,Ns,cp0,cv0,F,C,Fl)
  !---------------------------------------------------------------------------------------------------------------------------------
  implicit none
  integer(I1P),            intent(IN)::    gc                         !< Number of ghost cells used.
  integer(I_P),            intent(IN)::    N                          !< Number of cells.
  integer(I_P),            intent(IN)::    Ns                         !< Number of species.
  real(R_P),               intent(IN)::    cp0(1:Ns)                  !< Initial specific heat cp.
  real(R_P),               intent(IN)::    cv0(1:Ns)                  !< Initial specific heat cv.
  type(Type_Face),         intent(IN)::    F  (           0-gc:     ) !< Faces data [0-gc:N+gc].
  type(Type_Cell),         intent(IN)::    C  (           1-gc:     ) !< Cells data [1-gc:N+gc].
  type(Type_Conservative), intent(INOUT):: Fl (              0:     ) !< Convective fluxes (3D format)   [   0:N   ].
  type(Type_Vector)::                      ut (       1:2,1-gc:N+gc ) !< Tangential velocity: left (1) and right (2) interfaces.
#ifdef LMA
  real(R_P)::                              ulma(1:2)                  !< Left (1) and right (2) reconstructed normal speed adjusted
                                                                      !< for low Mach number flows.
  real(R_P)::                              z                          !< Scaling coefficient for Low Mach number Adjustment.
#endif
  real(R_P)::                              PR (1:Ns+4,1:2,   0:N+1  ) !< Reconstructed interface values of 1D primitive variables.
  real(R_P)::                              F_r                        !< Flux of mass (1D).
  real(R_P)::                              F_u                        !< Flux of momentum (1D).
  real(R_P)::                              F_E                        !< Flux of energy (1D).
  integer(I_P)::                           i,j                        !< Counters.
  !---------------------------------------------------------------------------------------------------------------------------------

  !---------------------------------------------------------------------------------------------------------------------------------
  ! computing velocity vectors and its tangential component
  do i=1-gc,N+gc
    ! computing tangential velocity component
    do j=1,2 ! 1 => left interface (i-1/2), 2 => right interface (i+1/2)
      if (i==1-gc.AND.j==1) cycle
      if (i==N+gc.AND.j==2) cycle
      ut(j,i) = C(i)%P%v - (C(i)%P%v.paral.F(i+j-2)%N) ! ut
    enddo
  enddo
  ! computing the left and right states or Riemann Problems
  select case(gc)
  case(2_I1P,3_I1P,4_I1P) ! 3rd, 5th or 7th order WENO reconstruction
    ! computing the reconstruction
    call preconstruct_n(gc=gc,N=N,Ns=Ns,cp0=cp0,cv0=cv0,F=F,C=C,PR=PR)
  case(1_I1P) ! 1st order piecewise constant reconstruction
    do i=0,N+1
      do j=1,2 ! 1 => left interface (i-1/2), 2 => right interface (i+1/2)
        if (i==0  .AND.j==1) cycle
        if (i==N+1.AND.j==2) cycle
        PR(1:Ns,j,i) =  C(i)%P%r(1:Ns)           ! rs
        PR(Ns+1,j,i) = (C(i)%P%v.dot.F(i+j-2)%N) ! un
        PR(Ns+2,j,i) =  C(i)%P%p                 ! p
        PR(Ns+3,j,i) =  C(i)%P%d                 ! r
        PR(Ns+4,j,i) =  C(i)%P%g                 ! g
      enddo
    enddo
  endselect
#ifdef LMA
  ! applying Low Mach number Adjustment for decreasing the dissipation in local low Mach number region
  do i=0,N
    z = min(1._R_P,max(sqrt(PR(Ns+1,2,i  )*PR(Ns+1,2,i  )+sq_norm(ut(2,i  )))/a(p=P(i  )%p,r=P(i  )%d,g=P(i  )%g),&
                       sqrt(PR(Ns+1,1,i+1)*PR(Ns+1,1,i+1)+sq_norm(ut(1,i+1)))/a(p=P(i+1)%p,r=P(i+1)%d,g=P(i+1)%g)))
    ulma(1) = 0.5_R_P*(PR(Ns+1,2,i) + PR(Ns+1,1,i+1)) + z*0.5_R_P*(PR(Ns+1,2,i) - PR(Ns+1,1,i+1))
    ulma(2) = 0.5_R_P*(PR(Ns+1,2,i) + PR(Ns+1,1,i+1)) - z*0.5_R_P*(PR(Ns+1,2,i) - PR(Ns+1,1,i+1))
    PR(Ns+1,2,i  ) = ulma(1)
    PR(Ns+1,1,i+1) = ulma(2)
  enddo
#endif
  ! solving Riemann Problems
  do i=0,N
    ! face normal fluxes
    call Riem_Solver(p1  = PR(Ns+2,2,i  ), & !| right value of cell i   (letf  of interface i+1/2)
                     r1  = PR(Ns+3,2,i  ), & !|
                     u1  = PR(Ns+1,2,i  ), & !|
                     g1  = PR(Ns+4,2,i  ), & !|
#if defined RSHLLCb || defined RSROE
                     cp1 = dot_product(PR(1:Ns,2,i)/PR(Ns+3,2,i),cp0), &
                     cv1 = dot_product(PR(1:Ns,2,i)/PR(Ns+3,2,i),cv0), &
#endif
                     p4  = PR(Ns+2,1,i+1), & !| left  value of cell i+1 (right of interface i+1/2)
                     r4  = PR(Ns+3,1,i+1), & !|
                     u4  = PR(Ns+1,1,i+1), & !|
                     g4  = PR(Ns+4,1,i+1), & !|
#if defined RSHLLCb || defined RSROE
                     cp4 = dot_product(PR(1:Ns,1,i+1)/PR(Ns+3,1,i+1),cp0), &
                     cv4 = dot_product(PR(1:Ns,1,i+1)/PR(Ns+3,1,i+1),cv0), &
#endif
                     F_r = F_r           , &
                     F_u = F_u           , &
                     F_E = F_E)
    ! uptdating fluxes with tangential components
    if (F_r>0._R_P) then
      Fl(i)%rs = F_r*PR(1:Ns,2,i  )/PR(Ns+3,2,i  )
      Fl(i)%rv = F_u*F(i)%N + F_r*ut(2,i)
      Fl(i)%re = F_E + F_r*sq_norm(ut(2,i))*0.5_R_P
    else
      Fl(i)%rs = F_r*PR(1:Ns,1,i+1)/PR(Ns+3,1,i+1)
      Fl(i)%rv = F_u*F(i)%N + F_r*ut(1,i+1)
      Fl(i)%re = F_E + F_r*sq_norm(ut(1,i+1))*0.5_R_P
    endif
  enddo
  return
  !---------------------------------------------------------------------------------------------------------------------------------
  contains
    !> Subroutine for reconstructing primitive variables along direction "NF".
    !> @ingroup Lib_Fluxes_ConvectivePrivateProcedure
    pure subroutine preconstruct_n(gc,N,Ns,cp0,cv0,F,C,PR)
    !-------------------------------------------------------------------------------------------------------------------------------
    implicit none
    integer(I1P),    intent(IN)::  gc                                !< Number of ghost cells used.
    integer(I_P),    intent(IN)::  N                                 !< Number of cells.
    integer(I_P),    intent(IN)::  Ns                                !< Number of species.
    real(R_P),       intent(IN)::  cp0(1:Ns)                         !< Initial specific heat cp.
    real(R_P),       intent(IN)::  cv0(1:Ns)                         !< Initial specific heat cv.
    type(Type_Face), intent(IN)::  F  (                  0-gc: N+gc) !< Faces data [0-gc:N+gc].
    type(Type_Cell), intent(IN)::  C  (                  1-gc: N+gc) !< Cells data [1-gc:N+gc].
    real(R_P),       intent(OUT):: PR (1:Ns+4,       1:2,   0: N+1 ) !< Reconstructed interface values 1D primitive variables.
    real(R_P)::                    P1D(1:Ns+2,       1:2,1-gc:-1+gc) !< 1D primitive variables at interfaces.
#ifdef RECVC
    real(R_P)::                    Pm (1:Ns+4                      ) !< Mean of primitive variables across interfaces.
    real(R_P)::                    LPm(1:Ns+2,1:Ns+2,1:2           ) !< Mean left eigenvectors matrix.
    real(R_P)::                    RPm(1:Ns+2,1:Ns+2,1:2           ) !< Mean right eigenvectors matrix.
    real(R_P)::                    CA (1:Ns+2,       1:2,1-gc:-1+gc) !< Interface value of characteristic variables.
    real(R_P)::                    CR (1:Ns+2,       1:2           ) !< Reconstructed interface value of charac. variables.
#endif
    logical::                      ROR(1:2)                          !< Logical flag for testing the result of WENO reconst.
    integer(I1P)::                 or                                !< Counter of order for ROR algorithm.
    integer(I_P)::                 i,j,k,v                           !< Counters.
    !-------------------------------------------------------------------------------------------------------------------------------

    !-------------------------------------------------------------------------------------------------------------------------------
    do i=0,N+1 ! loop over cells
      ! computing 1D primitive variables for the stencil [i+1-gc,i-1+gc] fixing the velocity across the interfaces i+-1/2
      do k=i+1-gc,i-1+gc
        do j=1,2 ! 1 => left interface (i-1/2), 2 => right interface (i+1/2)
          if (i==0  .AND.j==1) cycle
          if (i==N+1.AND.j==2) cycle
          P1D(1:Ns,j,k-i) =  C(k)%P%r(1:Ns)
          P1D(Ns+1,j,k-i) = (C(k)%P%v.dot.F(i+j-2)%N)
          P1D(Ns+2,j,k-i) =  C(k)%P%p
        enddo
      enddo
#ifdef RECVC
      ! computing mean left and right eigenvectors matrix across the interface
      LPm = 0._R_P
      RPm = 0._R_P
      do j=1,2 ! 1 => left interface (i-1/2), 2 => right interface (i+1/2)
        if (i==0  .AND.j==1) cycle
        if (i==N+1.AND.j==2) cycle
        ! computing mean of primitive variables across the interface
        Pm(1:Ns) = 0.5_R_P*( C(i+j-1)%P%r(1:Ns)           +  C(i+j-2)%P%r(1:Ns)          ) ! rs
        Pm(Ns+1) = 0.5_R_P*((C(i+j-1)%P%v.dot.F(i+j-2)%N) + (C(i+j-2)%P%v.dot.F(i+j-2)%N)) ! un
        Pm(Ns+2) = 0.5_R_P*( C(i+j-1)%P%p                 +  C(i+j-2)%P%p                ) ! p
        Pm(Ns+3) = 0.5_R_P*( C(i+j-1)%P%d                 +  C(i+j-2)%P%d                ) ! r
        Pm(Ns+4) = 0.5_R_P*( C(i+j-1)%P%g                 +  C(i+j-2)%P%g                ) ! g
        ! computing mean left and right eigenvectors matrix across the interface
        LPm(1:Ns+2,1:Ns+2,j) = LP(Ns,Pm(1:Ns+4))
        RPm(1:Ns+2,1:Ns+2,j) = RP(Ns,Pm(1:Ns+4))
      enddo
      ! transforming variables into local characteristic fields for the stencil [1-gc,-1+gc]
      CA = 0._R_P
      do k=i+1-gc,i-1+gc
        do j=1,2 ! 1 => left interface (i-1/2), 2 => right interface (i+1/2)
          if (i==0  .AND.j==1) cycle
          if (i==N+1.AND.j==2) cycle
          do v=1,Ns+2
            CA(v,j,k-i) = dot_product(LPm(v,1:Ns+2,j),P1D(1:Ns+2,j,k-i))
          enddo
        enddo
      enddo
#endif
      ! computing WENO reconstruction with ROR (Recursive Order Reduction) algorithm
      ROR_check: do or=gc,2_I1P,-1_I1P
        ! computing WENO reconstruction
#ifdef RECVC
        do v=1,Ns+2
          !CR(v,1:2) = weno(S=or,V=C(v,1:2,1-or:-1+or))
          call weno(S=or,V=CA(v,1:2,1-or:-1+or),VR=CR(v,1:2))
        enddo
        ! trasforming local reconstructed characteristic variables to primitive ones
        do j=1,2 ! 1 => left interface (i-1/2), 2 => right interface (i+1/2)
          if (i==0  .AND.j==1) cycle
          if (i==N+1.AND.j==2) cycle
          do v=1,Ns+2
            PR(v,j,i) = dot_product(RPm(v,1:Ns+2,j),CR(1:Ns+2,j))
          enddo
        enddo
#else
        do v=1,Ns+2
          !PR(v,1:2,i) = weno(S=or,V=P1D(v,1:2,1-or:-1+or))
          call weno(S=or,V=P1D(v,1:2,1-or:-1+or),VR=PR(v,1:2,i))
        enddo
#endif
        ! extrapolation of the reconstructed values for the non computed boundaries
        if (i==0  ) PR(1:Ns+2,1,i) = PR(1:Ns+2,2,i)
        if (i==N+1) PR(1:Ns+2,2,i) = PR(1:Ns+2,1,i)
#ifdef PPL
        ! applaying the maximum-principle-satisfying limiter to the reconstructed densities and pressure
        do v=1,Ns
          call positivity_preserving_limiter(o = or, vmean = C(i)%P%r(v), vr = PR(v,1:2,i)) ! densities
        enddo
        call positivity_preserving_limiter(o = or, vmean = C(i)%P%p, vr = PR(Ns+2,1:2,i))   ! pressure
#endif
        ! computing the reconstructed variables of total density and specific heats ratio
        do j=1,2 ! 1 => left interface (i-1/2), 2 => right interface (i+1/2)
          if (i==0  .AND.j==1) cycle
          if (i==N+1.AND.j==2) cycle
          PR(Ns+3,j,i) = sum(PR(1:Ns,j,i))
          PR(Ns+4,j,i) = dot_product(PR(1:Ns,j,i)/PR(Ns+3,j,i),cp0(1:Ns))/dot_product(PR(1:Ns,j,i)/PR(Ns+3,j,i),cv0(1:Ns))
        enddo
        ! verifing the WENO reconstruction at order or-th
        ROR = .true.
        do j=1,2 ! 1 => left interface (i-1/2), 2 => right interface (i+1/2)
          if (i==0  .AND.j==1) cycle
          if (i==N+1.AND.j==2) cycle
          ROR(j) = ((PR(Ns+2,j,i)>0._R_P).AND.(PR(Ns+3,j,i)>0._R_P).AND.(PR(Ns+4,j,i)>0._R_P))
        enddo
        if (ROR(1).AND.ROR(2)) exit ROR_check
        if (or==2) then
          ! the high order reconstruction is falied; used 1st order reconstruction
          do j=1,2 ! 1 => left interface (i-1/2), 2 => right interface (i+1/2)
            if (i==0  .AND.j==1) cycle
            if (i==N+1.AND.j==2) cycle
            PR(1:Ns,j,i) =  C(i)%P%r(1:Ns)           ! rs
            PR(Ns+1,j,i) = (C(i)%P%v.dot.F(i+j-2)%N) ! un
            PR(Ns+2,j,i) =  C(i)%P%p                 ! p
            PR(Ns+3,j,i) =  C(i)%P%d                 ! r
            PR(Ns+4,j,i) =  C(i)%P%g                 ! g
          enddo
        endif
      enddo ROR_check
    enddo
    return
    !-------------------------------------------------------------------------------------------------------------------------------
    endsubroutine preconstruct_n

    !> Function for computing left eigenvectors matrix (L) of the Jacobian fluxes matrix \f$A=R \Lambda L\f$ in primitive variables
    !> form.
    !> @note This function consider only the normal direction:
    !> \f$ \frac{\partial P}{\partial t} + R \Lambda L \frac{\partial P}{\partial n} = 0\f$ where P are the primitive variables and
    !> n is the normal direction. R is the matrix of the right eigenvectors, \f$\Lambda\f$ is the diagonal matrix of the eigenvalues
    !> and L is the matrix of the left eigenvectors.
    !> @ingroup Lib_Fluxes_ConvectivePrivateProcedure
    pure function LP(Ns,primitive) result(L)
    !-------------------------------------------------------------------------------------------------------------------------------
    implicit none
    integer(I_P), intent(IN):: Ns                ! Number of species.
    real(R_P),    intent(IN):: primitive(1:Ns+4) ! Primitive variables.
    real(R_P)::                L(1:Ns+2,1:Ns+2)  ! Left eigenvectors matrix.
    real(R_P)::                gp                ! g*p.
    real(R_P)::                a                 ! Speed of sound.
    integer(I_P)::             i                 ! Counter.
    !-------------------------------------------------------------------------------------------------------------------------------

    !-------------------------------------------------------------------------------------------------------------------------------
    ! initializing
    gp = primitive(Ns+4)*primitive(Ns+2)
    a  = sqrt(gp/primitive(Ns+3))
    L  = 0._R_P
    ! assigning non-zero values of L
      L(1,   Ns+1) = -gp/a              ; L(1,   Ns+2) =  1._R_P
    do i=2,Ns+1
      L(i,   i-1 ) =  gp/primitive(i-1) ; L(i,   Ns+2) = -1._R_P
    enddo
      L(Ns+2,Ns+1) =  gp/a              ; L(Ns+2,Ns+2) =  1._R_P
    return
    !-------------------------------------------------------------------------------------------------------------------------------
    endfunction LP

    !> Function for computing right eigenvectors matrix (R) of the Jacobian fluxes matrix \f$A=R \Lambda L\f$ in primitive variables
    !> form.
    !> @note This function consider only the normal direction:
    !> \f$ \frac{\partial P}{\partial t} + R \Lambda L \frac{\partial P}{\partial n} = 0\f$ where P are the primitive variables and
    !> n is the normal direction. R is the matrix of the right eigenvectors, \f$\Lambda\f$ is the diagonal matrix of the eigenvalues
    !> and L is the matrix of the left eigenvectors.
    !> @ingroup Lib_Fluxes_ConvectivePrivateProcedure
    pure function RP(Ns,primitive) result(R)
    !-------------------------------------------------------------------------------------------------------------------------------
    implicit none
    integer(I_P), intent(IN):: Ns                ! Number of species.
    real(R_P),    intent(IN):: primitive(1:Ns+4) ! Primitive variables.
    real(R_P)::                R(1:Ns+2,1:Ns+2)  ! Right eigenvectors matrix.
    real(R_P)::                gp                ! g*p.
    real(R_P)::                gp_inv            ! 1/(g*p).
    real(R_P)::                a                 ! Speed of sound.
    integer(I_P)::             i                 ! Counter.
    !-------------------------------------------------------------------------------------------------------------------------------

    !-------------------------------------------------------------------------------------------------------------------------------
    ! initializing
    gp     = primitive(Ns+4)*primitive(Ns+2)
    a      = sqrt(gp/primitive(Ns+3))
    gp_inv = 1._R_P/gp
    R = 0._R_P
    ! assigning non-zero values of R
    do i=1,Ns+1
      R(i,   1) =  0.5_R_P*primitive(i)*gp_inv ; R(i,i+1) = primitive(i)*gp_inv ; R(i,   Ns+2) = R(i,1)
    enddo
      R(Ns+1,1) = -0.5_R_P*a*gp_inv ;                                             R(Ns+1,Ns+2) = 0.5_R_P*a*gp_inv
      R(Ns+2,1) =  0.5_R_P          ;                                             R(Ns+2,Ns+2) = 0.5_R_P
    return
    !-------------------------------------------------------------------------------------------------------------------------------
    endfunction RP

    !> Positivity preserving limiter.
    !> @ingroup Lib_Fluxes_ConvectivePrivateProcedure
    pure subroutine positivity_preserving_limiter(o,vmean,vr)
    !-------------------------------------------------------------------------------------------------------------------------------
    implicit none
    integer(I_P), intent(IN)::    o                                        ! Order of space reconstruction.
    real(R_P),    intent(IN)::    vmean                                    ! Mean value.
    real(R_P),    intent(INOUT):: vr(1:2)                                  ! Reconstructed values.
    real(R_P), parameter::        w1(2:4)=[1._R_P/6._R_P,  &               ! Weights of Gauss-Lobatto's 3 points quadrature.
                                           1._R_P/12._R_P, &               ! Weights of Gauss-Lobatto's 4 points quadrature.
                                           1._R_P/20._R_P]                 ! Weights of Gauss-Lobatto's 5 points quadrature.
    real(R_P), parameter::        w2(2:4)=[1._R_P/(1._R_P-2._R_P*w1(2)), & ! 1/(1-2*w1)
                                           1._R_P/(1._R_P-2._R_P*w1(3)), & ! 1/(1-2*w1)
                                           1._R_P/(1._R_P-2._R_P*w1(4))]   ! 1/(1-2*w1)
    real(R_P), parameter::        e  = tiny(1._R_P)                        ! Small number for avoid division for zero.
    real(R_P)::                   vstar                                    ! Star value.
    real(R_P)::                   theta                                    ! Limiter coefficient.
    !-------------------------------------------------------------------------------------------------------------------------------

    !-------------------------------------------------------------------------------------------------------------------------------
    vstar = (vmean - w1(o)*(vr(1) + vr(2)))*w2(o)
    theta = min((vmean-0.1_R_P*vmean)/(vmean - min(vstar,vr(1),vr(2)) + e),1._R_P)
    vr(1) = theta*(vr(1) - vmean) + vmean
    vr(2) = theta*(vr(2) - vmean) + vmean
    return
    !-------------------------------------------------------------------------------------------------------------------------------
    endsubroutine positivity_preserving_limiter
  endsubroutine fluxes_convective
endmodule Lib_Fluxes_Convective
