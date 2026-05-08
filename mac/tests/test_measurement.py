import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from measurement import cristian_offset_ms


class CristianOffsetTest(unittest.TestCase):
    def test_basic_formula(self):
        self.assertAlmostEqual(
            cristian_offset_ms(server_date_ms=1_000_000, rtt_ms=100, pc_at_t2_ms=999_950),
            100.0,
            places=6,
        )

    def test_negative_offset_when_pc_ahead(self):
        self.assertAlmostEqual(
            cristian_offset_ms(server_date_ms=1_000_000, rtt_ms=50, pc_at_t2_ms=1_000_100),
            -75.0,
            places=6,
        )


if __name__ == "__main__":
    unittest.main()
