"""Compile the production seed expression and RNG without MPI/SmartRedis."""

import itertools
import math
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ForcingSeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "src" / "adm.f90").read_text()
        expression = re.search(
            r"ActuatorDisc\(idisc\)%RngState=(.*)", source
        ).group(1)
        routines = source[source.index("    function gauss_random(state)"):
                          source.index("end module actuator_disc_model")]
        driver = f"""
module forcing_rng
  implicit none
  integer, parameter :: mytype=kind(1.d0)
  real(mytype), parameter :: pi=acos(-1.d0)
contains
  function seed(instance,idisc,itime,nrank) result(state)
    integer, intent(in) :: instance,idisc,itime,nrank
    integer(8) :: state
    state={expression}
  end function
{routines}
end module

program check_seed
  use forcing_rng
  implicit none
  integer :: instance,idisc,itime,nrank,j
  integer(8) :: state
  do itime=1,10001,10000
    do idisc=1,3
      do instance=0,32
        do nrank=0,1
          write(*,*) seed(instance,idisc,itime,nrank)
        enddo
      enddo
    enddo
  enddo
  do instance=1,32
    state=seed(instance,1,1,0)
    do j=1,4096
      write(*,*) gauss_random(state)
    enddo
  enddo
end program
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "check_seed.f90").write_text(driver)
            subprocess.run(
                ["gfortran", "-O2", "-fcheck=all", "-ffpe-trap=invalid,zero,overflow",
                 "-ffree-line-length-none", "check_seed.f90", "-o", "check_seed"],
                cwd=path, check=True, capture_output=True, text=True,
            )
            cls.output = subprocess.check_output([str(path / "check_seed")], text=True)
            repeated = subprocess.check_output([str(path / "check_seed")], text=True)
        cls.repeated = repeated
        lines = cls.output.splitlines()
        cls.seeds = [int(line) for line in lines[:396]]
        samples = [float(line) for line in lines[396:]]
        cls.series = [samples[i:i + 4096] for i in range(0, len(samples), 4096)]

    def test_rank_invariance_and_distinct_seeds(self):
        self.assertEqual(self.seeds[::2], self.seeds[1::2])
        self.assertEqual(len(set(self.seeds)), 198)
        self.assertEqual(self.seeds[0], 88172645463325252 + 1000003 + 1)

    def test_reproducibility(self):
        self.assertEqual(self.output, self.repeated)

    def test_distinct_low_correlation_gaussian_sequences(self):
        self.assertEqual(len(self.series), 32)
        self.assertEqual(len({tuple(s) for s in self.series}), 32)
        centred = []
        for series in self.series:
            self.assertEqual(len(series), 4096)
            self.assertTrue(all(math.isfinite(x) for x in series))
            mean = statistics.mean(series)
            self.assertLess(abs(mean), 0.1)
            self.assertTrue(0.9 < statistics.pstdev(series) < 1.1)
            centred.append([x - mean for x in series])
        for a, b in itertools.combinations(centred, 2):
            correlation = sum(x * y for x, y in zip(a, b)) / math.sqrt(
                sum(x * x for x in a) * sum(y * y for y in b)
            )
            self.assertLess(abs(correlation), 0.08)


if __name__ == "__main__":
    unittest.main()
