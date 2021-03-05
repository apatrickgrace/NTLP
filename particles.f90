module particles
  integer :: rproc,trproc,tproc,tlproc,lproc,blproc,bproc,brproc
  integer :: pr_r,pl_r,pt_r,pb_r,ptr_r,ptl_r,pbl_r,pbr_r
  integer :: pr_s,pl_s,pt_s,pb_s,ptr_s,ptl_s,pbl_s,pbr_s
  real :: ymin,ymax,zmin,zmax,xmax,xmin
  real, allocatable :: uext(:,:,:), vext(:,:,:), wext(:,:,:)
  real, allocatable :: u_t(:,:,:), v_t(:,:,:), w_t(:,:,:)
  real, allocatable :: Text(:,:,:),T_t(:,:,:)
  real, allocatable :: T2ext(:,:,:),T2_t(:,:,:)
  real, allocatable :: partTsrc(:,:,:),partTsrc_t(:,:,:)
  real, allocatable :: partHsrc(:,:,:),partHsrc_t(:,:,:)
  real, allocatable :: partTEsrc(:,:,:),partTEsrc_t(:,:,:)
  real, allocatable :: partcount_t(:,:,:),partsrc_t(:,:,:,:)
  real, allocatable :: vpsum_t(:,:,:,:),vpsqrsum_t(:,:,:,:)
  real, allocatable :: upwp_t(:,:,:),upwp(:,:,:)
  real, allocatable :: partcount(:,:,:),partsrc(:,:,:,:)
  real, allocatable :: vpsum(:,:,:,:),vpsqrsum(:,:,:,:)
  real, allocatable :: Tpsum(:,:,:),Tpsum_t(:,:,:)
  real, allocatable :: Tpsqrsum(:,:,:),Tpsqrsum_t(:,:,:)
  real, allocatable :: Tfsum(:,:,:),Tfsum_t(:,:,:)
  real, allocatable :: qfsum(:,:,:),qfsum_t(:,:,:)
  real, allocatable :: wpTpsum(:,:,:),wpTpsum_t(:,:,:)
  real, allocatable :: radsum(:,:,:),radsum_t(:,:,:)
  real, allocatable :: rad2sum(:,:,:),rad2sum_t(:,:,:)
  real, allocatable :: multcount(:,:,:),multcount_t(:,:,:) 
  real, allocatable :: mwsum(:,:,:),mwsum_t(:,:,:)
  real, allocatable :: qstarsum(:,:,:),qstarsum_t(:,:,:)

  !--- SFS velocity calculation ---------
  real, allocatable :: sigm_s(:,:,:),sigm_sdx(:,:,:),sigm_sdy(:,:,:)
  real, allocatable :: sigm_sdz(:,:,:),sigm_sext(:,:,:)
  real, allocatable :: sigm_sdxext(:,:,:),sigm_sdyext(:,:,:)
  real, allocatable :: sigm_sdzext(:,:,:)
  real, allocatable :: vis_ss(:,:,:),vis_sext(:,:,:)

  integer :: particletype,pad_diff
  integer :: numpart,tnumpart,ngidx
  integer :: iseed
  integer :: num100=0, num1000=0, numimpos=0
  integer :: tnum100, tnum1000, tnumimpos
  integer :: denum, actnum, tdenum, tactnum
  integer :: num_destroy=0,tnum_destroy=0
  integer :: tot_reintro=0

  real :: Rep_avg,part_grav(3)
  real :: radavg,radmin,radmax,radmsqr,tempmin,tempmax,qmin,qmax
  real :: vp_init(3),Tp_init,radius_init
  real :: pdf_factor,pdf_prob
  integer*8 :: mult_init,mult_factor,mult_a,mult_c

  real :: avgres=0,tavgres=0

  integer, parameter :: histbins = 512
  real :: hist_rad(histbins+2)
  real :: bins_rad(histbins+2)

  real :: hist_res(histbins+2)
  real :: bins_res(histbins+2)

  real :: hist_actres(histbins+2)
  real :: bins_actres(histbins+2)

  real :: hist_numact(histbins+2)
  real :: bins_numact(histbins+2)

  !REMEMBER: IF ADDING ANYTHING, MUST UPDATE MPI DATATYPE!
  type :: particle
    integer :: pidx,procidx,nbr_pidx,nbr_procidx
    real :: vp(3),xp(3),uf(3),xrhs(3),vrhs(3),Tp,Tprhs_s
    real :: Tprhs_L,Tf,radius,radrhs,qinf,qstar,dist
    real :: res,m_s,Os,rc,actres,numact
    real :: u_sub(3),sigm_s
    integer*8 :: mult
    type(particle), pointer :: prev,next
  end type particle

  type(particle), pointer :: part,first_particle

CONTAINS

  subroutine fill_ext
    use pars
    use fields
    use con_stats
    use con_data
    implicit none
    include 'mpif.h'

    integer :: istatus(mpi_status_size),ierr
    integer :: ix,iy,iz
    !preceding letter: r=right,l=left,t=top,b=bot.
    !_s: buf of things to send TO r,l,t,b
    !_r: buf of things to recv FROM r,l,t,b
    real :: tbuf_s(nnz+2,iye-iys+1,2,5),tbuf_r(nnz+2,iye-iys+1,3,5)
    real :: bbuf_s(nnz+2,iye-iys+1,3,5),bbuf_r(nnz+2,iye-iys+1,2,5)
    real :: rbuf_s(nnz+2,2,mxe-mxs+1,5),rbuf_r(nnz+2,3,mxe-mxs+1,5)
    real :: lbuf_s(nnz+2,3,mxe-mxs+1,5),lbuf_r(nnz+2,2,mxe-mxs+1,5)

    !Corners:
    real :: trbuf_s(nnz+2,2,2,5),trbuf_r(nnz+2,3,3,5)
    real :: brbuf_s(nnz+2,2,3,5),brbuf_r(nnz+2,3,2,5)
    real :: blbuf_s(nnz+2,3,3,5),blbuf_r(nnz+2,2,2,5)
    real :: tlbuf_s(nnz+2,3,2,5),tlbuf_r(nnz+2,2,3,5)

    !MPI send counts:
    integer :: rc_s,rc_r,trc_s,trc_r,tc_s,tc_r,tlc_s,tlc_r
    integer :: lc_s,lc_r,blc_s,blc_r,bc_s,bc_r,brc_s,brc_r

    !Debugging:
    real :: xv,yv,zv

    !To update the particle ODE in time, need the interpolated
    !velocity field
    !This requires filling uext,vext,wext from nearby procs
    uext = 0.0
    vext = 0.0
    wext = 0.0
    Text = 0.0
    T2ext = 0.0

    !First fill the center, since this is just u,v,w on that proc:

    !In the column setup, need to tranpose u,v,w first into u_t,v_t,w_t:
    call xtoz_trans(u(1:nnx,iys:iye,izs-1:ize+1),u_t,nnx,nnz, &
    mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)
    call xtoz_trans(v(1:nnx,iys:iye,izs-1:ize+1),v_t,nnx,nnz, &
    mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)
    call xtoz_trans(w(1:nnx,iys:iye,izs-1:ize+1),w_t,nnx,nnz, &
    mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)
    call xtoz_trans(t(1:nnx,iys:iye,1,izs-1:ize+1),T_t,nnx,nnz, &
    mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)
    call xtoz_trans(t(1:nnx,iys:iye,2,izs-1:ize+1),T2_t,nnx,nnz, &
    mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)

    uext(0:nnz+1,iys:iye,mxs:mxe) = u_t(0:nnz+1,iys:iye,mxs:mxe)
    vext(0:nnz+1,iys:iye,mxs:mxe) = v_t(0:nnz+1,iys:iye,mxs:mxe)
    wext(0:nnz+1,iys:iye,mxs:mxe) = w_t(0:nnz+1,iys:iye,mxs:mxe)
    Text(0:nnz+1,iys:iye,mxs:mxe) = T_t(0:nnz+1,iys:iye,mxs:mxe)
    T2ext(0:nnz+1,iys:iye,mxs:mxe) = T2_t(0:nnz+1,iys:iye,mxs:mxe)


    !Recall that SR assign_nbrs assigned rproc,lproc, etc.

    !Going to call 6 sendrecv calls - one for each proc. nbr.:

    !Fill the send buffers:

    !I know these are redundant, but so I can keep them straight...
    tc_s = 5*(nnz+2)*2*(iye-iys+1)
    tc_r = 5*(nnz+2)*3*(iye-iys+1)
    trc_s = 5*(nnz+2)*2*2
    trc_r = 5*(nnz+2)*3*3
    rc_s = 5*(nnz+2)*(mxe-mxs+1)*2
    rc_r = 5*(nnz+2)*(mxe-mxs+1)*3
    tlc_s = 5*(nnz+2)*3*2
    tlc_r = 5*(nnz+2)*2*3
    bc_s = 5*(nnz+2)*3*(iye-iys+1)
    bc_r = 5*(nnz+2)*2*(iye-iys+1)
    blc_s = 5*(nnz+2)*3*3
    blc_r = 5*(nnz+2)*2*2
    lc_s = 5*(nnz+2)*(mxe-mxs+1)*3
    lc_r = 5*(nnz+2)*(mxe-mxs+1)*2
    brc_s = 5*(nnz+2)*2*3
    brc_r = 5*(nnz+2)*3*2

    !First u:
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,1) = u_t(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,1) = u_t(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,1) = u_t(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,1) = u_t(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,1) = u_t(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,1) = u_t(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,1) = u_t(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,1) = u_t(0:nnz+1,iys:iys+2,mxe-1:mxe)

    !v:
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,2) = v_t(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,2) = v_t(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,2) = v_t(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,2) = v_t(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,2) = v_t(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,2) = v_t(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,2) = v_t(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,2) = v_t(0:nnz+1,iys:iys+2,mxe-1:mxe)

    !w:
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,3) = w_t(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,3) = w_t(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,3) = w_t(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,3) = w_t(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,3) = w_t(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,3) = w_t(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,3) = w_t(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,3) = w_t(0:nnz+1,iys:iys+2,mxe-1:mxe)

    !T:
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,4) = T_t(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,4) = T_t(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,4) = T_t(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,4) = T_t(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,4) = T_t(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,4) = T_t(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,4) = T_t(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,4) = T_t(0:nnz+1,iys:iys+2,mxe-1:mxe)

    !T2:
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,5) = T2_t(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,5) = T2_t(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,5) = T2_t(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,5) = T2_t(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,5) = T2_t(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,5) = T2_t(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,5) = T2_t(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,5) = T2_t(0:nnz+1,iys:iys+2,mxe-1:mxe)

    !Zero out recieve buffers
    rbuf_r=0.0;trbuf_r=0.0;tbuf_r=0.0;tlbuf_r=0.0;lbuf_r=0.0
    blbuf_r=0.0;bbuf_r=0.0;brbuf_r=0.0

    !Left/right:
    call MPI_Sendrecv(rbuf_s,rc_s,mpi_real8,rproc,3, &
    lbuf_r,lc_r,mpi_real8,lproc,3,mpi_comm_world,istatus,ierr)

    call mpi_barrier(mpi_comm_world,ierr)
    call MPI_Sendrecv(lbuf_s,lc_s,mpi_real8,lproc,4, &
    rbuf_r,rc_r,mpi_real8,rproc,4,mpi_comm_world,istatus,ierr)

    !Top/bottom:
    call MPI_Sendrecv(tbuf_s,tc_s,mpi_real8,tproc,5, &
    bbuf_r,bc_r,mpi_real8,bproc,5,mpi_comm_world,istatus,ierr)

    call MPI_Sendrecv(bbuf_s,bc_s,mpi_real8,bproc,6, &
    tbuf_r,tc_r,mpi_real8,tproc,6,mpi_comm_world,istatus,ierr)

    !Top right/bottom left:
    call MPI_Sendrecv(trbuf_s,trc_s,mpi_real8,trproc,7, &
    blbuf_r,blc_r,mpi_real8,blproc,7, &
    mpi_comm_world,istatus,ierr)

    call MPI_Sendrecv(blbuf_s,blc_s,mpi_real8,blproc,8, &
    trbuf_r,trc_r,mpi_real8,trproc,8, &
    mpi_comm_world,istatus,ierr)

    !Top left/bottom right:
    call MPI_Sendrecv(tlbuf_s,tlc_s,mpi_real8,tlproc,9, &
    brbuf_r,brc_r,mpi_real8,brproc,9, &
    mpi_comm_world,istatus,ierr)

    call MPI_Sendrecv(brbuf_s,brc_s,mpi_real8,brproc,10, &
    tlbuf_r,tlc_r,mpi_real8,tlproc,10, &
    mpi_comm_world,istatus,ierr)

    !Now fill the ext arrays with the recieved buffers:
    uext(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,1)
    uext(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,1)
    uext(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,1)
    uext(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,1)
    uext(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,1)
    uext(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,1)
    uext(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,1)
    uext(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,1)

    vext(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,2)
    vext(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,2)
    vext(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,2)
    vext(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,2)
    vext(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,2)
    vext(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,2)
    vext(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,2)
    vext(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,2)

    wext(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,3)
    wext(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,3)
    wext(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,3)
    wext(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,3)
    wext(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,3)
    wext(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,3)
    wext(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,3)
    wext(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,3)

    Text(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,4)
    Text(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,4)
    Text(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,4)
    Text(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,4)
    Text(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,4)
    Text(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,4)
    Text(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,4)
    Text(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,4)


    T2ext(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,5)
    T2ext(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,5)
    T2ext(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,5)
    T2ext(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,5)
    T2ext(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,5)
    T2ext(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,5)
    T2ext(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,5)
    T2ext(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,5)


  end subroutine fill_ext
  subroutine fill_extSFS
    !       This subroutine calculte the extented fields for SFS velocity

    use pars
    use fields
    use con_stats
    use con_data
    implicit none
    include 'mpif.h'

    integer :: istatus(mpi_status_size),ierr
    integer :: ix,iy,iz
    real :: sigm_st(0:nnz+1,iys:iye,mxs:mxe)
    real :: sigm_sdxt(0:nnz+1,iys:iye,mxs:mxe)
    real :: sigm_sdyt(0:nnz+1,iys:iye,mxs:mxe)
    real :: sigm_sdzt(0:nnz+1,iys:iye,mxs:mxe)
    real :: vis_st(0:nnz+1,iys:iye,mxs:mxe)
    !preceding letter: r=right,l=left,t=top,b=bot.
    !_s: buf of things to send TO r,l,t,b
    !_r: buf of things to recv FROM r,l,t,b
    real :: tbuf_s(nnz+2,iye-iys+1,2,5),tbuf_r(nnz+2,iye-iys+1,3,5)
    real :: bbuf_s(nnz+2,iye-iys+1,3,5),bbuf_r(nnz+2,iye-iys+1,2,5)
    real :: rbuf_s(nnz+2,2,mxe-mxs+1,5),rbuf_r(nnz+2,3,mxe-mxs+1,5)
    real :: lbuf_s(nnz+2,3,mxe-mxs+1,5),lbuf_r(nnz+2,2,mxe-mxs+1,5)

    !Corners:
    real :: trbuf_s(nnz+2,2,2,5),trbuf_r(nnz+2,3,3,5)
    real :: brbuf_s(nnz+2,2,3,5),brbuf_r(nnz+2,3,2,5)
    real :: blbuf_s(nnz+2,3,3,5),blbuf_r(nnz+2,2,2,5)
    real :: tlbuf_s(nnz+2,3,2,5),tlbuf_r(nnz+2,2,3,5)


    !MPI send counts:
    integer :: rc_s,rc_r,trc_s,trc_r,tc_s,tc_r,tlc_s,tlc_r
    integer :: lc_s,lc_r,blc_s,blc_r,bc_s,bc_r,brc_s,brc_r
    sigm_sext = 0.0
    sigm_sdxext = 0.0
    sigm_sdyext = 0.0
    sigm_sdzext = 0.0
    vis_sext = 0.0
    vis_st = 0.0
    sigm_st = 0.0
    sigm_sdxt = 0.0
    sigm_sdyt = 0.0
    sigm_sdzt = 0.0

    call xtoz_trans(sigm_s(1:nnx,iys:iye,izs-1:ize+1),sigm_st,nnx, &
    nnz,mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)
    call xtoz_trans(sigm_sdx(1:nnx,iys:iye,izs-1:ize+1),sigm_sdxt,nnx, &
    nnz,mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)
    call xtoz_trans(sigm_sdy(1:nnx,iys:iye,izs-1:ize+1),sigm_sdyt,nnx, &
    nnz,mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)
    call xtoz_trans(sigm_sdz(1:nnx,iys:iye,izs-1:ize+1),sigm_sdzt,nnx, &
    nnz,mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)

    call xtoz_trans(vis_ss(1:nnx,iys:iye,izs-1:ize+1),vis_st,nnx, &
    nnz,mxs,mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e, &
    myid,ncpu_s,numprocs)

    sigm_sext(0:nnz+1,iys:iye,mxs:mxe) = sigm_st(0:nnz+1,iys:iye,mxs:mxe)
    sigm_sdxext(0:nnz+1,iys:iye,mxs:mxe) = sigm_sdxt(0:nnz+1,iys:iye,mxs:mxe)
    sigm_sdyext(0:nnz+1,iys:iye,mxs:mxe) = sigm_sdyt(0:nnz+1,iys:iye,mxs:mxe)
    sigm_sdzext(0:nnz+1,iys:iye,mxs:mxe) = sigm_sdzt(0:nnz+1,iys:iye,mxs:mxe)
    vis_sext(0:nnz+1,iys:iye,mxs:mxe) = vis_st(0:nnz+1,iys:iye,mxs:mxe)



    !Fill the send buffers:
    tc_s = 5*(nnz+2)*2*(iye-iys+1)
    tc_r = 5*(nnz+2)*3*(iye-iys+1)
    trc_s = 5*(nnz+2)*2*2
    trc_r = 5*(nnz+2)*3*3
    rc_s = 5*(nnz+2)*(mxe-mxs+1)*2
    rc_r = 5*(nnz+2)*(mxe-mxs+1)*3
    tlc_s = 5*(nnz+2)*3*2
    tlc_r = 5*(nnz+2)*2*3
    bc_s = 5*(nnz+2)*3*(iye-iys+1)
    bc_r = 5*(nnz+2)*2*(iye-iys+1)
    blc_s = 5*(nnz+2)*3*3
    blc_r = 5*(nnz+2)*2*2
    lc_s = 5*(nnz+2)*(mxe-mxs+1)*3
    lc_r = 5*(nnz+2)*(mxe-mxs+1)*2
    brc_s = 5*(nnz+2)*2*3
    brc_r = 5*(nnz+2)*3*2

    !First sigm_s:
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,1) = sigm_st(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,1) = sigm_st(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,1) = sigm_st(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,1) = sigm_st(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,1) = sigm_st(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,1) = sigm_st(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,1) = sigm_st(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,1) = sigm_st(0:nnz+1,iys:iys+2,mxe-1:mxe)

    !sigm_sdx:
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,2) = sigm_sdxt(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,2) = sigm_sdxt(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,2) = sigm_sdxt(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,2) = sigm_sdxt(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,2) = sigm_sdxt(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,2) = sigm_sdxt(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,2) = sigm_sdxt(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,2) = sigm_sdxt(0:nnz+1,iys:iys+2,mxe-1:mxe)

    !sigm_sdy:
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,3) = sigm_sdyt(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,3) = sigm_sdyt(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,3) = sigm_sdyt(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,3) = sigm_sdyt(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,3) = sigm_sdyt(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,3) = sigm_sdyt(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,3) = sigm_sdyt(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,3) = sigm_sdyt(0:nnz+1,iys:iys+2,mxe-1:mxe)

    !sigm_sdz
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,4) = sigm_sdzt(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,4) = sigm_sdzt(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,4) = sigm_sdzt(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,4) = sigm_sdzt(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,4) = sigm_sdzt(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,4) = sigm_sdzt(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,4) = sigm_sdzt(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,4) = sigm_sdzt(0:nnz+1,iys:iys+2,mxe-1:mxe)

    !vis_s
    tbuf_s(1:nnz+2,1:iye-iys+1,1:2,5) = vis_st(0:nnz+1,iys:iye,mxe-1:mxe)
    trbuf_s(1:nnz+2,1:2,1:2,5) = vis_st(0:nnz+1,iye-1:iye,mxe-1:mxe)
    rbuf_s(1:nnz+2,1:2,1:mxe-mxs+1,5) = vis_st(0:nnz+1,iye-1:iye,mxs:mxe)
    brbuf_s(1:nnz+2,1:2,1:3,5) = vis_st(0:nnz+1,iye-1:iye,mxs:mxs+2)
    bbuf_s(1:nnz+2,1:iye-iys+1,1:3,5) = vis_st(0:nnz+1,iys:iye,mxs:mxs+2)
    blbuf_s(1:nnz+2,1:3,1:3,5)  = vis_st(0:nnz+1,iys:iys+2,mxs:mxs+2)
    lbuf_s(1:nnz+2,1:3,1:mxe-mxs+1,5) = vis_st(0:nnz+1,iys:iys+2,mxs:mxe)
    tlbuf_s(1:nnz+2,1:3,1:2,5) = vis_st(0:nnz+1,iys:iys+2,mxe-1:mxe)


    !Zero out recieve buffers
    rbuf_r=0.0;trbuf_r=0.0;tbuf_r=0.0;tlbuf_r=0.0;lbuf_r=0.0
    blbuf_r=0.0;bbuf_r=0.0;brbuf_r=0.0

    !Left/right:
    call MPI_Sendrecv(rbuf_s,rc_s,mpi_real8,rproc,3, &
    lbuf_r,lc_r,mpi_real8,lproc,3,mpi_comm_world,istatus,ierr)

    call MPI_Sendrecv(lbuf_s,lc_s,mpi_real8,lproc,4, &
    rbuf_r,rc_r,mpi_real8,rproc,4,mpi_comm_world,istatus,ierr)

    !Top/bottom:
    call MPI_Sendrecv(tbuf_s,tc_s,mpi_real8,tproc,5, &
    bbuf_r,bc_r,mpi_real8,bproc,5,mpi_comm_world,istatus,ierr)

    call MPI_Sendrecv(bbuf_s,bc_s,mpi_real8,bproc,6, &
    tbuf_r,tc_r,mpi_real8,tproc,6,mpi_comm_world,istatus,ierr)

    !Top right/bottom left:
    call MPI_Sendrecv(trbuf_s,trc_s,mpi_real8,trproc,7, &
    blbuf_r,blc_r,mpi_real8,blproc,7, &
    mpi_comm_world,istatus,ierr)

    call MPI_Sendrecv(blbuf_s,blc_s,mpi_real8,blproc,8, &
    trbuf_r,trc_r,mpi_real8,trproc,8, &
    mpi_comm_world,istatus,ierr)

    !Top left/bottom right:
    call MPI_Sendrecv(tlbuf_s,tlc_s,mpi_real8,tlproc,9, &
    brbuf_r,brc_r,mpi_real8,brproc,9, &
    mpi_comm_world,istatus,ierr)

    call MPI_Sendrecv(brbuf_s,brc_s,mpi_real8,brproc,10, &
    tlbuf_r,tlc_r,mpi_real8,tlproc,10, &
    mpi_comm_world,istatus,ierr)

    !Now fill the ext arrays with the recieved buffers:
    sigm_sext(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,1)
    sigm_sext(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,1)
    sigm_sext(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,1)
    sigm_sext(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,1)
    sigm_sext(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,1)
    sigm_sext(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,1)
    sigm_sext(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,1)
    sigm_sext(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,1)

    sigm_sdxext(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,2)
    sigm_sdxext(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,2)
    sigm_sdxext(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,2)
    sigm_sdxext(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,2)
    sigm_sdxext(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,2)
    sigm_sdxext(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,2)
    sigm_sdxext(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,2)
    sigm_sdxext(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,2)

    sigm_sdyext(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,3)
    sigm_sdyext(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,3)
    sigm_sdyext(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,3)
    sigm_sdyext(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,3)
    sigm_sdyext(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,3)
    sigm_sdyext(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,3)
    sigm_sdyext(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,3)
    sigm_sdyext(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,3)

    sigm_sdzext(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,4)
    sigm_sdzext(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,4)
    sigm_sdzext(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,4)
    sigm_sdzext(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,4)
    sigm_sdzext(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,4)
    sigm_sdzext(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,4)
    sigm_sdzext(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,4)
    sigm_sdzext(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,4)


    vis_sext(0:nnz+1,iys:iye,mxe+1:mxe+3) = tbuf_r(1:nnz+2,1:iye-iys+1,1:3,5)
    vis_sext(0:nnz+1,iye+1:iye+3,mxe+1:mxe+3) = trbuf_r(1:nnz+2,1:3,1:3,5)
    vis_sext(0:nnz+1,iye+1:iye+3,mxs:mxe) = rbuf_r(1:nnz+2,1:3,1:mxe-mxs+1,5)
    vis_sext(0:nnz+1,iye+1:iye+3,mxs-2:mxs-1) = brbuf_r(1:nnz+2,1:3,1:2,5)
    vis_sext(0:nnz+1,iys:iye,mxs-2:mxs-1) = bbuf_r(1:nnz+2,1:iye-iys+1,1:2,5)
    vis_sext(0:nnz+1,iys-2:iys-1,mxs-2:mxs-1) = blbuf_r(1:nnz+2,1:2,1:2,5)
    vis_sext(0:nnz+1,iys-2:iys-1,mxs:mxe) = lbuf_r(1:nnz+2,1:2,1:mxe-mxs+1,5)
    vis_sext(0:nnz+1,iys-2:iys-1,mxe+1:mxe+3) = tlbuf_r(1:nnz+2,1:2,1:3,5)

  end subroutine fill_extSFS

  subroutine particle_coupling_exchange
      use pars
      use con_data
      use con_stats
      implicit none
      include 'mpif.h'
      real :: ctbuf_s(nnz+2,1:iye-iys+2,6),cbbuf_r(nnz+2,1:iye-iys+2,6)
      real :: crbuf_s(nnz+2,1:mxe-mxs+1,6),clbuf_r(nnz+2,1:mxe-mxs+1,6)
      integer :: istatus(mpi_status_size),ierr,ncount


      !Now, partsrc and partTsrc have halos on each processor - give these to the rightful owner:
      crbuf_s=0.0;ctbuf_s=0.0
      clbuf_r=0.0;cbbuf_r=0.0

      !First send top: 
      !get send buffer ready:
      ctbuf_s(1:nnz+2,1:iye-iys+2,1:3)=partsrc_t(0:nnz+1,iys:iye+1,mxe+1,1:3)
      ctbuf_s(1:nnz+2,1:iye-iys+2,4)=partTsrc_t(0:nnz+1,iys:iye+1,mxe+1)
      ctbuf_s(1:nnz+2,1:iye-iys+2,5)=partHsrc_t(0:nnz+1,iys:iye+1,mxe+1)
      ctbuf_s(1:nnz+2,1:iye-iys+2,6)=partTEsrc_t(0:nnz+1,iys:iye+1,mxe+1)

      ncount = 6*(nnz+2)*(iye-iys+2)
      call mpi_sendrecv(ctbuf_s,ncount,mpi_real8,tproc,1, &
           cbbuf_r,ncount,mpi_real8,bproc,1,mpi_comm_world,istatus,ierr)

      !Now just add the contents of the receive buffer into the entire iys column of this proc:

      partsrc_t(0:nnz+1,iys:iye+1,mxs,1:3) = partsrc_t(0:nnz+1,iys:iye+1,mxs,1:3) + cbbuf_r(1:nnz+2,1:iye-iys+2,1:3)
      partTsrc_t(0:nnz+1,iys:iye+1,mxs) = partTsrc_t(0:nnz+1,iys:iye+1,mxs) + cbbuf_r(1:nnz+2,1:iye-iys+2,4)
      partHsrc_t(0:nnz+1,iys:iye+1,mxs) = partHsrc_t(0:nnz+1,iys:iye+1,mxs) + cbbuf_r(1:nnz+2,1:iye-iys+2,5)
      partTEsrc_t(0:nnz+1,iys:iye+1,mxs) = partTEsrc_t(0:nnz+1,iys:iye+1,mxs) + cbbuf_r(1:nnz+2,1:iye-iys+2,6)

      !Now get the right send buffer ready:
      crbuf_s(1:nnz+2,1:mxe-mxs+1,1:3)=partsrc_t(0:nnz+1,iye+1,mxs:mxe,1:3)
      crbuf_s(1:nnz+2,1:mxe-mxs+1,4)=partTsrc_t(0:nnz+1,iye+1,mxs:mxe)
      crbuf_s(1:nnz+2,1:mxe-mxs+1,5)=partHsrc_t(0:nnz+1,iye+1,mxs:mxe)
      crbuf_s(1:nnz+2,1:mxe-mxs+1,6)=partTEsrc_t(0:nnz+1,iye+1,mxs:mxe)

      !Now send to right:
      ncount = 6*(nnz+2)*(mxe-mxs+1)
      call mpi_sendrecv(crbuf_s,ncount,mpi_real8,rproc,2, &
           clbuf_r,ncount,mpi_real8,lproc,2,mpi_comm_world,istatus,ierr)

      !And again add the contents to the top/bottom rows of partsrc:
      partsrc_t(0:nnz+1,iys,mxs:mxe,1:3) = partsrc_t(0:nnz+1,iys,mxs:mxe,1:3) + clbuf_r(1:nnz+2,1:mxe-mxs+1,1:3)

      partTsrc_t(0:nnz+1,iys,mxs:mxe) = partTsrc_t(0:nnz+1,iys,mxs:mxe) + clbuf_r(1:nnz+2,1:mxe-mxs+1,4)
      partHsrc_t(0:nnz+1,iys,mxs:mxe) = partHsrc_t(0:nnz+1,iys,mxs:mxe) + clbuf_r(1:nnz+2,1:mxe-mxs+1,5)
      partTEsrc_t(0:nnz+1,iys,mxs:mxe) = partTEsrc_t(0:nnz+1,iys,mxs:mxe) + clbuf_r(1:nnz+2,1:mxe-mxs+1,6)


  end subroutine particle_coupling_exchange

  subroutine assign_nbrs
        use pars
        include 'mpif.h'
      !Figure out which processors lie to all sides: 
      !NOTE: For this updated case, where particles lie in columns not 
      !aligning with the velocity, there will be no MPI_PROC_NULL since
      !x and y are BOTH periodic
     
      !On right boundary:
      if ( mod(myid+1,ncpu_s) == 0 ) then
         !On the top:
         if ( myid .GE. ncpu_s*(ncpu_z-1) ) then
            rproc = myid-ncpu_s+1
            trproc = 0 
            tproc = ncpu_s-1 
            tlproc = ncpu_s-2 
            lproc = myid-1
            blproc = myid-ncpu_s-1
            bproc = myid-ncpu_s
            brproc = myid-ncpu_s - ncpu_s+1
         !On the bottom:
         elseif ( myid .LT. ncpu_s ) then
            rproc = myid-ncpu_s+1
            trproc = myid+1
            tproc = myid+ncpu_s
            tlproc = myid+ncpu_s-1
            lproc = myid-1
            blproc = myid+ncpu_s*(ncpu_z-1)-1 
            bproc = myid+ncpu_s*(ncpu_z-1) 
            brproc = ncpu_s*(ncpu_z-1) 
         !In the middle of right side:
         else 
            rproc = myid-ncpu_s+1
            trproc = myid+1
            tproc = myid+ncpu_s
            tlproc = myid+ncpu_s-1
            lproc = myid-1
            blproc = myid-ncpu_s-1
            bproc = myid-ncpu_s
            brproc = myid-ncpu_s - ncpu_s+1
         end if 

      !On the left boundary:
      elseif ( mod(myid,ncpu_s) == 0) then
         !On the top:
         if ( myid .GE. ncpu_s*(ncpu_z-1) ) then
            rproc = myid+1
            trproc = 1 
            tproc = 0 
            tlproc = ncpu_s-1
            lproc = myid+ncpu_s-1
            blproc = myid-1
            bproc = myid-ncpu_s
            brproc = myid-ncpu_s+1
         !On the bottom:
         elseif ( myid .LT. ncpu_s ) then
            rproc = myid+1
            trproc = myid+ncpu_s+1
            tproc = myid+ncpu_s
            tlproc = myid+ncpu_s+ncpu_s-1
            lproc = myid+ncpu_s-1
            blproc = numprocs-1 
            bproc = ncpu_s*(ncpu_z-1) 
            brproc = ncpu_s*(ncpu_z-1)+1 
         !In the middle of left side:
         else
            rproc = myid+1
            trproc = myid+ncpu_s+1
            tproc = myid+ncpu_s
            tlproc = myid+ncpu_s + ncpu_s-1
            lproc = myid+ncpu_s-1
            blproc = myid-1
            bproc = myid-ncpu_s
            brproc = myid-ncpu_s+1
         end if
      !On the top boundary
      elseif ( myid .GE. ncpu_s*(ncpu_z-1) ) then
         !Only check if in the middle:
         if ( .NOT. ( mod(myid,ncpu_s) == 0) ) then
            if ( .NOT. (mod(myid+1,ncpu_s) == 0) ) then
               rproc = myid+1
               trproc = myid-(ncpu_s*(ncpu_z-1))+1 
               tproc = myid-(ncpu_s*(ncpu_z-1)) 
               tlproc = myid-(ncpu_s*(ncpu_z-1))-1 
               lproc = myid-1
               blproc = myid-ncpu_s-1
               bproc = myid-ncpu_s
               brproc = myid-ncpu_s+1
            end if
         end if 
      !On the bottom boundary
      elseif ( myid .LT. ncpu_s) then
         if ( .NOT. ( mod(myid,ncpu_s) == 0) ) then
            if ( .NOT. (mod(myid+1,ncpu_s) == 0) ) then
               rproc = myid+1
               trproc = myid+ncpu_s+1
               tproc = myid+ncpu_s
               tlproc = myid+ncpu_s-1
               lproc = myid-1
               blproc = myid+ncpu_s*(ncpu_z-1)-1
               bproc = myid+ncpu_s*(ncpu_z-1) 
               brproc = myid+ncpu_s*(ncpu_z-1)+1 
            end if
         end if
      !Everywhere else:
      else 
         rproc = myid+1
         trproc = myid+ncpu_s+1
         tproc = myid+ncpu_s
         tlproc = myid+ncpu_s-1
         lproc = myid-1
         blproc = myid-ncpu_s-1
         bproc = myid-ncpu_s
         brproc = myid-ncpu_s+1
      end if

      return
  end subroutine assign_nbrs

  subroutine particle_exchange
      use pars
      use con_data
      use con_stats
      implicit none
      include 'mpif.h'

      type(particle), pointer :: tmp
      integer :: idx,psum,csum
      integer :: ir,itr,itop,itl,il,ibl,ib,ibr
      integer :: istatus(mpi_status_size),ierr
      integer :: status_array(mpi_status_size,16),req(16)
      type(particle), allocatable :: rbuf_s(:),trbuf_s(:)
      type(particle), allocatable :: tbuf_s(:),tlbuf_s(:)
      type(particle), allocatable :: lbuf_s(:),blbuf_s(:)
      type(particle), allocatable :: bbuf_s(:),brbuf_s(:)
      type(particle), allocatable :: rbuf_r(:),trbuf_r(:)
      type(particle), allocatable :: tbuf_r(:),tlbuf_r(:)
      type(particle), allocatable :: lbuf_r(:),blbuf_r(:)
      type(particle), allocatable :: bbuf_r(:),brbuf_r(:)
      type(particle), allocatable :: totalbuf(:)
      
      !Zero out the counters for how many particles to send each dir.
      pr_s=0;ptr_s=0;pt_s=0;ptl_s=0;pl_s=0;pbl_s=0;pb_s=0;pbr_s=0
      
      !As soon as the location is updated, must check to see if it left the proc:
      !May be a better way of doing this, but it seems most reasonable:
      part => first_particle
      do while (associated(part))     

         !First get numbers being sent to all sides:
         if (part%xp(2) .GT. ymax) then 
            if (part%xp(1) .GT. xmax) then !top right
               ptr_s = ptr_s + 1
            elseif (part%xp(1) .LT. xmin) then !bottom right
               pbr_s = pbr_s + 1
            else  !right
               pr_s = pr_s + 1
            end if
         elseif (part%xp(2) .LT. ymin) then
            if (part%xp(1) .GT. xmax) then !top left
               ptl_s = ptl_s + 1
            else if (part%xp(1) .LT. xmin) then !bottom left
               pbl_s = pbl_s + 1
            else  !left
               pl_s = pl_s + 1
            end if
         elseif ( (part%xp(1) .GT. xmax) .AND. &
                  (part%xp(2) .LT. ymax) .AND. &
                  (part%xp(2) .GT. ymin) ) then !top
            pt_s = pt_s + 1
         elseif ( (part%xp(1) .LT. xmin) .AND. &
                  (part%xp(2) .LT. ymax) .AND. &
                  (part%xp(2) .GT. ymin) ) then !bottom
            pb_s = pb_s + 1
         end if
         
         part => part%next
      end do
      
      !Now allocate the send buffers based on these counts:
      allocate(rbuf_s(pr_s),trbuf_s(ptr_s),tbuf_s(pt_s),tlbuf_s(ptl_s))
      allocate(lbuf_s(pl_s),blbuf_s(pbl_s),bbuf_s(pb_s),brbuf_s(pbr_s))

      !Now loop back through the particles and fill the buffers:
      !NOTE: If it finds one, add it to buffer and REMOVE from list
      ir=1;itr=1;itop=1;itl=1;il=1;ibl=1;ib=1;ibr=1

      part => first_particle
      do while (associated(part))
         
         if (part%xp(2) .GT. ymax) then 
            if (part%xp(1) .GT. xmax) then !top right
               trbuf_s(itr) = part
               call destroy_particle
               itr = itr + 1 
            elseif (part%xp(1) .LT. xmin) then !bottom right
               brbuf_s(ibr) = part
               call destroy_particle
               ibr = ibr + 1
            else   !right
               rbuf_s(ir) = part
               call destroy_particle
               ir = ir + 1
            end if
         elseif (part%xp(2) .LT. ymin) then
            if (part%xp(1) .GT. xmax) then !top left
               tlbuf_s(itl) = part
               call destroy_particle
               itl = itl + 1
            else if (part%xp(1) .LT. xmin) then !bottom left
               blbuf_s(ibl) = part
               call destroy_particle
               ibl = ibl + 1
            else  !left
               lbuf_s(il) = part
               call destroy_particle
               il = il + 1
            end if
         elseif ( (part%xp(1) .GT. xmax) .AND. &
                  (part%xp(2) .LT. ymax) .AND. &
                  (part%xp(2) .GT. ymin) ) then !top
            tbuf_s(itop) = part
            call destroy_particle
            itop = itop + 1
         elseif ( (part%xp(1) .LT. xmin) .AND. &
                  (part%xp(2) .LT. ymax) .AND. &
                  (part%xp(2) .GT. ymin) ) then !bottom
            bbuf_s(ib) = part
            call destroy_particle
            ib = ib + 1 
         else
         part => part%next
         end if 
         
      end do

      !Now everyone exchanges the counts with all neighbors:
      !Left/right:
      call MPI_Sendrecv(pr_s,1,mpi_integer,rproc,3, &
             pl_r,1,mpi_integer,lproc,3,mpi_comm_world,istatus,ierr)

      call MPI_Sendrecv(pl_s,1,mpi_integer,lproc,4, &
             pr_r,1,mpi_integer,rproc,4,mpi_comm_world,istatus,ierr)

      !Top/bottom:
      call MPI_Sendrecv(pt_s,1,mpi_integer,tproc,5, &
             pb_r,1,mpi_integer,bproc,5,mpi_comm_world,istatus,ierr)

      call MPI_Sendrecv(pb_s,1,mpi_integer,bproc,6, &
             pt_r,1,mpi_integer,tproc,6,mpi_comm_world,istatus,ierr)

      !Top right/bottom left:
      call MPI_Sendrecv(ptr_s,1,mpi_integer,trproc,7, &
             pbl_r,1,mpi_integer,blproc,7,mpi_comm_world,istatus,ierr)

      call MPI_Sendrecv(pbl_s,1,mpi_integer,blproc,8, &
             ptr_r,1,mpi_integer,trproc,8,mpi_comm_world,istatus,ierr)

       !Top left/bottom right:
      call MPI_Sendrecv(ptl_s,1,mpi_integer,tlproc,9, &
             pbr_r,1,mpi_integer,brproc,9,mpi_comm_world,istatus,ierr)

      call MPI_Sendrecv(pbr_s,1,mpi_integer,brproc,10, &
              ptl_r,1,mpi_integer,tlproc,10,mpi_comm_world,istatus,ierr)

      !Now everyone has the number of particles arriving from every neighbor
      !If the count is greater than zero, exchange:

      !Allocate room to receive from each side
      allocate(rbuf_r(pr_r),trbuf_r(ptr_r),tbuf_r(pt_r),tlbuf_r(ptl_r))
      allocate(lbuf_r(pl_r),blbuf_r(pbl_r),bbuf_r(pb_r),brbuf_r(pbr_r))
     
      !Send to right:
      if (pr_s .GT. 0) then
      call mpi_isend(rbuf_s,pr_s,particletype,rproc,11,mpi_comm_world,req(1),ierr)
      else
      req(1) = mpi_request_null
      end if

      !Receive from left:
      if (pl_r .GT. 0) then
      call mpi_irecv(lbuf_r,pl_r,particletype,lproc,11,mpi_comm_world,req(2),ierr)
      else
      req(2) = mpi_request_null
      end if

      !Send to left:
      if (pl_s .GT. 0) then
      call mpi_isend(lbuf_s,pl_s,particletype,lproc,12,mpi_comm_world,req(3),ierr)
      else
      req(3) = mpi_request_null
      end if

      !Receive from right:
      if (pr_r .GT. 0) then
      call mpi_irecv(rbuf_r,pr_r,particletype,rproc,12,mpi_comm_world,req(4),ierr)
      else
      req(4) = mpi_request_null
      end if

      !Send to top:
      if (pt_s .GT. 0) then
      call mpi_isend(tbuf_s,pt_s,particletype,tproc,13,mpi_comm_world,req(5),ierr)
      else
      req(5) = mpi_request_null
      end if
      
      !Receive from bottom:
      if (pb_r .GT. 0) then
      call mpi_irecv(bbuf_r,pb_r,particletype,bproc,13,mpi_comm_world,req(6),ierr)
      else
      req(6) = mpi_request_null
      end if

      !Send to bottom:
      if (pb_s .GT. 0) then
      call mpi_isend(bbuf_s,pb_s,particletype,bproc,14,mpi_comm_world,req(7),ierr)
      else
      req(7) = mpi_request_null
      end if
      
      !Recieve from top:
      if (pt_r .GT. 0) then
      call mpi_irecv(tbuf_r,pt_r,particletype,tproc,14,mpi_comm_world,req(8),ierr)
      else
      req(8) = mpi_request_null
      end if

      !Send to top right:
      if (ptr_s .GT. 0) then
      call mpi_isend(trbuf_s,ptr_s,particletype,trproc,15,mpi_comm_world,req(9),ierr)
      else
      req(9) = mpi_request_null
      end if
     
      !Receive from bottom left:
      if (pbl_r .GT. 0) then
      call mpi_irecv(blbuf_r,pbl_r,particletype,blproc,15,mpi_comm_world,req(10),ierr)
      else 
      req(10) = mpi_request_null
      end if
    
      !Send to bottom left:
      if (pbl_s .GT. 0) then
      call mpi_isend(blbuf_s,pbl_s,particletype,blproc,16,mpi_comm_world,req(11),ierr)
      else
      req(11) = mpi_request_null
      end if
     
      !Receive from top right:
      if (ptr_r .GT. 0) then
      call mpi_irecv(trbuf_r,ptr_r,particletype,trproc,16,mpi_comm_world,req(12),ierr)
      else 
      req(12) = mpi_request_null
      end if

      !Send to top left:
      if (ptl_s .GT. 0) then
      call mpi_isend(tlbuf_s,ptl_s,particletype,tlproc,17,mpi_comm_world,req(13),ierr)
      else 
      req(13) = mpi_request_null
      end if
    
      !Receive from bottom right:
      if (pbr_r .GT. 0) then
      call mpi_irecv(brbuf_r,pbr_r,particletype,brproc,17,mpi_comm_world,req(14),ierr)
      else 
      req(14) = mpi_request_null
      end if
  
      !Send to bottom right:
      if (pbr_s .GT. 0) then
      call mpi_isend(brbuf_s,pbr_s,particletype,brproc,18,mpi_comm_world,req(15),ierr)
      else
      req(15) = mpi_request_null
      end if
  
      !Receive from top left:
      if (ptl_r .GT. 0) then
      call mpi_irecv(tlbuf_r,ptl_r,particletype,tlproc,18,mpi_comm_world,req(16),ierr)
      else
      req(16) = mpi_request_null
      end if

      call mpi_waitall(16,req,status_array,ierr)

      !Now add incoming particles to linked list:
      !NOTE: add them to beginning since it's easiest to access (first_particle)

      !Form one large buffer to loop through and add:
      psum = pr_r+ptr_r+pt_r+ptl_r+pl_r+pbl_r+pb_r+pbr_r
      csum = 0
      allocate(totalbuf(psum))
      if (pr_r .GT. 0) then 
         totalbuf(1:pr_r) = rbuf_r(1:pr_r)
         csum = csum + pr_r 
      end if
      if (ptr_r .GT. 0) then 
         totalbuf(csum+1:csum+ptr_r) = trbuf_r(1:ptr_r)
         csum = csum + ptr_r
      end if
      if (pt_r .GT. 0) then 
         totalbuf(csum+1:csum+pt_r) = tbuf_r(1:pt_r)
         csum = csum + pt_r
      end if
      if (ptl_r .GT. 0) then 
         totalbuf(csum+1:csum+ptl_r) = tlbuf_r(1:ptl_r)
         csum = csum + ptl_r
      end if
      if (pl_r .GT. 0) then 
         totalbuf(csum+1:csum+pl_r) = lbuf_r(1:pl_r)
         csum = csum + pl_r
      end if
      if (pbl_r .GT. 0) then 
         totalbuf(csum+1:csum+pbl_r) = blbuf_r(1:pbl_r)
         csum = csum + pbl_r
      end if
      if (pb_r .GT. 0) then 
         totalbuf(csum+1:csum+pb_r) = bbuf_r(1:pb_r)
         csum = csum + pb_r
      end if
      if (pbr_r .GT. 0) then 
         totalbuf(csum+1:csum+pbr_r) = brbuf_r(1:pbr_r)
         csum = csum + pbr_r
      end if

      do idx = 1,psum
        if (.NOT. associated(first_particle)) then
           allocate(first_particle)
           first_particle = totalbuf(idx)
           nullify(first_particle%next,first_particle%prev)
        else
           allocate(first_particle%prev)
           tmp => first_particle%prev
           tmp = totalbuf(idx)
           tmp%next => first_particle
           nullify(tmp%prev)
           first_particle => tmp
           nullify(tmp)
        end if
      end do  
      
      deallocate(rbuf_s,trbuf_s,tbuf_s,tlbuf_s)
      deallocate(lbuf_s,blbuf_s,bbuf_s,brbuf_s)
      deallocate(rbuf_r,trbuf_r,tbuf_r,tlbuf_r)
      deallocate(lbuf_r,blbuf_r,bbuf_r,brbuf_r)
      deallocate(totalbuf)

  end subroutine particle_exchange

  subroutine set_bounds  
        use pars
        use con_data
        use con_stats
        implicit none
        include 'mpif.h'

      !Each processor must figure out at what ymin,ymax,zmin,zmax a particle leaves
      ymin = dy*(iys-1)
      ymax = dy*(iye)
      zmin = z(izs-1)
      zmax = z(ize)  
      xmin = dx*(mxs-1)
      xmax = dx*(mxe)

  end subroutine set_bounds

  subroutine particle_init
      use pars
      use con_data
      implicit none
      include 'mpif.h' 
      integer :: values(8)
      integer :: idx,ierr
      integer*8 :: mult
      real :: xv,yv,zv,ran2,deltaz
      real :: maxx,maxy,maxz
      real :: xp_init(3),rad_init,m_s,Os
      real :: S,M
      integer*8 :: num_a,num_c,totnum_a,totnum_c

      !Create the seed for the random number generator:
      call date_and_time(VALUES=values)
      iseed = -(myid+values(8)+values(7)+values(6))

      !Initialize ngidx, the particle global index
      ngidx = 1
  
      !For the channel case, set the total number of particles:
      deltaz = zmax-zmin

      numpart = tnumpart/numprocs
      if (myid == 0) then
      numpart = numpart + MOD(tnumpart,numprocs)
      endif

      !Initialize the linked list of particles:
      nullify(part,first_particle)
      
      !Now initialize all particles with a random location on that processor
      maxx=0.0
      maxy=0.0
      maxz=0.0
      num_a = 0
      num_c = 0
      do idx=1,numpart
      xv = ran2(iseed)*(xmax-xmin) + xmin
      yv = ran2(iseed)*(ymax-ymin) + ymin
      zv = ran2(iseed)*(zi-zw1) + zw1
      xp_init = (/xv,yv,zv/)

      !Get the initial droplet size based on some distribution:

      !From params file -- all particles identical
      !rad_init = radius_init
      !m_s = Sal*2.0/3.0*pi2*radius_init**3*rhow

      !call exponential_dist(rad_init)  !From Shima et al. (2009) test case
      !m_s = Sal*4.0/3.0*pi*radius_init**3*rhow


!!!!!!! DOUBLE LOGNORMAL
      !Generate a double lognormal from individual coarse & accumulation modes
      !call double_lognormal_dist(rad_init,m_s,Os,mult)  !First attempt!


      !Generate
!      if (ran2(iseed) .gt. pdf_prob) then   !It's accumulation mode
!         S = 0.5
!         M = -1.95
!         Os = 0.5
!         mult = mult_a
!
!         !With these parameters, get m_s and rad_init from distribution
!         call lognormal_dist(rad_init,m_s,Os,M,S)
!         num_a = num_a + 1
!
!       else  !It's coarse mode
!
!         S = 0.45
!         M = 0.0
!         Os = 1.0
!         mult = mult_c
!
!         !With these parameters, get m_s and rad_init from distribution
!         call lognormal_dist(rad_init,m_s,Os,M,S)
!         num_c = num_c + 1
!
!       end if



!!!!!!! UNIFORM

!      if (ran2(iseed) .gt. 0.5) then
!      Os = 0.5
!      else
!      Os = 1.0
!      end if
!      mult = mult_init
!      call uniform_dist(rad_init,m_s,Os)

!       !Force the output particle to be a coarse mode particle
!       if (idx==1 .and. myid==0) then
!            !Force particle log output to be a coarse mode in fog layer -- "giant mode"
!            S = 0.45
!            M = 0.0
!            Os = 1.0
!            mult = mult_c
!
!            !With these parameters, get m_s and rad_init from distribution
!            call lognormal_dist(rad_init,m_s,Os,M,S)
!            xp_init(3) = 10.0
!        end if


!!!!! More appropriate for sea spray:
         Os = 1.0
         mult = mult_init
         rad_init = radius_init   ! From the params.in file
         m_s = rad_init**3*pi2*2.0/3.0*rhow*Sal  !Using the salinity specified in params.in
         
         Tp_init = tsfcc(1)

         xp_init(1) = ran2(iseed)*(xmax-xmin) + xmin
         xp_init(2) = ran2(iseed)*(ymax-ymin) + ymin
         xp_init(3) = ran2(iseed)*zl

      call create_particle(xp_init,vp_init,Tp_init,m_s,Os,mult,rad_init,idx,myid) 
      end do


      partTsrc = 0.0
      partTsrc_t = 0.0
      partHsrc = 0.0
      partHsrc_t = 0.0
      partTEsrc = 0.0
      partTEsrc_t = 0.0


  end subroutine particle_init

  subroutine particle_setup

      use pars
      implicit none 
      include 'mpif.h'

      integer :: blcts(3),types(3)
      integer :: ierr
      real :: pi
      integer(kind=MPI_ADDRESS_KIND) :: extent,lb
      integer(kind=MPI_ADDRESS_KIND) :: extent2,lb2,displs(3)
      integer :: num_reals,num_integers,num_longs

      !First set up the neighbors for the interpolation stage:
      call assign_nbrs

      !Also assign the x,y,z max and mins to track particles leaving
      call set_bounds


      !Lognormal distribution parameters  -- Must be called even on
      !restart!
      mult_factor = 200
      pdf_factor = 0.02*real(mult_factor)
      pdf_prob = pdf_factor/(1 + pdf_factor)

      !Adjust the multiplicity so that the total number of particles
      !isn't altered:
      mult_c = mult_init/mult_factor
      mult_a = mult_init/(1.0-pdf_prob)*(1 - pdf_prob/real(mult_factor))


      !set_binsdata does logarithmic binning!
      !Radius histogram
      call set_binsdata(bins_rad,histbins+2,1.0e-8,1.0e-3)

      !Residence time histogram
      call set_binsdata(bins_res,histbins+2,1.0e-1,1.0e4)

      !Activated time histogram
      call set_binsdata(bins_actres,histbins+2,1.0e-1,1.0e4)

      !Num activations histogram
      call set_binsdata_integer(bins_numact,histbins+2,0.0)


      !Initialize the linked list of particles:
      nullify(part,first_particle)

      !Set up MPI datatypes for sending particle information
      !MUST UPDATE IF THINGS ARE ADDED/REMOVED FROM PARTICLE STRUCTURE

      num_reals = 6*3+16
      num_integers = 4
      num_longs = 3
      
      blcts(1:3) = (/num_integers,num_reals,num_longs/)
      displs(1) = 0
      types(1) = mpi_integer
      call mpi_type_get_extent(mpi_integer,lb,extent,ierr)
      
      !Displace num_integers*mpi_integer
      displs(2) = extent*num_integers
      types(2) = mpi_real8
      call mpi_type_get_extent(mpi_real8,lb,extent,ierr)
      !Displace num_reals*size of mpi_real8
      displs(3) = displs(2) + extent*num_reals
      types(3) = mpi_integer8

      !Now define the type:
      call mpi_type_create_struct(3,blcts,displs,types,particletype,ierr)

       call mpi_type_get_true_extent(particletype,lb2,extent2,ierr)
       call mpi_type_get_extent(particletype,lb2,extent,ierr)
       if (extent .NE. sizeof(part) ) then
          if (myid==0) then
          write(*,*) 'WARNING: extent of particletype not equalto sizeof(part):'
          write(*,*) 'sizeof(part) = ', sizeof(part)
          write(*,*) 'mpi_type_get_true_extent(particletype) = ',extent2
          write(*,*) 'mpi_type_get_extent(particletype) = ',extent
          end if
       end if
      
      !Need to compute any padding which may exist in particle struct:
      pad_diff = extent-extent2 
      if (myid==0) then
      write(*,*) 'mpi_get_extent = ',extent
      write(*,*) 'mpi_get_true_extent = ',extent2
      write(*,*) 'sizeof(part) = ',sizeof(part)
      write(*,*) 'DIFF = ',pad_diff
      end if
      if (pad_diff .LT. 0) then
        write(*,*) 'WARNING: mpi_get_extent - mpi_get_true_extent LT 0!'
        call mpi_finalize(ierr)
        stop
      end if
      
      if (myid==0) then
      write(*,*) 'huge(tnumpart) = ',huge(tnumpart)
      write(*,*) 'huge(part%pidx) = ',huge(part%pidx)
      write(*,*) 'huge(part%mult) = ',huge(part%mult)
      end if


      call mpi_type_commit(particletype,ierr)

  end subroutine particle_setup

  subroutine save_particles
      use pars
      implicit none
      include 'mpif.h'

      integer :: istatus(mpi_status_size), ierr, fh
      integer(kind=mpi_offset_kind) :: zoffset,offset
      integer :: pnum_vec(numprocs)
      integer :: iproc,i
      type(particle) :: writebuf(numpart),tmp

      !Do this with mpi_write_at_all
      !Need to figure out the displacements - need numpart from each proc
      call mpi_allgather(numpart,1,mpi_integer,pnum_vec,1,mpi_integer,mpi_comm_world,ierr)

      !Package all the particles into writebuf:
      i = 1
      part => first_particle
      do while (associated(part))
      writebuf(i) = part
      !write(*,'a5,3e15.6') 'xp:',part%xp(1:3)
      part => part%next
      i = i + 1
      end do

      !Now only write to the file if you actually have particles
      !EXCEPTION: proc 0, which needs to write tnumpart regardless
      call mpi_file_open(mpi_comm_world, path_sav_part, &
                        mpi_mode_create+mpi_mode_rdwr, &
                        mpi_info_null,fh,ierr)

      zoffset = 0
      !Write tnumpart first:
      if (myid==0) then
      call mpi_file_write_at(fh,zoffset,tnumpart,1,mpi_integer,istatus,ierr)
      write(*,*) 'wrote tnumpart = ',tnumpart
      end if

      zoffset = zoffset + 4
     
      !Now compute the offset (in bytes!):
      offset = zoffset 
      do iproc = 0,myid-1
         offset = offset + pnum_vec(iproc+1)*(sizeof(tmp)-pad_diff) 
      end do

      !Now everyone else write, ONLY if numpart > 0
      if (numpart .GT. 0) then
      call mpi_file_write_at(fh,offset,writebuf,numpart,particletype,istatus,ierr)
      end if

      call mpi_file_close(fh,ierr)

      write(*,*) 'proc',myid,'wrote numpart = ',numpart

      if (myid==0) write(*,7000) path_sav_part
 7000 format(' PARTICLE DATA IS WRITTEN IN FILE  ',a80)

  end subroutine save_particles

  subroutine read_part_res
      use pars
      implicit none
      include 'mpif.h'

      integer :: istatus(mpi_status_size), ierr, fh
      integer(kind=mpi_offset_kind) :: zoffset,offset
      integer :: myp,totalp 
      integer :: iproc,i,pidxmax,numloop,partloop,readpart
      type(particle), allocatable :: readbuf(:)

      if (myid==0) write(*,7000) path_part 
 7000 format(' READING PARTICLE DATA FROM  ',a80)


      call mpi_file_open(mpi_comm_world,path_part,  &
                        mpi_mode_rdonly, &
                        mpi_info_null,fh,ierr)


      !Read in the total number of particles:
      offset = 0
      call mpi_file_read_at_all(fh,offset,tnumpart,1,mpi_integer,istatus,ierr)
      if (myid==0) write(*,*) 'read tnumpart = ',tnumpart
    
      offset = 4

      !For many particles (above ~10 million), I can't read them all
      !into the readbuf at the same time - must break up into chunks.
      !Arbitrarily choose 5 million particles at a time (~840 MB)

      !numloop will be 1 if tnumpart < 5 million, increasing from there
      numloop = floor(tnumpart/5e6)+1

      do partloop = 1,numloop

      if (partloop == numloop) then
         readpart = tnumpart - (numloop-1)*5e6
      else
         readpart = 5e6
      end if

      allocate(readbuf(readpart))

      call mpi_file_read_at_all(fh,offset,readbuf,readpart,particletype,istatus,ierr)

      do i = 1,readpart
        !Now - does it lie within this proc's bounds?
        if (readbuf(i)%xp(2) .GT. ymin .AND. &
            readbuf(i)%xp(2) .LT. ymax .AND. &
            readbuf(i)%xp(1) .GT. xmin .AND. &
            readbuf(i)%xp(1) .LT. xmax) then 
            if (.NOT. associated(first_particle)) then
               allocate(first_particle)
               first_particle = readbuf(i)
               nullify(first_particle%prev,first_particle%next)
               part => first_particle
            else
               allocate(part%next)
               part%next = readbuf(i)
               part%next%prev => part
               part => part%next
               nullify(part%next)
            end if

        end if
      end do

      deallocate(readbuf)

      offset = offset + sizeof(part)*readpart

      end do

      call mpi_file_close(fh,ierr)
      
      !Now just check how many each processor obtained:
      !At the same time, figure out max(pidx) and set ngidx 
      !to one plus this value:
      pidxmax = 0
      part => first_particle
      myp = 0
      do while (associated(part))
         myp = myp+1
         if (part%pidx .gt. pidxmax) pidxmax = part%pidx
         part => part%next
      end do

      !Set ngidx (the index for creating new particles) to 1+pidmax:
      ngidx = pidxmax + 1

      numpart = myp
     
      call mpi_allreduce(myp,totalp,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)

      write(*,*) 'proc',myid,'read in numpart:',myp
      if (myid==0) write(*,*) 'total number of particles read:',totalp

  end subroutine read_part_res

  subroutine particle_reintro(it)
      use pars
      use con_data
      use con_stats
      use fields
      implicit none
      include 'mpif.h'

      integer :: it
      integer :: ierr,randproc,np,my_reintro
      real :: xp_init(3),ran2,Os,m_s

      my_reintro = nprime*(1./60.)*(10.**6.)*dt*4/numprocs*20.0 !4m^3 (vol chamber)

      tot_reintro = 0

      if (mod(it, 20)==0) then

      tot_reintro = my_reintro*numprocs

      if (myid==0) write(*,*) 'time,tot_reintro:',time,tot_reintro

      do np=1,my_reintro

      !Proc 0 gets a random proc ID, broadcasts it out:
      !if (myid==0) randproc = floor(ran2(iseed)*numprocs)
      !call mpi_bcast(randproc,1,mpi_integer,0,mpi_comm_world,ierr)


         xp_init(1) = ran2(iseed)*(xmax-xmin) + xmin
         xp_init(2) = ran2(iseed)*(ymax-ymin) + ymin
         xp_init(3) = ran2(iseed)*zl/2.0

         Os = 1.0
         m_s = radius_init**3*pi2*2.0/3.0*rhow*Sal  !Using the salinity specified in params.in
         

         call create_particle(xp_init,vp_init, &
              Tp_init,m_s,Os,mult_init,radius_init,2,myid) 

      end do
      end if


  end subroutine particle_reintro

  subroutine create_particle(xp,vp,Tp,m_s,Os,mult,rad_init,idx,procidx)
      use pars
      implicit none

      real :: xp(3),vp(3),Tp,qinfp,rad_init,pi,m_s,Os
      integer :: idx,procidx
      integer*8 :: mult

      if (.NOT. associated(first_particle)) then
         allocate(first_particle)
         part => first_particle
         nullify(part%next,part%prev)
      else
         !Add to beginning of list since it's more convenient
         part => first_particle
         allocate(part%prev)
         first_particle => part%prev
         part%prev%next => part
         part => first_particle
         nullify(part%prev)
      end if

      pi = 4.0*atan(1.0)
  
      part%xp(1:3) = xp(1:3)
      part%vp(1:3) = vp(1:3)
      part%Tp = Tp
      part%radius = rad_init
      part%uf(1:3) = vp(1:3)
      part%qinf = tsfcc(2)
      part%qstar = 0.008
      part%Tf = Tp
      part%xrhs(1:3) = 0.0
      part%vrhs(1:3) = 0.0 
      part%Tprhs_s = 0.0
      part%Tprhs_L = 0.0
      part%radrhs = 0.0
      part%pidx = idx 
      part%procidx = procidx
      part%nbr_pidx = -1
      part%nbr_procidx = -1
      part%mult = mult
      part%res = 0.0
      part%actres = 0.0
      part%m_s = m_s
      part%Os = Os
      part%dist = 0.0
      part%u_sub(1:3) = 0.0
      part%sigm_s = 0.0
      part%numact = 0.0

      
  end subroutine create_particle

  subroutine particle_bcs_periodic
      use pars
      implicit none 

      !Assumes domain goes from [0,xl),[0,yl),[0,zl] 
      !Also maintain the number of particles on each proc
      
      part => first_particle
      do while (associated(part))

      !x,y periodic
   
      if (part%xp(1) .GT. xl) then
         part%xp(1) = part%xp(1)-xl
      elseif (part%xp(1) .LT. 0) then
         part%xp(1) = xl + part%xp(1)
      end if

      if (part%xp(2) .GT. yl) then
         part%xp(2) = part%xp(2)-yl
      elseif (part%xp(2) .LT. 0) then
         part%xp(2) = yl + part%xp(2)
      end if

      part => part%next

      end do


  end subroutine particle_bcs_periodic

  subroutine particle_update_rk3(it,istage)
      use pars
      use con_data
      use con_stats
      implicit none
      include 'mpif.h'

      integer :: istage,ierr,it
      real :: pi
      real :: denom,dtl,sigma
      integer :: ix,iy,iz
      real :: Rep,diff(3),diffnorm,corrfac,myRep_avg
      real :: xtmp(3),vtmp(3),Tptmp,radiustmp
      real :: Nup,Shp,rhop,taup_i,estar,einf
      real :: mylwc_sum,myphiw_sum,myphiv_sum,Volp      
      real :: Eff_C,Eff_S
      real :: t_s,t_f,t_s1,t_f1


      !First fill extended velocity field for interpolation
      !t_s = mpi_wtime()
      call fill_ext 
      !t_f = mpi_wtime()
      !call mpi_barrier(mpi_comm_world,ierr)
      !if (myid==5) write(*,*) 'time fill_ext:',t_f-t_s


      partcount_t = 0.0
      vpsum_t = 0.0
      upwp_t = 0.0
      vpsqrsum_t = 0.0
      Tpsum_t = 0.0
      Tfsum_t = 0.0
      qfsum_t = 0.0
      radsum_t = 0.0  
      rad2sum_t = 0.0  
      multcount_t = 0.0
      mwsum_t = 0.0
      Tpsqrsum_t = 0.0
      wpTpsum_t = 0.0
      myRep_avg = 0.0
      mylwc_sum = 0.0
      myphiw_sum = 0.0
      myphiv_sum = 0.0
      qstarsum_t = 0.0 

      t_s = mpi_wtime()


      !If you want, you can have the particles calculate nearest neighbor
      !Brute is there for checking, but WAY slower
      if (ineighbor) then
      !t_s = mpi_wtime()

      call particle_neighbor_search_kd
      !call particle_neighbor_search_brute

      !call mpi_barrier(mpi_comm_world,ierr)
      !t_f = mpi_wtime()
      !if (myid==5) write(*,*) 'time neighbor:', t_f - t_s
      end if


      !Loop over the linked list of particles:
      part => first_particle
      do while (associated(part))     
         !First, interpolate to get the fluid velocity part%uf(1:3):
         if (ilin .eq. 1) then
            call uf_interp_lin   !Use trilinear interpolation
         else
            call uf_interp       !Use 6th order Lagrange interpolation
         end if

         if (iexner .eq. 1) then
             part%Tf = part%Tf*(psurf/(psurf-part%xp(3)*rhoa*grav))**(-Rd/Cpa)
         end if


         if (it .LE. 1 ) then 
            !part%xrhs(1:3) = part%vp(1:3)
            !part%xp(1:3) = xtmp(1:3) + dt*gama(istage)*part%xrhs(1:3)
            part%vp(1:3) = part%uf
            part%Tp = part%Tf
         endif

         !Now advance the particle and position via RK3 (same as velocity)
        
         !Intermediate Values
         pi = 4.0*atan(1.0)  
         diff(1:3) = part%vp - part%uf
         diffnorm = sqrt(diff(1)**2 + diff(2)**2 + diff(3)**2)
         Rep = 2.0*part%radius*diffnorm/nuf  
         Volp = pi2*2.0/3.0*part%radius**3
         rhop = (part%m_s+Volp*rhow)/Volp
         taup_i = 18.0*rhoa*nuf/rhop/(2.0*part%radius)**2 

         myRep_avg = myRep_avg + Rep
         corrfac = (1.0 + 0.15*Rep**(0.687))
         mylwc_sum = mylwc_sum + Volp*rhop*real(part%mult)
         myphiw_sum = myphiw_sum + Volp*rhow
         myphiv_sum = myphiv_sum + Volp


         !Compute Nusselt number for particle:
         !Ranz-Marshall relation
         Nup = 2.0 + 0.6*Rep**(1.0/2.0)*Pra**(1.0/3.0)
         Shp = 2.0 + 0.6*Rep**(1.0/2.0)*Sc**(1.0/3.0)


         !Mass Transfer calculations
         einf = mod_Magnus(part%Tf)
         Eff_C = 2.0*Mw*Gam/(Ru*rhow*part%radius*part%Tp)
         Eff_S = Ion*part%Os*part%m_s*Mw/Ms/(Volp*rhop-part%m_s)
         estar = einf*exp(Mw*Lv/Ru*(1.0/part%Tf-1.0/part%Tp)+Eff_C-Eff_S)
         part%qstar = Mw/Ru*estar/part%Tp/rhoa

  
         xtmp(1:3) = part%xp(1:3) + dt*zetas(istage)*part%xrhs(1:3)
         vtmp(1:3) = part%vp(1:3) + dt*zetas(istage)*part%vrhs(1:3) 
         Tptmp = part%Tp + dt*zetas(istage)*part%Tprhs_s
         Tptmp = Tptmp + dt*zetas(istage)*part%Tprhs_L
         radiustmp = part%radius + dt*zetas(istage)*part%radrhs

         part%xrhs(1:3) = part%vp(1:3)
         part%vrhs(1:3) = corrfac*taup_i*(part%uf(1:3)-part%vp(1:3)) + part_grav(1:3)

         if (ievap .EQ. 1) then      
            part%radrhs = Shp/9.0/Sc*rhop/rhow*part%radius*taup_i*(part%qinf-part%qstar) !assumes qinf=rhov/rhoa rather than rhov/rhom
         else
            part%radrhs = 0.0
         end if


         part%Tprhs_s = -Nup/3.0/Pra*CpaCpp*rhop/rhow*taup_i*(part%Tp-part%Tf)
         part%Tprhs_L = 3.0*Lv/Cpp/part%radius*part%radrhs



  
         part%xp(1:3) = xtmp(1:3) + dt*gama(istage)*part%xrhs(1:3)
         part%vp(1:3) = vtmp(1:3) + dt*gama(istage)*part%vrhs(1:3)
         part%Tp = Tptmp + dt*gama(istage)*part%Tprhs_s
         part%Tp = part%Tp + dt*gama(istage)*part%Tprhs_L
         part%radius = radiustmp + dt*gama(istage)*part%radrhs


         if (istage .eq. 3) part%res = part%res + dt


        part => part%next
      end do



      !t_f1 = mpi_wtime()
      !write(*,*) 'proc,loop time: ',myid,t_f1-t_s
      call mpi_barrier(mpi_comm_world,ierr)
      t_f = mpi_wtime()
      if (myid==5) write(*,*) 'time loop:', t_f-t_s

      !Enforce nonperiodic bcs (either elastic or destroying particles)
      !t_s = mpi_wtime()
      call particle_bcs_nonperiodic
      !call mpi_barrier(mpi_comm_world,ierr)
      !t_f = mpi_wtime()
      !if (myid==5) write(*,*) 'time bc_non:', t_f - t_s

      !Check to see if particles left processor
      !If they did, remove from one list and add to another
      t_s = mpi_wtime()
      call particle_exchange
      call mpi_barrier(mpi_comm_world,ierr)
      t_f = mpi_wtime()
      if (myid==5) write(*,*) 'time exchg:', t_f - t_s

      !Now enforce periodic bcs 
      !just updates x,y locations if over xl,yl or under 0
      !t_s = mpi_wtime()
      call particle_bcs_periodic
      !call mpi_barrier(mpi_comm_world,ierr)
      !t_f = mpi_wtime()
      !if (myid==5) write(*,*) 'time bc_per:', t_f - t_s


      !Now that particles are in their updated position, 
      !compute their contribution to the momentum coupling:
      !t_s = mpi_wtime()
      call particle_coupling_update
      !call mpi_barrier(mpi_comm_world,ierr)
      !t_f = mpi_wtime()
      !if (myid==5) write(*,*) 'time cpl: ', t_f - t_s

      call particle_coupling_exchange

      call particle_stats

 
      !Finally, now that coupling and statistics arrays are filled, 
      !Transpose them back to align with the velocities:
      call ztox_trans(partsrc_t(0:nnz+1,iys:iye,mxs:mxe,1), &
                     partsrc(1:nnx,iys:iye,izs-1:ize+1,1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(partsrc_t(0:nnz+1,iys:iye,mxs:mxe,2), &
                     partsrc(1:nnx,iys:iye,izs-1:ize+1,2),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(partsrc_t(0:nnz+1,iys:iye,mxs:mxe,3), &
                     partsrc(1:nnx,iys:iye,izs-1:ize+1,3),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(partTsrc_t(0:nnz+1,iys:iye,mxs:mxe), &
                     partTsrc(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(partHsrc_t(0:nnz+1,iys:iye,mxs:mxe), &
                     partHsrc(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(partTEsrc_t(0:nnz+1,iys:iye,mxs:mxe), &
                     partTEsrc(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(mwsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     mwsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      !Try only calling these when the history data is being written:
      if(mtrans  .and. istage .eq. 3) then
      call ztox_trans(upwp_t(0:nnz+1,iys:iye,mxs:mxe), &
                     upwp(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(vpsum_t(0:nnz+1,iys:iye,mxs:mxe,1), &
                     vpsum(1:nnx,iys:iye,izs-1:ize+1,1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(vpsum_t(0:nnz+1,iys:iye,mxs:mxe,2), &
                     vpsum(1:nnx,iys:iye,izs-1:ize+1,2),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(vpsum_t(0:nnz+1,iys:iye,mxs:mxe,3), &
                     vpsum(1:nnx,iys:iye,izs-1:ize+1,3),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(vpsqrsum_t(0:nnz+1,iys:iye,mxs:mxe,1), &
                     vpsqrsum(1:nnx,iys:iye,izs-1:ize+1,1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(vpsqrsum_t(0:nnz+1,iys:iye,mxs:mxe,2), &
                     vpsqrsum(1:nnx,iys:iye,izs-1:ize+1,2),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(vpsqrsum_t(0:nnz+1,iys:iye,mxs:mxe,3), &
                     vpsqrsum(1:nnx,iys:iye,izs-1:ize+1,3),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(Tpsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     Tpsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(Tpsqrsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     Tpsqrsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(Tfsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     Tfsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(qfsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     qfsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(wpTpsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     wpTpsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(partcount_t(0:nnz+1,iys:iye,mxs:mxe), &
                     partcount(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(radsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     radsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(rad2sum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     rad2sum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs) 

      call ztox_trans(multcount_t(0:nnz+1,iys:iye,mxs:mxe), &
                     multcount(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)


      call ztox_trans(qstarsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     qstarsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      end if


      !t_s = mpi_wtime
      !Get particle count:
      numpart = 0
      part => first_particle
      do while (associated(part))
      numpart = numpart + 1
      part => part%next
      end do
      !call mpi_barrier(mpi_comm_world,ierr)
      !t_f = mpi_wtime()
      !if (myid==5) write(*,*) 'time numpart: ', t_f - t_s
 
      !t_s = mpi_wtime()
      !Compute total number of particles
      call mpi_allreduce(numpart,tnumpart,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)
      !Compute average particle Reynolds number
      call mpi_allreduce(myRep_avg,Rep_avg,1,mpi_real8,mpi_sum,mpi_comm_world,ierr)

      Rep_avg = Rep_avg/tnumpart

      call mpi_allreduce(mylwc_sum,lwc,1,mpi_real8,mpi_sum,mpi_comm_world,ierr)

      call mpi_allreduce(myphiw_sum,phiw,1,mpi_real8,mpi_sum,mpi_comm_world,ierr)

      call mpi_allreduce(myphiv_sum,phiv,1,mpi_real8,mpi_sum,mpi_comm_world,ierr)

      
      phiw = phiw/xl/yl/zl/rhoa
      phiv = phiv/xl/yl/zl

      !call mpi_barrier(mpi_comm_world,ierr)
      !t_f = mpi_wtime()
      !if (myid==5) write(*,*) 'time mpi_allreduce: ', t_f - t_s

  end subroutine particle_update_rk3

  subroutine particle_update_BE(it)
      use pars
      use con_data
      use con_stats
      implicit none
      include 'mpif.h'

      integer :: ierr,it,fluxloc,fluxloci
      real :: tmpbuf(6),tmpbuf_rec(6)
      real :: myradavg,myradmax,myradmin,mytempmax,mytempmin
      real :: myradmsqr
      real :: myqmin,myqmax
      real :: denom,dtl,sigma
      integer :: ix,iy,iz,im,flag,mflag,act_tmp,myact_tmp
      real :: Rep,diff(3),diffnorm,corrfac,myRep_avg
      real :: xtmp(3),vtmp(3),Tptmp,radiustmp
      real :: Nup,Shp,rhop,taup_i,estar,einf
      real :: mylwc_sum,myphiw_sum,myphiv_sum,Volp
      real :: Eff_C,Eff_S
      real :: t_s,t_f,t_s1,t_f1
      real :: rt_start(2)
      real :: rt_zeroes(2)
      real :: taup0, dt_taup0, temp_r, temp_t, guess
      real :: tmp_coeff
      real :: xp3i



      !First fill extended velocity field for interpolation
      call fill_ext

      partcount_t = 0.0
      vpsum_t = 0.0
      upwp_t = 0.0
      vpsqrsum_t = 0.0
      Tpsum_t = 0.0
      Tfsum_t = 0.0
      qfsum_t = 0.0
      radsum_t = 0.0
      rad2sum_t = 0.0
      multcount_t = 0.0
      mwsum_t = 0.0
      Tpsqrsum_t = 0.0
      wpTpsum_t = 0.0
      myRep_avg = 0.0
      mylwc_sum = 0.0
      myphiw_sum = 0.0
      myphiv_sum = 0.0
      qstarsum_t = 0.0

      partsrc_t = 0.0
      partTsrc_t = 0.0
      partHsrc_t = 0.0
      partTEsrc_t = 0.0

      pflux = 0.0

      denum = 0
      actnum = 0
      num100 = 0
      num1000 = 0
      numimpos = 0
      num_destroy = 0

      !loop over the linked list of particles
      part => first_particle
      do while (associated(part))


         !First, interpolate to get the fluid velocity part%uf(1:3):
         if (ilin .eq. 1) then
            call uf_interp_lin   !Use trilinear interpolation
         else
            call uf_interp       !Use 6th order Lagrange interpolation
         end if


        if (it .LE. 1) then
           part%vp(1:3) = part%uf
        end if

         if (iexner .eq. 1) then
             part%Tf = part%Tf*(psurf/(psurf-part%xp(3)*rhoa*grav))**(-Rd/Cpa)
         end if

        diff(1:3) = part%vp - part%uf
        diffnorm = sqrt(diff(1)**2 + diff(2)**2 + diff(3)**2)
        Volp = pi2*2.0/3.0*part%radius**3
        rhop = (part%m_s+Volp*rhow)/Volp
        taup_i = 18.0*rhoa*nuf/rhop/(2.0*part%radius)**2
        Rep = 2.0*part%radius*diffnorm/nuf
        corrfac = (1.0 + 0.15*Rep**(0.687))

        corrfac = 1.0

        xp3i = part%xp(3)   !Store this to do flux calculation

        !implicitly calculates next velocity and position
        part%xp(1:3) = part%xp(1:3) + dt*part%vp(1:3)
        part%vp(1:3) = (part%vp(1:3)+taup_i*dt*corrfac*part%uf(1:3)+dt*part_grav(1:3))/(1+dt*corrfac*taup_i)



        !Store the particle flux now that we have the new position
        if (part%xp(3) .gt. zl) then   !This will get treated in particle_bcs_nonperiodic, but record here
           fluxloc = nnz+1
           fluxloci = minloc(z,1,mask=(z.gt.xp3i))-1
        elseif (part%xp(3) .lt. 0.0) then !This will get treated in particle_bcs_nonperiodic, but record here
           fluxloci = minloc(z,1,mask=(z.gt.xp3i))-1
           fluxloc = 0
        else

        fluxloc = minloc(z,1,mask=(z.gt.part%xp(3)))-1
        fluxloci = minloc(z,1,mask=(z.gt.xp3i))-1

        end if  !Only apply flux calc to particles in domain

        if (xp3i .lt. part%xp(3)) then !Particle moved up

        do iz=fluxloci,fluxloc-1
           pflux(iz) = pflux(iz) + part%mult
        end do

        elseif (xp3i .gt. part%xp(3)) then !Particle moved down

        do iz=fluxloc,fluxloci-1
           pflux(iz) = pflux(iz) - part%mult
        end do

        end if  !Up/down conditional statement


        ! non-dimensionalizes particle radius and temperature before
        ! iteratively solving for next radius and temperature

        taup0 = (((part%m_s)/((2./3.)*pi2*radius_init**3) + rhow)*(radius_init*2)**2)/(18*rhoa*nuf)

        dt_taup0 = dt/taup0

        if (ievap .EQ. 1) then

               !Gives initial guess into nonlinear solver
               !mflag = 0, has equilibrium radius; mflag = 1, no
               !equilibrium (uses itself as initial guess)
               call rad_solver2(guess,mflag)

               if (mflag == 0) then
                rt_start(1) = guess/part%radius
                rt_start(2) = part%Tf/part%Tp
               else
                rt_start(1) = 1.0
                rt_start(2) = 1.0
               end if

               call gauss_newton_2d(part%vp,dt_taup0,rt_start, rt_zeroes,flag)

               if (flag==1) then
               num100 = num100+1

               call LV_solver(part%vp,dt_taup0,rt_start, rt_zeroes,flag)

               end if

               if (flag == 1) num1000 = num1000 + 1

               if      (isnan(rt_zeroes(1)) &
                  .OR. (rt_zeroes(1)*part%radius<0) &
                  .OR. isnan(rt_zeroes(2)) &
                  .OR. (rt_zeroes(2)<0) &
                  .OR. (rt_zeroes(1)*part%radius>1.0e-2) & !These last 3 are very specific to pi chamber
                  .OR. (rt_zeroes(2)*part%Tp > Tbot(1)*1.1)  &
                  .OR. (rt_zeroes(2)*part%Tp < Ttop(1)*0.9)) &
              then

                numimpos = numimpos + 1  !How many have failed?
                !If they failed (should be very small number), radius,
                !temp remain unchanged
                rt_zeroes(1) = 1.0
                rt_zeroes(2) = part%Tf/part%Tp

                write(*,'(a30,14e15.6)') 'WARNING: CONVERGENCE',  &
               part%radius,part%qinf,part%Tp,part%Tf,part%xp(3), &
               part%Os,part%m_s,part%vp(1),part%vp(2),part%vp(3), &
               part%res,part%sigm_s,rt_zeroes(1),rt_zeroes(2)

               end if

               !Get the critical radius based on old temp
               part%rc = crit_radius(part%m_s,part%Os,part%Tp) 

               !Count if activated/deactivated
               if (part%radius > part%rc .AND. part%radius*rt_zeroes(1) < part%rc) then
                   denum = denum + 1

                   !Also add activated lifetime to histogram
               call add_histogram(bins_actres,hist_actres,histbins+2,part%actres,part%mult)
                   

               elseif (part%radius < part%rc .AND. part%radius*rt_zeroes(1) > part%rc) then
                   actnum = actnum + 1
                   part%numact = part%numact + 1.0

                   !Reset the activation lifetime
                   part%actres = 0.0

               endif

               !Redimensionalize
               part%radius = rt_zeroes(1)*part%radius
               part%Tp = rt_zeroes(2)*part%Tp
        end if

         if (part%radius .gt. 1.0e-2) then
         write(*,'(a30,12e15.6)') 'WARNING: BIG DROPLET',  &
         part%radius,part%qinf,part%Tp,part%Tf,part%xp(3), &
         part%Os,part%m_s,part%vp(1),part%vp(2),part%vp(3), &
         part%res,part%sigm_s
         end if

         if (part%qinf .lt. 0.0) then
         write(*,'(a30,12e15.6)') 'WARNING: NEG QINF',  &
         part%radius,part%qinf,part%Tp,part%Tf,part%xp(3), &
         part%Os,part%m_s,part%vp(1),part%vp(2),part%vp(3), &
         part%res,part%sigm_s
         end if


         !Intermediate Values
         diff(1:3) = part%vp - part%uf
         diffnorm = sqrt(diff(1)**2 + diff(2)**2 + diff(3)**2)
         Rep = 2.0*part%radius*diffnorm/nuf

         myRep_avg = myRep_avg + Rep
         corrfac = (1.0 + 0.15*Rep**(0.687))
         mylwc_sum = mylwc_sum + Volp*rhop*real(part%mult)
         myphiw_sum = myphiw_sum + Volp*rhow
         myphiv_sum = myphiv_sum + Volp

         !Compute Nusselt number for particle:
         !Ranz-Marshall relation
         Nup = 2.0 + 0.6*Rep**(1.0/2.0)*Pra**(1.0/3.0)
         Shp = 2.0 + 0.6*Rep**(1.0/2.0)*Sc**(1.0/3.0)

         !Mass Transfer calculations
         einf = mod_Magnus(part%Tf)

         Eff_C = 2.0*Mw*Gam/(Ru*rhow*part%radius*part%Tp)
         Eff_S = Ion*part%Os*part%m_s*Mw/Ms/(Volp*rhop-part%m_s)
         estar = einf*exp(Mw*Lv/Ru*(1.0/part%Tf-1.0/part%Tp)+Eff_C-Eff_S)
         part%qstar = Mw/Ru*estar/part%Tp/rhoa

        if (ievap .EQ. 1) then
            part%radrhs = Shp/9.0/Sc*rhop/rhow*part%radius*taup_i*(part%qinf-part%qstar) !assumes qinf=rhov/rhoa rather than rhov/rhom
        else

            part%radrhs = 0.0

            !Also update the temperature directly using BE:
            tmp_coeff = -Nup/3.0/Pra*CpaCpp*rhop/rhow*taup_i
            part%Tp = (part%Tp + tmp_coeff*dt*part%Tf)/(1+dt*tmp_coeff)
        end if

        part%Tprhs_s = -Nup/3.0/Pra*CpaCpp*rhop/rhow*taup_i*(part%Tp-part%Tf)
        part%Tprhs_L = 3.0*Lv/Cpp/part%radius*part%radrhs

        part%xrhs(1:3) = part%vp(1:3)
        part%vrhs(1:3) = corrfac*taup_i*(part%uf(1:3)-part%vp(1:3)) + part_grav(1:3)

        part%res = part%res + dt
        part%actres = part%actres + dt


      part => part%next
      end do


      !Enforce nonperiodic bcs (either elastic or destroying particles)
      call particle_bcs_nonperiodic

      !Check to see if particles left processor
      !If they did, remove from one list and add to another

      call particle_exchange

      !Now enforce periodic bcs 
      !just updates x,y locations if over xl,yl or under 0
      call particle_bcs_periodic

      call particle_coupling_update

      call particle_coupling_exchange

      call particle_stats

      !Finally, now that coupling and statistics arrays are filled, 
      !Transpose them back to align with the velocities:
      call ztox_trans(partsrc_t(0:nnz+1,iys:iye,mxs:mxe,1), &
                     partsrc(1:nnx,iys:iye,izs-1:ize+1,1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(partsrc_t(0:nnz+1,iys:iye,mxs:mxe,2), &
                     partsrc(1:nnx,iys:iye,izs-1:ize+1,2),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(partsrc_t(0:nnz+1,iys:iye,mxs:mxe,3), &
                     partsrc(1:nnx,iys:iye,izs-1:ize+1,3),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(partTsrc_t(0:nnz+1,iys:iye,mxs:mxe), &
                     partTsrc(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(partHsrc_t(0:nnz+1,iys:iye,mxs:mxe), &
                     partHsrc(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(partTEsrc_t(0:nnz+1,iys:iye,mxs:mxe), &
                     partTEsrc(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(mwsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     mwsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(partcount_t(0:nnz+1,iys:iye,mxs:mxe), &
                     partcount(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(multcount_t(0:nnz+1,iys:iye,mxs:mxe), &
                     multcount(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(radsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     radsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)



      !Try only calling these when the history data is being written:
      if(mtrans) then
      call ztox_trans(upwp_t(0:nnz+1,iys:iye,mxs:mxe), &
                     upwp(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(vpsum_t(0:nnz+1,iys:iye,mxs:mxe,1), &
                     vpsum(1:nnx,iys:iye,izs-1:ize+1,1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(vpsum_t(0:nnz+1,iys:iye,mxs:mxe,2), &
                     vpsum(1:nnx,iys:iye,izs-1:ize+1,2),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(vpsum_t(0:nnz+1,iys:iye,mxs:mxe,3), &
                     vpsum(1:nnx,iys:iye,izs-1:ize+1,3),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(vpsqrsum_t(0:nnz+1,iys:iye,mxs:mxe,1), &
                     vpsqrsum(1:nnx,iys:iye,izs-1:ize+1,1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs) 
      call ztox_trans(vpsqrsum_t(0:nnz+1,iys:iye,mxs:mxe,2), &
                     vpsqrsum(1:nnx,iys:iye,izs-1:ize+1,2),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(vpsqrsum_t(0:nnz+1,iys:iye,mxs:mxe,3), &
                     vpsqrsum(1:nnx,iys:iye,izs-1:ize+1,3),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(Tpsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     Tpsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(Tpsqrsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     Tpsqrsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(Tfsum_t(0:nnz+1,iys:iye,mxs:mxe), & 
                     Tfsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(qfsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     qfsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)
      call ztox_trans(wpTpsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     wpTpsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(rad2sum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     rad2sum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      call ztox_trans(qstarsum_t(0:nnz+1,iys:iye,mxs:mxe), &
                     qstarsum(1:nnx,iys:iye,izs-1:ize+1),nnx,nnz,mxs, &
                     mxe,mx_s,mx_e,iys,iye,izs,ize,iz_s,iz_e,myid, &
                     ncpu_s,numprocs)

      end if

      !Get particle count:
      numpart = 0
      myact_tmp = 0
      myradavg = 0.0
      myradmsqr = 0.0
      myradmin=1000.0
      myradmax = 0.0
      mytempmin = 1000.0
      mytempmax = 0.0
      myqmin = 1000.0
      myqmax = 0.0
      part => first_particle
      do while (associated(part))
      numpart = numpart + 1
      !Radavg and radmsqr will be only of ACTIVATED droplets
      if (part%radius .gt. part%rc) then
      !if (part%radius .gt. 1.5e-6) then
         myradavg = myradavg + part%radius
         myradmsqr = myradmsqr + part%radius**2
         myact_tmp = myact_tmp + 1
      end if
      if (part%radius .gt. myradmax) myradmax = part%radius
      if (part%radius .lt. myradmin) myradmin = part%radius
      if (part%Tp .gt. mytempmax) mytempmax = part%Tp
      if (part%Tp .lt. mytempmin) mytempmin = part%Tp
      if (part%qstar .gt. myqmax) myqmax = part%qinf
      if (part%qstar .lt. myqmin) myqmin = part%qinf
      part => part%next
      end do


      !Compute total number of particles
      call mpi_allreduce(numpart,tnumpart,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)


      call mpi_allreduce(denum,tdenum,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)

      call mpi_allreduce(actnum,tactnum,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)

      call mpi_allreduce(myact_tmp,act_tmp,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)

      tmpbuf(1) = myRep_avg
      tmpbuf(2) = mylwc_sum
      tmpbuf(3) = myphiw_sum
      tmpbuf(4) = myphiv_sum
      tmpbuf(5) = myradavg
      tmpbuf(6) = myradmsqr


      !calculate average particle residence time
      call mpi_allreduce(avgres,tavgres,1,mpi_real8,mpi_sum,mpi_comm_world,ierr)

      !Combine all reals that are being summed:
      call mpi_allreduce(tmpbuf,tmpbuf_rec,6,mpi_real8,mpi_sum,mpi_comm_world,ierr)

      call mpi_allreduce(num_destroy,tnum_destroy,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)

      call mpi_allreduce(num100,tnum100,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)
      call mpi_allreduce(num1000,tnum1000,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)
      call mpi_allreduce(numimpos,tnumimpos,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)

      Rep_avg = tmpbuf_rec(1)
      lwc = tmpbuf(2)
      phiw = tmpbuf_rec(3)
      phiv = tmpbuf_rec(4)
      radavg = tmpbuf_rec(5)
      radmsqr = tmpbuf_rec(6)

      phiw = phiw/xl/yl/zl/rhoa
      phiv = phiv/xl/yl/zl
      Rep_avg = Rep_avg/tnumpart
      radavg = radavg/act_tmp
      radmsqr = radmsqr/act_tmp
      tavgres = tavgres/tnum_destroy

      !Min and max radius
      call mpi_allreduce(myradmin,radmin,1,mpi_real8,mpi_min,mpi_comm_world,ierr)
      call mpi_allreduce(myradmax,radmax,1,mpi_real8,mpi_max,mpi_comm_world,ierr)

      call mpi_allreduce(mytempmin,tempmin,1,mpi_real8,mpi_min,mpi_comm_world,ierr)
      call mpi_allreduce(mytempmax,tempmax,1,mpi_real8,mpi_max,mpi_comm_world,ierr)

      call mpi_allreduce(myqmin,qmin,1,mpi_real8,mpi_min,mpi_comm_world,ierr)
      call mpi_allreduce(myqmax,qmax,1,mpi_real8,mpi_min,mpi_comm_world,ierr)



  end subroutine particle_update_BE

  subroutine destroy_particle
      implicit none

      type(particle), pointer :: tmp

      !Is it the first and last in the list?
      if (associated(part,first_particle) .AND. (.NOT. associated(part%next)) ) then
          nullify(first_particle)
          deallocate(part)
      else
        if (associated(part,first_particle)) then !Is it the first particle?
           first_particle => part%next
           part => first_particle
           deallocate(part%prev)
        elseif (.NOT. associated(part%next)) then !Is it the last particle?
           nullify(part%prev%next)
           deallocate(part)
        else
           tmp => part
           part => part%next
           tmp%prev%next => tmp%next
           tmp%next%prev => tmp%prev
           deallocate(tmp)
        end if
      end if
   
  end subroutine destroy_particle

  subroutine particle_stats
      use pars
      use con_stats
      use con_data
      implicit none
      integer :: i,ipt,jpt,kpt
      real :: rhop,pi

      part => first_particle
      do while (associated(part))     

      ipt = floor(part%xp(1)/dx) + 1
      jpt = floor(part%xp(2)/dy) + 1
      kpt = minloc(z,1,mask=(z.gt.part%xp(3))) - 1

      pi   = 4.0*atan(1.0)

      rhop = (part%m_s+4.0/3.0*pi*part%radius**3*rhow)/(4.0/3.0*pi*part%radius**3)

      !Takes in ipt,jpt,kpt as the node to the "bottom left" of the particle
      !(i.e. the node in the negative direction for x,y,z)
      !and computes quantities needed to get particle statistics

      partcount_t(kpt,jpt,ipt) = partcount_t(kpt,jpt,ipt) + 1.0
      
      !Get su mean, mean-squared of particle velocities at each level
      upwp_t(kpt,jpt,ipt) = upwp_t(kpt,jpt,ipt) + part%vp(1)*part%vp(3)
      do i = 1,3
      vpsum_t(kpt,jpt,ipt,i) = vpsum_t(kpt,jpt,ipt,i) + part%vp(i)
      vpsqrsum_t(kpt,jpt,ipt,i)=vpsqrsum_t(kpt,jpt,ipt,i)+part%vp(i)**2
      end do

      Tpsum_t(kpt,jpt,ipt) = Tpsum_t(kpt,jpt,ipt) + part%Tp
      Tpsqrsum_t(kpt,jpt,ipt) = Tpsqrsum_t(kpt,jpt,ipt) + part%Tp**2

      Tfsum_t(kpt,jpt,ipt) = Tfsum_t(kpt,jpt,ipt) + part%Tf

      qfsum_t(kpt,jpt,ipt) = qfsum_t(kpt,jpt,ipt) + part%qinf

      wpTpsum_t(kpt,jpt,ipt) = wpTpsum_t(kpt,jpt,ipt) + part%Tp*part%vp(3)


      radsum_t(kpt,jpt,ipt) = radsum_t(kpt,jpt,ipt) + part%radius 

      rad2sum_t(kpt,jpt,ipt) = rad2sum_t(kpt,jpt,ipt) + part%radius**2  

      multcount_t(kpt,jpt,ipt) = multcount_t(kpt,jpt,ipt) + real(part%mult)

      mwsum_t(kpt,jpt,ipt) = mwsum_t(kpt,jpt,ipt) + real(part%mult)*(rhow*4.0/3.0*pi*part%radius**3)

      qstarsum_t(kpt,jpt,ipt) = qstarsum_t(kpt,jpt,ipt) + part%qstar

      part => part%next
      end do

  end subroutine particle_stats

  subroutine particle_coalesce
      use pars
      use kd_tree
      use pars
      use con_data
      implicit none 

      type(particle), pointer :: part_tmp
      type(tree_master_record), pointer :: tree

      real, allocatable :: xp_data(:,:),distances(:),rad_data(:)
      real, allocatable :: vel_data(:,:)
      integer, allocatable :: index_data(:,:),indexes(:)
      integer*8, allocatable :: mult_data(:)
      integer, allocatable :: destroy_data(:)
      integer, allocatable :: coal_data(:),ran_nq(:)

      integer :: i,nq,coal_idx,j,ran_idx,tmp_int,gm,gam_til
      integer :: ns,k_idx,j_idx
      integer*8 :: mult_tmp_j,mult_tmp_k,xi_j,xi_k
      real :: qv(3),dist_tmp,xdist,ydist,zdist,ran2
      real :: phi,K,Pjk,veldiff,E,dV,p_alpha,pvol_j,pvol_k,golovin_b
      real :: rad_j_tmp,rad_k_tmp

      !For whatever reason, the kd-search sometimes misses edge cases,
      !and you should do nq+1 if you actually want nq
      nq = 11

      allocate(xp_data(numpart,3),index_data(numpart,2))
      allocate(vel_data(numpart,3))
      allocate(distances(nq),indexes(nq),ran_nq(2:nq-1))
      allocate(rad_data(numpart),mult_data(numpart),coal_data(numpart))
      allocate(destroy_data(numpart))

      !Loop over particles and fill arrays
      i = 1
      part_tmp => first_particle
      do while (associated(part_tmp))

         xp_data(i,1:3) = part_tmp%xp(1:3) 
         index_data(i,1) = part_tmp%pidx
         index_data(i,2) = part_tmp%procidx

         rad_data(i) = part_tmp%radius
         mult_data(i) = part_tmp%mult
         coal_data(i) = 0

         vel_data(i,1:3) = part_tmp%vp(1:3)

      i = i+1   
      part_tmp => part_tmp%next
      end do

      !Build the kd-tree
      tree => create_tree(xp_data) 

      !Do the search for each of the particles
      part_tmp => first_particle
      do i=1,numpart

         qv(1:3) = xp_data(i,1:3)
         call n_nearest_to(tree,qv,nq,indexes,distances)
         !call n_nearest_to_brute_force(tree,qv,nq,indexes,distances)
 
         !Go back through and assign the shortest distance and index
         !NOTE: Must use 2nd one since it finds itself as nearest neighbor
         !Keep this turned on despite "ineighbor" flag -- consider it a bonus
         part_tmp%dist = sqrt(distances(2))
         part_tmp%nbr_pidx = index_data(indexes(2),1)
         part_tmp%nbr_procidx = index_data(indexes(2),2)

         !Okay, now the particle knows who the nearest nq particles are
         !--> pick one at random and apply coalescence rules
         !Loop over all nq until you find one that hasn't coalesced
         !Don't coalesce if all nq nearby have already done so

         !Set up an array 2,3,...,nq-1
         do j=2,nq-1
            ran_nq(j) = j
         end do

         !Get a random permutation of this array
         do j=2,nq-1
            ran_idx = floor(ran2(iseed)*(nq-3)) + 2 !Get a number between 2 and nq-1
            tmp_int = ran_nq(j) 
            ran_nq(j) = ran_nq(ran_idx)
            ran_nq(ran_idx) = tmp_int
         end do

         !Now loop through these coalescence candidates and take first one that hasn't already coalesced
         coal_idx = -1
         if (coal_data(i) .eq. 0) then
         do j=2,nq-1

             if (.not. coal_data(indexes(ran_nq(j)))) then        !Found one that has not already coalesced
                coal_idx = indexes(ran_nq(j))              !The index of the coalescence candidate in the arrays
                goto 101
             end if
         
         end do
         end if !coal_data = 0
   
101   continue


      !Now apply the coalescence rules to the pair (i,coal_idx) assuming a coal_idx was found (.ne. -1)
      if (coal_idx .ge. 1) then

         phi = ran2(iseed) 
         dV = 2*pi2/3.0*(sqrt(distances(nq-1)))**3  !The volume will be the sphere formed by outermost droplet considered
         E = 1.0  !Collision efficiency -- obviously this needs to be updated from 1.0
         
         veldiff = sqrt( (vel_data(i,1)-vel_data(coal_idx,1))**2 +  &
                         (vel_data(i,2)-vel_data(coal_idx,2))**2 +  &
                         (vel_data(i,3)-vel_data(coal_idx,3))**2 )

         if (mult_data(i) .ge. mult_data(coal_idx)) then
            xi_j = mult_data(i)
            xi_k = mult_data(coal_idx)
            j_idx = i
            k_idx = coal_idx
         else
            xi_j = mult_data(coal_idx)
            xi_k = mult_data(i)
            j_idx = coal_idx
            k_idx = i
         end if

         !Choose the kernel:
         K = pi2/2.0*E*veldiff*(rad_data(i) + rad_data(coal_idx))**2

         !Golovin (1963) kernel:
         !pvol_j = pi2*2.0/3.0*rad_data(j_idx)**3.0
         !pvol_k = pi2*2.0/3.0*rad_data(k_idx)**3.0
         !golovin_b = 1.5e3
         !K = golovin_b*(pvol_j + pvol_k)

         Pjk = K*dt/dV*xi_j

         !TESTING: cheat here and hard-code a different dt and dV than the flow
         !since there are issues
         !Pjk = K*1.0/1.0e6*xi_j
         !ns = tnumpart

         !ns = nq-1   !This would be the number of particles in the "cell" according to Shima et al. 2009
         p_alpha = Pjk*(real(ns)*(real(ns)-1.0)/2.0)/(real(ns)/2.0)

         !if (p_alpha .gt. 1) write(*,*) 'WARNING: p_alpha > 1'

         if (phi .lt. p_alpha-floor(p_alpha)) then
            gm = floor(p_alpha) + 1
         else
            gm = floor(p_alpha)
         end if


         if (gm .gt. 0) then  !Only update radii and multiplicities if the coin flip indicates
       
            gam_til = min(gm,floor(real(xi_j)/real(xi_k)))


            if (xi_j - gam_til*xi_k .gt. 0) then

            !Update particle j's multiplicity
            mult_data(j_idx) = mult_data(j_idx)-gam_til*mult_data(k_idx)
               
            !Update particle k's radius
            rad_data(k_idx) = (gam_til*rad_data(j_idx)**3 + rad_data(k_idx)**3)**(1.0/3.0)


            elseif (xi_j - gam_til*xi_k .eq. 0) then

            mult_tmp_j = floor(real(mult_data(k_idx))/2.0)
            mult_tmp_k = mult_data(k_idx) - floor(real(mult_data(k_idx))/2.0)
       
            mult_data(j_idx) = mult_tmp_j
            mult_data(k_idx) = mult_tmp_k

            rad_j_tmp = (gam_til*rad_data(j_idx)**3 + rad_data(k_idx)**3)**(1.0/3.0)
            rad_k_tmp = (gam_til*rad_data(j_idx)**3 + rad_data(k_idx)**3)**(1.0/3.0)

            rad_data(j_idx) = rad_j_tmp
            rad_data(k_idx) = rad_k_tmp

            end if


          end if !gm .gt. 0

       !Now exclude both of these from checking again
       coal_data(coal_idx) = 1
       coal_data(i) = 1
      end if  !coal_idx .gt. 1
         
         

      part_tmp => part_tmp%next
      end do

      !Now finally update the particle linked list
      i = 1
      part_tmp => first_particle
      do while (associated(part_tmp))

         !Only things which should change are radius and multiplicity
         part_tmp%radius = rad_data(i)
         part_tmp%mult = mult_data(i)

      i = i+1   
      part_tmp => part_tmp%next
      end do

      !Finally remove dead particles from coalescence
      i = 1
      numpart = 0
      part => first_particle
      do while (associated(part))
         if (mult_data(i) .eq. 0) then
            call destroy_particle
         else
            numpart = numpart + 1
            part => part%next
         end if

      i = i+1
      end do



      call destroy_tree(tree)
      deallocate(xp_data,index_data)
      deallocate(vel_data,distances,indexes,ran_nq)
      deallocate(rad_data,mult_data,coal_data,destroy_data)


  end subroutine particle_coalesce

  subroutine gauss_newton_2d(vnext,h,vec1,vec2,flag)
        implicit none

        real, intent(in) :: vnext(3), h, vec1(2)
        real, intent(out) :: vec2(2)
        integer, intent(out) :: flag
        real :: error = 1E-8, fv1(2), fv2(2), v1(2), v_output(3), rel
        real :: diff, temp1(2), temp2(2), relax, coeff, correct(2)
        real, dimension(1:2, 1:2) :: J, fancy, inv, finalJ
        integer :: iterations, neg, counts

        iterations = 0
        flag = 0

        v1 = vec1
        fv2 = (/1., 1./)
        coeff = 0.1
        do while ((sqrt(dot_product(fv2, fv2)) > error) .AND. (iterations<1000))


                iterations = iterations + 1

                call ie_vrt_nd(vnext, v1(1), v1(2), v_output, fv1, h)
                call jacob_approx_2d(vnext, v1(1), v1(2), h, J)

                fancy = matmul(transpose(J), J)

                call inverse_finder_2d(fancy, inv)

                finalJ = matmul(inv, transpose(J))

                correct = matmul(finalJ,fv1)
                vec2 = v1 - correct

                call ie_vrt_nd(vnext, v1(1), v1(2),v_output,temp1,h)
                call ie_vrt_nd(vnext, vec2(1), vec2(2),v_output,temp2,h)

                diff = sqrt(dot_product(temp1,temp1))-sqrt(dot_product(temp2,temp2))

                if (sqrt(dot_product(correct,correct))<1E-8) then
                        EXIT
                end if

                relax = 1.0
                counts = 0

               do while ((diff<0).OR.(vec2(1)<0) .OR. (vec2(2)<0) .OR. isnan(vec2(1)))
                        counts = counts + 1
                        coeff = 0.5
                        relax = relax * coeff
                        vec2 = v1-matmul(finalJ,fv1)*relax
                call ie_vrt_nd(vnext, vec2(1), vec2(2),v_output,temp2,h)
                        diff = sqrt(dot_product(temp1,temp1))-sqrt(dot_product(temp2,temp2))

                        if (counts>10) EXIT
                end do

                v1 = vec2

                call ie_vrt_nd(vnext, vec2(1), vec2(2), v_output, fv2,h)
        end do
      if (iterations == 100) flag = 1
      if (isnan(vec2(1)) .OR. vec2(1)<0 .OR. isnan(vec2(2)) .OR. vec2(2)<0) flag = 1

  end subroutine gauss_newton_2d
  subroutine LV_solver(vnext,h,vec1,vec2,flag)
        implicit none

        real, intent(in) :: vnext(3),h, vec1(2)
        real, intent(out) :: vec2(2)
        integer, intent(out) :: flag
        real :: error = 1E-8, fv1(2), fv2(2), v1(2), v_output(3), rel
        real :: diff, lambda,lup,ldown
        real :: C(2), newC(2), gradC(2), correct(2)
        real, dimension(1:2, 1:2) :: J,I,g,invg
        integer :: iterations, neg

        I = reshape((/1, 0, 0, 1/),shape(I))
        iterations = 0
        flag = 0
        v1 = vec1
        fv2 = (/1., 1./)

        lambda = 0.001
        lup = 2.0
        ldown = 2.0

        do while ((sqrt(dot_product(fv2, fv2)) > error) .AND. (iterations<1000))

        iterations = iterations + 1
        call jacob_approx_2d(vnext, v1(1), v1(2), h,J)

        call ie_vrt_nd(vnext, v1(1), v1(2),v_output,fv1,h)
        g = matmul(transpose(J),J)+lambda*I
        gradC = matmul(transpose(J),fv1)
        C = 0.5*fv1*fv1

        call inverse_finder_2d(g, invg)
        correct = matmul(invg, gradC)
        if (sqrt(dot_product(correct,correct)) < 1E-12) then
                EXIT
        end if

        vec2 = v1 - correct
        call ie_vrt_nd(vnext, vec2(1), vec2(2),v_output,fv2,h)
        newC = 0.5*fv2*fv2

        if (sqrt(dot_product(newC,newC))<sqrt(dot_product(C,C))) then
                v1 = vec2
                lambda = lambda/ldown
        else
                lambda = lambda*lup
        end if

        end do

        if (iterations==1000) then
                flag = 1
        end if

        if (vec2(1) < 0 .OR. vec2(2) < 0) then
                flag = 1
        end if


  end subroutine LV_solver
  subroutine jacob_approx_2d(vnext, rnext, tnext, h, J)
        implicit none
        integer :: n

        real, intent(in) :: vnext(3), rnext, tnext, h
        real, intent(out), dimension(1:2, 1:2) :: J
        real :: diff = 0, v_output(3), rt_output(2),xper(2),fxper(2), ynext(2),xper2(2),fxper2(2)

        diff = 1E-12

        ynext(1) = rnext
        ynext(2) = tnext

        call ie_vrt_nd(vnext, rnext, tnext, v_output, rt_output, h)

        xper = ynext
        xper2 = ynext

        do n=1, 2
                xper(n) = xper(n) + diff
                xper2(n) = xper2(n) - diff
                call ie_vrt_nd(vnext, xper(1), xper(2),v_output,fxper,h)
                call ie_vrt_nd(vnext, xper2(1), xper2(2),v_output,fxper2,h)
                J(:, n) = (fxper-rt_output)/diff
                xper(n) = ynext(n)
                xper2(n) = ynext(n)
        end do

  end subroutine jacob_approx_2d
  subroutine inverse_finder_2d(C, invC)
        implicit none
        real :: det
        real, dimension(1:2, 1:2), intent(in) :: C
        real, dimension(1:2, 1:2), intent(out) :: invC

        det = C(1, 1) * C(2, 2) - C(1, 2) * C(2, 1)

        invC = reshape((/C(2, 2), -C(2,1), -C(1, 2), C(1, 1)/),shape(invC))
        invC = (1./det)*invC

  end subroutine inverse_finder_2d
  subroutine ie_vrt_nd(vnext, tempr, tempt, v_output,rt_output, h)
      use pars
      use con_data
      use con_stats
      implicit none
      include 'mpif.h'

      real, intent(in) :: vnext(3), tempr, tempt, h
      real, intent(out) :: v_output(3), rT_output(2)

      real :: esa, dnext,  m_w, rhop, Rep, taup,vprime(3), rprime, Tprime, qstr, Shp, Nup, dp, VolP
      real :: diff(3), diffnorm, Tnext, rnext, T
      real :: taup0, g(3)


        taup0 = (((part%m_s)/((2./3.)*pi2*radius_init**3) + rhow)*(radius_init*2)**2)/(18*rhoa*nuf)
        g(1:3) = part_grav(1:3)

        ! quantities come in already non-dimensionalized, so must be
        ! converted back;
        ! velocity is not non-dimensionalized so no need to change
        rnext = tempr * part%radius
        Tnext = tempt * part%Tp
        dnext = rnext * 2.

        esa = mod_Magnus(part%Tf)
        VolP = (2./3.)*pi2*rnext**3
        rhop = (part%m_s + VolP*rhow) / VolP

        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

        !!! Velocity !!!
        diff(1:3) = part%uf - vnext
        diffnorm = sqrt(diff(1)**2 + diff(2)**2 + diff(3)**2)
        Rep = dnext * diffnorm/nuf
        taup = (rhop * dnext**2)/(18.0*rhoa*nuf)
        vprime(1:3) = (1. + 0.15 * (Rep**0.687)) * (1./taup)*diff(1:3) - g(1:3)
        vprime(1:3) = vprime(1:3) * taup0 ** 2
        !!!!!!!!!!!!!!!!

        !!! Humidity !!!
        qstr = (Mw/(Ru*Tnext*rhoa)) * esa * exp(((Lv*Mw/Ru)*((1./part%Tf) - (1./Tnext))) + ((2.*Mw*Gam)/(Ru*rhow*rnext*Tnext)) - ((Ion*part%Os*part%m_s*(Mw/Ms))/(Volp*rhop-part%m_s)))
        !!!!!!!!!!!!!!!!!!

        !!! Radius !!!
        Shp = 2. + 0.6 * Rep**(1./2.) * Sc**(1./3.)
        rprime = (1./9.) * (Shp/Sc) * (rhop/rhow) * (rnext/taup) * (part%qinf - qstr)
        rprime = rprime * (taup0/part%radius)
        !!!!!!!!!!!!!!!!!

        !!! Temperature !!!
        Nup = 2. + 0.6*Rep**(1./2.)*Pra**(1./3.);

        Tprime = -(1./3.)*(Nup/Pra)*CpaCpp*(rhop/rhow)*(1./taup)*(Tnext-part%Tf) + 3.*Lv*(1./(rnext*Cpp))*rprime*(part%radius/taup0)
        Tprime = Tprime * (taup0/part%Tp)
        !!!!!!!!!!!!!!!!!

        ! velocity is not non-dimensionalized so it does not need to be
        ! changed back
        v_output(1:3) = vnext(1:3) - part%vp(1:3) - h * vprime(1:3)
        rT_output(1) = rnext/part%radius - 1.0  - h*rprime
        rT_output(2) = Tnext/part%Tp - 1.0  - h*Tprime

  end subroutine ie_vrt_nd
  subroutine rad_solver2(guess,mflag)
      use pars
      use con_data
      use con_stats
      implicit none
      include 'mpif.h'

      real, intent(OUT) :: guess
      integer, intent(OUT) :: mflag
      real :: a, c, esa, Q, R, M, val, theta, S, T

      mflag = 0
      esa = mod_Magnus(part%Tf)

      a = -(2*Mw*Gam)/(Ru*rhow*part%Tf)/LOG((Ru*part%Tf*rhoa*part%qinf)/(Mw*esa))
      c = (Ion*part%Os*part%m_s*(Mw/Ms))/((2.0/3.0)*pi2*rhow)/LOG((Ru*part%Tf*rhoa*part%qinf)/(Mw*esa))

      Q = (a**2.0)/9.0
      R = (2.0*a**3.0+27.0*c)/54.0
      M = R**2.0-Q**3.0
      val = (R**2.0)/(Q**3.0)

      if (M<0) then
        theta = acos(R/sqrt(Q**3.0))
        guess = -(2*sqrt(Q)*cos((theta-pi2)/3.0))-a/3.0

        if (guess < 0) then
        guess = -(2*sqrt(Q)*cos((theta+pi2)/3.0))-a/3.0
        end if

      else
        S = -(R/abs(R))*(abs(R)+sqrt(M))**(1.0/3.0)
        T = Q/S
        guess = S + T - a/3.0

        if (guess < 0) then
                guess = part%radius
                mflag = 1
        end if
      end if

  end subroutine rad_solver2

  function mod_Magnus(T)
    implicit none

    !Take in T in Kelvin and return saturation vapor pressure using function of Alduchov and Eskridge, 1996
    real,intent(in) :: T
    real :: mod_Magnus

    mod_Magnus = 610.94 *exp((17.6257*(T-273.15))/(243.04+(T-273.15)))


  end function mod_Magnus

  function crit_radius(m_s,Os,Tf)
    use pars
    use con_data
    implicit none

    integer :: i,maxidx(1)
    integer, parameter :: N=1000
    real :: m_s,Os,Tf
    real :: radval(N),SS(N)
    real :: radstart,radend,dr
    real :: crit_radius
    real :: firstterm,secterm

    radstart = -8
    radend = -3
    dr = (radstart-radend)/N

    do i=1,N

      radval(i) = 10**(radstart - (i-1)*dr)

      firstterm = 2*Mw*Gam/Ru/rhow/radval(i)/Tf
      secterm =Ion*Os*m_s*(Mw/Ms)/(rhow*pi2*2.0/3.0*radval(i)**3)

      SS(i) = exp( 2*Mw*Gam/Ru/rhow/radval(i)/Tf - Ion*Os*m_s*(Mw/Ms)/(rhow*pi2*2.0/3.0*radval(i)**3))

    end do

    maxidx = maxloc(SS)

    crit_radius = radval(maxidx(1))


  end function crit_radius


end module particles