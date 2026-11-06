"""Exercise the production yaw reader with MPI and a deterministic Redis stub."""

import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ActuatorPollingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "src" / "adm.f90").read_text()
        binding = source[source.index("    type, bind(C), private :: poll_timespec"):
                         source.index("type ActuatorDiscType")]
        routine = re.search(
            r"    subroutine actuator_disc_model_read_input\(.*?"
            r"    end subroutine actuator_disc_model_read_input",
            source, re.DOTALL,
        ).group(0)
        driver = """
module var
end module
module param
  real, parameter :: dx=1., dy=1., dz=1.
end module
module decomp_2d
end module
module decomp_2d_io
end module
module polling_test
  use mpi
  use iso_c_binding
  implicit none
  integer, parameter :: mytype=kind(1.), real_type=MPI_REAL
  real(mytype), parameter :: conrad=acos(-1.)/180.
  integer :: nrank, Nad, flag_reads=0, yaw_reads=0, gamma_calls=0
  real(c_double) :: first_poll=0., last_poll=0.
  character(len=12) :: name_prefix='1'
  character(len=32) :: scenario
  type :: disc_type
    real(mytype) :: YawAng=0., TiltAng=0., RotN(3)=0.
  end type
  type(disc_type), allocatable :: ActuatorDisc(:)
  type :: stub_client
  contains
    procedure :: unpack_tensor
  end type
  type(stub_client) :: client
""" + binding + """
contains
  integer function unpack_tensor(self, key, values, dims) result(status)
    class(stub_client), intent(inout) :: self
    character(len=*), intent(in) :: key
    real(c_double), intent(out) :: values(:)
    integer, intent(in) :: dims(:)
    status=0
    if (nrank/=0) then
      status=99
      return
    endif
    if (index(key, '_yaws_done')>0) then
      flag_reads=flag_reads+1
      if (flag_reads==1) first_poll=MPI_WTIME()
      last_poll=MPI_WTIME()
      if (scenario=='flag_error') then
        status=7
        return
      endif
      values=1._c_double
      if (scenario=='delayed'.and.last_poll-first_poll<0.03_c_double) values=0._c_double
    else
      yaw_reads=yaw_reads+1
      if (scenario=='yaw_error') then
        status=8
        return
      endif
      values=[12.125_c_double, -27.625_c_double]+real(yaw_reads-1,c_double)
    endif
  end function unpack_tensor

  subroutine actuator_disc_model_compute_gamma(count, coords)
    integer, optional, intent(in) :: count
    character(len=*), optional, intent(in) :: coords
    integer :: total, status
    call MPI_ALLREDUCE(1, total, 1, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, status)
    gamma_calls=gamma_calls+1
  end subroutine actuator_disc_model_compute_gamma
""" + routine.replace("      use var, only: GammaDisc", "      use var") + """
end module polling_test

program check_polling
  use polling_test
  implicit none
  integer :: status, count, ranks, iteration
  real(c_double) :: expected(2)
  character(len=100) :: coords='unused'
  call MPI_INIT(status)
  call MPI_COMM_RANK(MPI_COMM_WORLD, nrank, status)
  call MPI_COMM_SIZE(MPI_COMM_WORLD, ranks, status)
  call get_command_argument(1, scenario)
  count=2
  if (scenario=='zero_discs') count=0
  allocate(ActuatorDisc(count))
  do iteration=1,2
    call actuator_disc_model_read_input(count, coords)
    if (count>0) then
      expected=[12.125_c_double, -27.625_c_double]+real(iteration-1,c_double)
      if (any(abs(real(ActuatorDisc%YawAng,c_double)-expected)>1.e-6_c_double)) &
        call MPI_ABORT(MPI_COMM_WORLD, 31, status)
      if (any(abs(ActuatorDisc%RotN(1)-cos(ActuatorDisc%YawAng*conrad))>1.e-6)) &
        call MPI_ABORT(MPI_COMM_WORLD, 32, status)
    endif
  enddo
  if (gamma_calls/=merge(2,0,count>0)) call MPI_ABORT(MPI_COMM_WORLD, 33, status)
  if (nrank/=0.and.(flag_reads/=0.or.yaw_reads/=0)) call MPI_ABORT(MPI_COMM_WORLD, 34, status)
  if (nrank==0) then
    if (yaw_reads/=merge(2,0,count>0)) call MPI_ABORT(MPI_COMM_WORLD, 35, status)
    if (scenario=='delayed') then
      if (flag_reads<3.or.flag_reads>100) call MPI_ABORT(MPI_COMM_WORLD, 36, status)
      if (last_poll-first_poll<0.03_c_double) call MPI_ABORT(MPI_COMM_WORLD, 37, status)
    endif
    write(*,*) 'PASS', ranks, flag_reads, yaw_reads, gamma_calls
  endif
  call MPI_FINALIZE(status)
end program check_polling
"""
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        path = Path(cls.directory.name)
        cls.binary = path / "check_polling"
        (path / "check_polling.f90").write_text(driver)
        compiler = shlex.split(os.environ.get("WINDRL_MPI_TEST_COMPILER", "ftn"))
        subprocess.run(
            [*compiler, "-O0", "-fcheck=all", "-ffree-line-length-none",
             str(path / "check_polling.f90"), "-o", str(cls.binary)],
            cwd=path, check=True, capture_output=True, text=True,
        )

    def run_case(self, scenario, ranks):
        runner = shlex.split(os.environ.get("WINDRL_MPI_TEST_RUNNER", "srun"))
        result = subprocess.run(
            [*runner, "-n", str(ranks), str(self.binary), scenario],
            capture_output=True, text=True, timeout=30,
        )
        output = result.stdout + result.stderr
        if scenario.endswith("error"):
            self.assertNotEqual(result.returncode, 0, output)
            expected = "yaw-ready read failed" if scenario == "flag_error" else "yaw read failed"
            self.assertIn(expected, output)
        else:
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("PASS", output)

    def test_immediate_ready(self):
        for ranks in (1, 4):
            with self.subTest(ranks=ranks):
                self.run_case("ready", ranks)

    def test_delayed_ready(self):
        for ranks in (1, 4):
            with self.subTest(ranks=ranks):
                self.run_case("delayed", ranks)

    def test_zero_discs(self):
        self.run_case("zero_discs", 4)

    def test_flag_read_failure(self):
        self.run_case("flag_error", 4)

    def test_yaw_read_failure(self):
        self.run_case("yaw_error", 4)


if __name__ == "__main__":
    unittest.main()