
!Copyright (c) 2012-2022, Xcompact3d
!This file is part of Xcompact3d (xcompact3d.com)
!SPDX-License-Identifier: BSD 3-Clause

module actuator_disc_model

    use decomp_2d_mpi, only: nrank, nproc
    use decomp_2d_constants, only: mytype, real_type
    use actuator_line_model_utils 
    use airfoils
    use iso_c_binding
    use smartredis_client, only : client_type

    implicit none

    type, bind(C), private :: poll_timespec
        integer(c_long) :: seconds
        integer(c_long) :: nanoseconds
    end type poll_timespec

    interface
        function poll_nanosleep(requested, remaining) bind(C, name='nanosleep') result(status)
            import c_int, poll_timespec
            type(poll_timespec), intent(in) :: requested
            type(poll_timespec), intent(out) :: remaining
            integer(c_int) :: status
        end function poll_nanosleep
    end interface
    private :: poll_nanosleep
    
type ActuatorDiscType
    integer :: ID                       ! Actuator disc ID
    real(mytype) :: D                   ! Actuator disc diameter 
    real(mytype) :: COR(3)              ! Centre of rotation
    real(mytype) :: RotN(3)             ! Axis of rotation
    real(mytype) :: C_T                 ! Thrust coefficient
    real(mytype) :: alpha               ! Induction coefficient
    real(mytype) :: Udisc               ! Disc-averaged velocity
    real(mytype) :: UF                  ! Disc-averaged velocity -- filtered
    real(mytype) :: YawAng              ! Rotor yaw angle (in degrees, with respect to y-axis)
    real(mytype) :: TiltAng             ! Rotor tilt angle (in degrees, with respect to z-axis)
    real(mytype) :: Area
    real(mytype) :: Power
    real(mytype) :: Thrust
    real(mytype) :: Udisc_ave=0.0_mytype
    real(mytype) :: Power_ave=0.0_mytype
    real(mytype) :: Thrust_ave=0.0_mytype
    real(mytype) :: PertAmp             ! Perturbation amplitude (fraction of thrust)
    real(mytype) :: PertFreq            ! Perturbation frequency
    integer :: PertDir                  ! Perturbation direction (0: axial edge forcing, 1: transverse sway)
    integer :: PertMode                 ! Azimuthal mode of the axial edge forcing (0: pulsing, 1: rocking, ...)
    real(mytype) :: PertWidth           ! Radial width of the axial edge forcing (fraction of D)
    real(mytype) :: PertPhase           ! Temporal phase of the perturbation
    real(mytype) :: PertAzim            ! Azimuthal orientation of the perturbation
    real(mytype) :: PertVec(3)          ! In-plane direction of the transverse perturbation
    real(mytype) :: PertBand            ! Spectral width (FWHM) of the perturbation, 0 for a pure sine
    real(mytype) :: PertTheta           ! Current phase of the perturbation
    real(mytype) :: PertTime=-1.0_mytype ! Time at which PertTheta was last updated (<0: not yet set)
    integer(8) :: RngState              ! State of the perturbation random number generator
end type ActuatorDiscType

    type(ActuatorDiscType), allocatable, save :: ActuatorDisc(:)
    type(client_type) :: client
    integer, save :: Nad                ! Number of the actuator disc turbines 
    character(len=12), save :: name_prefix
    real(mytype), allocatable, save :: GammaPert(:,:,:,:) ! Spatial shape of the edge perturbation

contains

    !*******************************************************************************
    !
    subroutine actuator_disc_model_init(Ndiscs,admCoords)
    !
    !*******************************************************************************
        
      use var, only: GammaDisc
      use param, only: dx,dy,dz,istret,irestart,itime,iturboutput,initstat,icontrolfreq,instance
      use decomp_2d
      use decomp_2d_io
      use MPI

      implicit none
      integer, intent(in) :: Ndiscs
      character(len=100), intent(in) :: admCoords
      character(1000) :: ReadLine
      real(mytype) :: GammaDisc_tot
      integer :: idisc,i,j,k,ierr,code,ios,result
      real :: temp
      real(mytype) :: dummy(8),pert_real(6)
      integer :: pert_int(2)
      real(mytype) :: xmesh,ymesh,zmesh,deltax,deltay,deltaz,deltan,deltar,disc_thick,hgrid,projected_x,projected_y,projected_z
      real(mytype) :: normal(3),e1(3),e2(3),pvec(3),theta,pert_width

      if (icontrolfreq>=1) then
          if (nrank==0) then
              write(*,*) '==========================================================='
              write(*,*) 'Initialising smartredis database'
              write(*,*) '==========================================================='
          end if
          result = client%initialize("smartredis_database")
          write(name_prefix, '(I0)') instance
          if (nrank==0) write(*,*) 'instance = ', trim(name_prefix)
          if (result /= 0) then
              write(*,*) 'SmartRedis initialization failed'
              call MPI_ABORT(MPI_COMM_WORLD, result, ierr)
          endif
      end if

      ! ADM not yet set-up for stretched grids
      if (istret/=0) then
         write(*,*) 'Simulation stopped: run with different options'
         call MPI_ABORT(MPI_COMM_WORLD,code,ierr); stop
      endif

      ! Specify the actuator discs
      Nad=Ndiscs
      if (nrank==0) then
         write(*,*) '==========================================================='
         write(*,*) 'The actuator disc model is enabled'
         write(*,*) 'Number of Actuator discs : ', Nad
         write(*,*) '==========================================================='
      endif

      if (Nad>0) then 
         ! Read the disc data
         allocate(ActuatorDisc(Nad))
         open(15,file=admCoords)
         read(15,*)
         do idisc=1,Nad
            actuatordisc(idisc)%ID=idisc
            read(15,'(A)') ReadLine
            read(Readline,*) ActuatorDisc(idisc)%COR(1),ActuatorDisc(idisc)%COR(2),ActuatorDisc(idisc)%COR(3),&
                             ActuatorDisc(idisc)%YawAng,ActuatorDisc(idisc)%TiltAng,ActuatorDisc(idisc)%D,&
                             ActuatorDisc(idisc)%C_T,ActuatorDisc(idisc)%alpha
            ! Remember: RotN(1)=cos(yaw_angle)*cos(tilt_angle), RotN(2)=sin(tilt_angle) and RotN(3)=sin(yaw_angle)
            ActuatorDisc(idisc)%RotN(1)=cos(ActuatorDisc(idisc)%YawAng*conrad)*cos(ActuatorDisc(idisc)%TiltAng*conrad)  
            ActuatorDisc(idisc)%RotN(2)=sin(ActuatorDisc(idisc)%TiltAng*conrad)
            ActuatorDisc(idisc)%RotN(3)=sin(ActuatorDisc(idisc)%YawAng*conrad)  
            ActuatorDisc(idisc)%Area=pi*(ActuatorDisc(idisc)%D**2._mytype)/4._mytype
            ! Optional perturbation columns: PertAmp PertFreq PertDir PertMode PertWidth PertPhase[deg] PertAzim[deg] [PertBand]
            ActuatorDisc(idisc)%PertAmp=0.
            ActuatorDisc(idisc)%PertFreq=0.
            ActuatorDisc(idisc)%PertDir=0
            ActuatorDisc(idisc)%PertMode=1
            ActuatorDisc(idisc)%PertWidth=0.1_mytype
            ActuatorDisc(idisc)%PertPhase=0.
            ActuatorDisc(idisc)%PertAzim=0.
            ActuatorDisc(idisc)%PertBand=0.
            ! Rank-independent seed; distinct reproducible forcing for each environment.
            ActuatorDisc(idisc)%RngState=88172645463325252_8+1000000007_8*int(instance,8)+1000003_8*idisc+itime
            read(Readline,*,iostat=ios) dummy,pert_real(1),pert_real(2),pert_int(1),pert_int(2),pert_real(3),pert_real(4),pert_real(5),&
                                        pert_real(6)
            if (ios==0) then
               ActuatorDisc(idisc)%PertBand=pert_real(6)
            else
               read(Readline,*,iostat=ios) dummy,pert_real(1),pert_real(2),pert_int(1),pert_int(2),pert_real(3),pert_real(4),pert_real(5)
            endif
            if (ios==0) then
               ActuatorDisc(idisc)%PertAmp=pert_real(1)
               ActuatorDisc(idisc)%PertFreq=pert_real(2)
               ActuatorDisc(idisc)%PertDir=pert_int(1)
               ActuatorDisc(idisc)%PertMode=pert_int(2)
               ActuatorDisc(idisc)%PertWidth=pert_real(3)
               ActuatorDisc(idisc)%PertPhase=pert_real(4)*conrad
               ActuatorDisc(idisc)%PertAzim=pert_real(5)*conrad
            endif
            if (nrank==0) then
               write(*,*) 'Disc ', idisc, ' perturbation: amp, freq, dir, mode, width, phase[deg], azim[deg], band = ', &
                          ActuatorDisc(idisc)%PertAmp,ActuatorDisc(idisc)%PertFreq,ActuatorDisc(idisc)%PertDir,&
                          ActuatorDisc(idisc)%PertMode,ActuatorDisc(idisc)%PertWidth,&
                          ActuatorDisc(idisc)%PertPhase/conrad,ActuatorDisc(idisc)%PertAzim/conrad,ActuatorDisc(idisc)%PertBand
            endif
         enddo
         close(15)
          
         call actuator_disc_model_compute_gamma()

         if (irestart==1) then
             do idisc=1,Nad
                 open(15,File='disc'//trim(int2str(idisc))//'.adm', position="append", status='old', action='read')
                 backspace(15)
                 read(15,*) temp,temp,actuatordisc(idisc)%UF,actuatordisc(idisc)%Power,actuatordisc(idisc)%Thrust,actuatordisc(idisc)%Udisc_ave,actuatordisc(idisc)%Power_ave,actuatordisc(idisc)%Thrust_ave,temp,temp,temp
                 actuatordisc(idisc)%Udisc_ave=actuatordisc(idisc)%Udisc_ave*(mod(itime-1,icontrolfreq)+1)
                 actuatordisc(idisc)%Power_ave=actuatordisc(idisc)%Power_ave*(mod(itime-1,icontrolfreq)+1)
                 actuatordisc(idisc)%Thrust_ave=actuatordisc(idisc)%Thrust_ave*(mod(itime-1,icontrolfreq)+1)
                 close(15)
             end do
         endif

      endif

      return

    end subroutine actuator_disc_model_init

    !*******************************************************************************
    !
    subroutine actuator_disc_model_read_input(Ndiscs,admCoords)
    !
    !*******************************************************************************

      use MPI

      implicit none
      integer, intent(in) :: Ndiscs
      character(len=100), intent(in) :: admCoords
      integer :: idisc,ierr,result
      real(kind=c_double), dimension(Ndiscs) :: AllYawAngs
      real(kind=c_double), dimension(1) :: controller_done
      integer :: yaw_mpi_type
      type(poll_timespec) :: poll_delay, remaining_delay

      Nad=Ndiscs
      if (nrank==0) then
          controller_done(1) = 0
          poll_delay = poll_timespec(0_c_long, 1000000_c_long)
          do while (int(controller_done(1)) == 0)
              result = client%unpack_tensor(trim(name_prefix)//'_yaws_done', controller_done, shape(controller_done))
              if (result /= 0) then
                  write(*,*) 'SmartRedis yaw-ready read failed'
                  call MPI_ABORT(MPI_COMM_WORLD, result, ierr)
              endif
              if (int(controller_done(1)) == 0) then
                  result = poll_nanosleep(poll_delay, remaining_delay)
                  if (result /= 0) then
                      write(*,*) 'SmartRedis polling sleep failed'
                      call MPI_ABORT(MPI_COMM_WORLD, 1, ierr)
                  endif
              endif
          end do

          if (Nad>0) then
              result = client%unpack_tensor(trim(name_prefix)//'_yaws', AllYawAngs, shape(AllYawAngs))
              if (result /= 0) then
                  write(*,*) 'SmartRedis yaw read failed'
                  call MPI_ABORT(MPI_COMM_WORLD, result, ierr)
              endif
          endif
      endif

      call MPI_TYPE_MATCH_SIZE(MPI_TYPECLASS_REAL, int(c_sizeof(controller_done(1))), yaw_mpi_type, result)
      if (result /= MPI_SUCCESS) then
          write(*,*) 'MPI yaw datatype lookup failed'
          call MPI_ABORT(MPI_COMM_WORLD, result, ierr)
      endif
      call MPI_BCAST(AllYawAngs, Nad, yaw_mpi_type, 0, MPI_COMM_WORLD, result)
      if (result /= MPI_SUCCESS) then
          write(*,*) 'MPI yaw broadcast failed'
          call MPI_ABORT(MPI_COMM_WORLD, result, ierr)
      endif

      if (Nad>0) then
          do idisc=1,Nad
              ActuatorDisc(idisc)%YawAng=AllYawAngs(idisc)
              ActuatorDisc(idisc)%RotN(1)=cos(ActuatorDisc(idisc)%YawAng*conrad)*cos(ActuatorDisc(idisc)%TiltAng*conrad)
              ActuatorDisc(idisc)%RotN(2)=sin(ActuatorDisc(idisc)%TiltAng*conrad)
              ActuatorDisc(idisc)%RotN(3)=sin(ActuatorDisc(idisc)%YawAng*conrad)
          enddo
          call actuator_disc_model_compute_gamma()
      endif

      return

    end subroutine actuator_disc_model_read_input

    !*******************************************************************************
    !
    subroutine actuator_disc_model_compute_gamma()
    !
    !*******************************************************************************

      use var, only: GammaDisc
      use param, only: dx,dy,dz
      use decomp_2d
      use MPI

      implicit none
      integer :: idisc,i,j,k,ierr
      real(mytype) :: GammaDisc_tot(1),GammaDisc_global(1)
      real(mytype) :: xmesh,ymesh,zmesh,deltax,deltay,deltaz,deltan,deltar
      real(mytype) :: disc_thick,hgrid,projected_x,projected_y,projected_z
      real(mytype) :: normal(3),e1(3),e2(3),pvec(3),theta,pert_width

      GammaDisc=0.0
      if (any(ActuatorDisc%PertAmp/=0..and.ActuatorDisc%PertDir==0)) then
         if (.not.allocated(GammaPert)) allocate(GammaPert(xsize(1),xsize(2),xsize(3),Nad))
         GammaPert=0.0
      endif

      do idisc=1,Nad
         GammaDisc_tot(1)=0.0
         hgrid=sqrt((dx*ActuatorDisc(idisc)%RotN(1))**2+&
                    (dy*ActuatorDisc(idisc)%RotN(2))**2+&
                    (dz*(-ActuatorDisc(idisc)%RotN(3)))**2)
         disc_thick=max(ActuatorDisc(idisc)%D/8.0,hgrid*1.5)
         pert_width=max(ActuatorDisc(idisc)%PertWidth*ActuatorDisc(idisc)%D,hgrid*1.5)
         normal=[ActuatorDisc(idisc)%RotN(1),ActuatorDisc(idisc)%RotN(2),-ActuatorDisc(idisc)%RotN(3)]
         if (abs(normal(2))<0.9) then
            e1=[0._mytype,1._mytype,0._mytype]
         else
            e1=[0._mytype,0._mytype,1._mytype]
         endif
         e1=e1-dot_product(e1,normal)*normal
         e1=e1/sqrt(dot_product(e1,e1))
         e2=[normal(2)*e1(3)-normal(3)*e1(2),&
             normal(3)*e1(1)-normal(1)*e1(3),&
             normal(1)*e1(2)-normal(2)*e1(1)]
         ActuatorDisc(idisc)%PertVec=cos(ActuatorDisc(idisc)%PertAzim)*e1+&
                                     sin(ActuatorDisc(idisc)%PertAzim)*e2

         do k=1,xsize(3)
            zmesh=(xstart(3)+k-2)*dz
            do j=1,xsize(2)
               ymesh=(xstart(2)+j-2)*dy
               do i=1,xsize(1)
                  xmesh=(xstart(1)+i-2)*dx
                  deltax=xmesh-ActuatorDisc(idisc)%COR(1)
                  deltay=ymesh-ActuatorDisc(idisc)%COR(2)
                  deltaz=zmesh-ActuatorDisc(idisc)%COR(3)
                  deltan=deltax*ActuatorDisc(idisc)%RotN(1)+&
                          deltay*ActuatorDisc(idisc)%RotN(2)-&
                          deltaz*ActuatorDisc(idisc)%RotN(3)
                  projected_x=xmesh-deltan*ActuatorDisc(idisc)%RotN(1)
                  projected_y=ymesh-deltan*ActuatorDisc(idisc)%RotN(2)
                  projected_z=zmesh-deltan*(-ActuatorDisc(idisc)%RotN(3))
                  deltar=sqrt((projected_x-ActuatorDisc(idisc)%COR(1))**2+&
                              (projected_y-ActuatorDisc(idisc)%COR(2))**2+&
                              (projected_z-ActuatorDisc(idisc)%COR(3))**2)
                  GammaDisc(i,j,k,idisc)=exp(-(deltan/(disc_thick/2.0))**2.0-&
                                                   (deltar/(ActuatorDisc(idisc)%D/2.0))**8.0)
                  GammaDisc_tot(1)=GammaDisc_tot(1)+GammaDisc(i,j,k,idisc)

                  if (ActuatorDisc(idisc)%PertAmp/=0..and.ActuatorDisc(idisc)%PertDir==0) then
                     pvec=[projected_x-ActuatorDisc(idisc)%COR(1),&
                           projected_y-ActuatorDisc(idisc)%COR(2),&
                           projected_z-ActuatorDisc(idisc)%COR(3)]
                     theta=atan2(dot_product(pvec,e2),dot_product(pvec,e1))
                     GammaPert(i,j,k,idisc)=exp(-((deltar-ActuatorDisc(idisc)%D/2.0)/pert_width)**2.0)*&
                                            cos(ActuatorDisc(idisc)%PertMode*&
                                                (theta-ActuatorDisc(idisc)%PertAzim))
                  endif
               enddo
            enddo
         enddo

         call MPI_ALLREDUCE(GammaDisc_tot,GammaDisc_global,1,real_type,MPI_SUM,MPI_COMM_WORLD,ierr)
         GammaDisc(:,:,:,idisc)=GammaDisc(:,:,:,idisc)/GammaDisc_global(1)
         if (ActuatorDisc(idisc)%PertAmp/=0..and.ActuatorDisc(idisc)%PertDir==0) then
            GammaPert(:,:,:,idisc)=GammaPert(:,:,:,idisc)*GammaDisc(:,:,:,idisc)
         endif
      enddo

      return

    end subroutine actuator_disc_model_compute_gamma

    !*******************************************************************************
    !
    subroutine actuator_disc_model_compute_source(ux1,uy1,uz1)
    !
    !*******************************************************************************
        
      use decomp_2d, only: xsize
      use MPI
      use param, only: dx, dy, dz, dt, t, itime, initstat, rho_air, T_relax, dBL, ustar, icontrolfreq
      use var, only: Fdiscx, Fdiscy, Fdiscz, GammaDisc
        
      implicit none
      real(mytype), dimension(xsize(1),xsize(2),xsize(3)) :: ux1, uy1, uz1       
      real(mytype) :: uave, CTprime, alpha_relax, pert, dtp
      real(mytype), allocatable, dimension(:) :: Udisc_partial
      integer :: i, j, k, idisc, ierr

      ! Compute disc-averaged velocity
      allocate(Udisc_partial(Nad))
     
      do idisc=1,Nad
         uave=0.
         do k=1,xsize(3)
            do j=1,xsize(2)
               do i=1,xsize(1)
                  ! Take the inner product to compute the rotor-normal velocity
                  uave=uave+GammaDisc(i,j,k,idisc)*(&  
                       ux1(i,j,k)*  actuatordisc(idisc)%RotN(1)+&
                       uy1(i,j,k)*  actuatordisc(idisc)%RotN(2)+&
                       uz1(i,j,k)*(-actuatordisc(idisc)%RotN(3)))
               enddo
            enddo
         enddo
         Udisc_partial(idisc)=uave
      enddo
      call MPI_ALLREDUCE(Udisc_partial,actuatordisc%Udisc,Nad,real_type,MPI_SUM,MPI_COMM_WORLD,ierr)

      deallocate(Udisc_partial)

      ! Time relaxation -- low pass filter
      if (itime==1.or.T_relax<0) then
         do idisc=1,Nad
            actuatordisc(idisc)%UF=actuatordisc(idisc)%Udisc
         enddo
      else
         alpha_relax=(dt/T_relax)/(1.+dt/T_relax)
         do idisc=1,Nad
            actuatordisc(idisc)%UF=alpha_relax*actuatordisc(idisc)%Udisc+(1.-alpha_relax)*actuatordisc(idisc)%UF
         enddo
      endif
        
      ! Compute the forces
      Fdiscx=0.
      Fdiscy=0.
      Fdiscz=0.
      do idisc=1,Nad
         ! Compute local thrust coefficient
         CTprime=actuatordisc(idisc)%C_T/(1-actuatordisc(idisc)%alpha)**2.
         ! Compute power and thrust (a power coefficient may be considered here)
         actuatordisc(idisc)%Thrust=0.5_mytype*rho_air*CTprime*actuatordisc(idisc)%UF**2.0_mytype*actuatordisc(idisc)%Area
         actuatordisc(idisc)%Power =actuatordisc(idisc)%Thrust*actuatordisc(idisc)%UF
         ! Distribute thrust force
         Fdiscx(:,:,:)=Fdiscx(:,:,:)-actuatordisc(idisc)%Thrust*GammaDisc(:,:,:,idisc)*actuatordisc(idisc)%RotN(1)/(dx*dy*dz)
         Fdiscy(:,:,:)=Fdiscy(:,:,:)-actuatordisc(idisc)%Thrust*GammaDisc(:,:,:,idisc)*actuatordisc(idisc)%RotN(2)/(dx*dy*dz)
         Fdiscz(:,:,:)=Fdiscz(:,:,:)-actuatordisc(idisc)%Thrust*GammaDisc(:,:,:,idisc)*(-actuatordisc(idisc)%RotN(3))/(dx*dy*dz)
         ! Add the perturbation mimicking disc vibration
         if (actuatordisc(idisc)%PertAmp/=0.) then
            if (actuatordisc(idisc)%PertBand==0..or.actuatordisc(idisc)%PertTime<0.) then
               actuatordisc(idisc)%PertTheta=2._mytype*pi*actuatordisc(idisc)%PertFreq*t+actuatordisc(idisc)%PertPhase
            else
               ! Phase diffusion: Lorentzian spectrum centred at PertFreq with full width PertBand
               dtp=t-actuatordisc(idisc)%PertTime
               actuatordisc(idisc)%PertTheta=actuatordisc(idisc)%PertTheta+2._mytype*pi*actuatordisc(idisc)%PertFreq*dtp+&
                    sqrt(2._mytype*pi*actuatordisc(idisc)%PertBand*dtp)*gauss_random(actuatordisc(idisc)%RngState)
            endif
            actuatordisc(idisc)%PertTime=t
            pert=actuatordisc(idisc)%PertAmp*actuatordisc(idisc)%Thrust*sin(actuatordisc(idisc)%PertTheta)/(dx*dy*dz)
            if (actuatordisc(idisc)%PertDir==0) then
               ! Axial: local thrust fluctuation at the disc edge
               Fdiscx(:,:,:)=Fdiscx(:,:,:)-pert*GammaPert(:,:,:,idisc)*actuatordisc(idisc)%RotN(1)
               Fdiscy(:,:,:)=Fdiscy(:,:,:)-pert*GammaPert(:,:,:,idisc)*actuatordisc(idisc)%RotN(2)
               Fdiscz(:,:,:)=Fdiscz(:,:,:)-pert*GammaPert(:,:,:,idisc)*(-actuatordisc(idisc)%RotN(3))
            else
               ! Transverse: side force over the whole disc (sway), net force PertAmp*Thrust
               Fdiscx(:,:,:)=Fdiscx(:,:,:)+pert*GammaDisc(:,:,:,idisc)*actuatordisc(idisc)%PertVec(1)
               Fdiscy(:,:,:)=Fdiscy(:,:,:)+pert*GammaDisc(:,:,:,idisc)*actuatordisc(idisc)%PertVec(2)
               Fdiscz(:,:,:)=Fdiscz(:,:,:)+pert*GammaDisc(:,:,:,idisc)*actuatordisc(idisc)%PertVec(3)
            endif
         endif
      enddo
        
      ! Compute statistics over the current control window
      do idisc=1,Nad
         if (mod(itime,icontrolfreq)==1) then
            actuatordisc(idisc)%Udisc_ave=0.0_mytype
            actuatordisc(idisc)%Power_ave=0.0_mytype
            actuatordisc(idisc)%Thrust_ave=0.0_mytype
         endif
         actuatordisc(idisc)%Udisc_ave=actuatordisc(idisc)%Udisc_ave+actuatordisc(idisc)%UF
         actuatordisc(idisc)%Power_ave=actuatordisc(idisc)%Power_ave+actuatordisc(idisc)%Power
         actuatordisc(idisc)%Thrust_ave=actuatordisc(idisc)%Thrust_ave+actuatordisc(idisc)%Thrust
      enddo

      return

    end subroutine actuator_disc_model_compute_source
 
    !*******************************************************************************
    !
    subroutine actuator_disc_model_write_output(dump_no)
    !
    !*******************************************************************************

      use param, only: itime, initstat, icontrolfreq, dt

      implicit none
      integer, intent(in) :: dump_no
      integer :: idisc

      if (Nad>0) then
         do idisc=1, Nad
             if (dump_no==1) then
                 open(2020,File='disc'//trim(int2str(idisc))//'.adm')
                 write(2020,*) 'i, Time, UF, Power, Thrust, Udisc_ave, Power_ave, Thrust_ave, alpha, YawAng, TiltAng'
                 close(2020)
             endif
             open(2020,File='disc'//trim(int2str(idisc))//'.adm', position="append", status="old", action="write")
             write(2020,*)itime,&
                          itime*dt,&
                          actuatordisc(idisc)%UF,&
                          actuatordisc(idisc)%Power,&
                          actuatordisc(idisc)%Thrust,&
                          actuatordisc(idisc)%Udisc_ave/(mod(itime-1,icontrolfreq)+1),&
                          actuatordisc(idisc)%Power_ave/(mod(itime-1,icontrolfreq)+1),&
                          actuatordisc(idisc)%Thrust_ave/(mod(itime-1,icontrolfreq)+1),&
                          actuatordisc(idisc)%alpha,&
                          actuatordisc(idisc)%YawAng,&
                          actuatordisc(idisc)%TiltAng
             close(2020)
         enddo
      endif

      return 

    end subroutine actuator_disc_model_write_output

    !*******************************************************************************
    !
    subroutine actuator_disc_model_smartredis_output()
    !
    !*******************************************************************************

      use param, only: icontrolfreq
      use MPI

      implicit none
      integer :: idisc,result,ierr
      real(kind=c_double), dimension(Nad) :: AllPowers
      real(kind=c_double), dimension(1) :: simulation_done,controller_done

      if (Nad>0) then
          AllPowers=[(ActuatorDisc(idisc)%Power_ave/icontrolfreq,idisc=1,Nad)]
          if (nrank==0) then
              result=client%put_tensor(trim(name_prefix)//'_turbine_powers',AllPowers,shape(AllPowers))
              if (result/=0) then
                  write(*,*) 'SmartRedis write failed'
                  call MPI_ABORT(MPI_COMM_WORLD,result,ierr)
              endif
          endif
      endif

      controller_done(1)=0
      if (nrank==0) then
          result=client%put_tensor(trim(name_prefix)//'_yaws_done',controller_done,shape(controller_done))
          if (result/=0) then
              write(*,*) 'SmartRedis write failed'
              call MPI_ABORT(MPI_COMM_WORLD,result,ierr)
          endif
      endif

      simulation_done(1)=1
      if (nrank==0) then
          result=client%put_tensor(trim(name_prefix)//'_sim_done',simulation_done,shape(simulation_done))
          if (result/=0) then
              write(*,*) 'SmartRedis write failed'
              call MPI_ABORT(MPI_COMM_WORLD,result,ierr)
          endif
      endif

      return

    end subroutine actuator_disc_model_smartredis_output

    !*******************************************************************************
    !
    function gauss_random(state)
    !
    !*******************************************************************************
    ! Standard normal random number (xorshift64 + Box-Muller). Independent of the
    ! intrinsic random_number, so all ranks draw the same sequence from the same state.

      implicit none
      integer(8), intent(inout) :: state
      real(mytype) :: gauss_random, u1, u2

      u1=(real(ishft(xorshift(state),-11),mytype)+1._mytype)*2._mytype**(-53)
      u2=real(ishft(xorshift(state),-11),mytype)*2._mytype**(-53)
      gauss_random=sqrt(-2._mytype*log(u1))*cos(2._mytype*pi*u2)

    end function gauss_random

    function xorshift(state)

      implicit none
      integer(8), intent(inout) :: state
      integer(8) :: xorshift

      state=ieor(state,ishft(state,13))
      state=ieor(state,ishft(state,-7))
      state=ieor(state,ishft(state,17))
      xorshift=state

    end function xorshift

end module actuator_disc_model
