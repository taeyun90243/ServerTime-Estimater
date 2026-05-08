import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from measurement import cristian_offset_ms, median, stddev_sample, ci95_ms


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


class StatsHelperTest(unittest.TestCase):
    def test_median_odd(self):
        self.assertEqual(median([3.0, 1.0, 2.0]), 2.0)

    def test_median_even(self):
        self.assertEqual(median([1.0, 2.0, 3.0, 4.0]), 2.5)

    def test_median_empty_raises(self):
        with self.assertRaises(ValueError):
            median([])

    def test_stddev_sample_two_values(self):
        self.assertAlmostEqual(stddev_sample([1.0, 3.0]), 2.0 ** 0.5, places=6)

    def test_stddev_sample_single_value_returns_zero(self):
        self.assertEqual(stddev_sample([5.0]), 0.0)

    def test_ci95_ms_uses_t_table(self):
        vals = [1.0] * 10
        self.assertAlmostEqual(ci95_ms(vals), 0.0, places=6)


if __name__ == "__main__":
    unittest.main()
