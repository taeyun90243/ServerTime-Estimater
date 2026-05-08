import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from measurement import (
    cristian_offset_ms,
    median,
    stddev_sample,
    ci95_ms,
    select_edge_offsets,
    reduce_samples,
    adaptive_count,
)


def _sample(rtt_ms, server_date_ms, pc_at_t2_ms):
    raw_offset = (server_date_ms + rtt_ms / 2.0) - pc_at_t2_ms
    return {
        "rtt_ms": rtt_ms,
        "server_date_ms": server_date_ms,
        "pc_at_t2_ms": pc_at_t2_ms,
        "raw_offset_ms": raw_offset,
    }


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


class EdgeDetectionTest(unittest.TestCase):
    def test_edge_detected_when_date_increments(self):
        samples = [
            _sample(rtt_ms=50, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_980),
            _sample(rtt_ms=50, server_date_ms=1_000_001_000, pc_at_t2_ms=1_000_000_500),
        ]
        edges = select_edge_offsets(samples)
        self.assertEqual(len(edges), 1)

    def test_no_edge_when_date_repeats(self):
        samples = [
            _sample(rtt_ms=50, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_980),
            _sample(rtt_ms=50, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_990),
        ]
        self.assertEqual(select_edge_offsets(samples), [])

    def test_reduce_uses_edge_method_when_edges_present(self):
        samples = [
            _sample(rtt_ms=50, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_980),
            _sample(rtt_ms=50, server_date_ms=1_000_001_000, pc_at_t2_ms=1_000_000_500),
            _sample(rtt_ms=50, server_date_ms=1_000_002_000, pc_at_t2_ms=1_000_001_500),
        ]
        result = reduce_samples(samples)
        self.assertEqual(result["method"], "edge")
        self.assertGreaterEqual(result["accepted_count"], 1)

    def test_reduce_falls_back_when_no_edges(self):
        samples = [
            _sample(rtt_ms=50 + i, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_980 + i)
            for i in range(10)
        ]
        result = reduce_samples(samples)
        self.assertEqual(result["method"], "upper-envelope")


class AdaptiveCountTest(unittest.TestCase):
    def test_low_rtt_clamps_to_max(self):
        self.assertEqual(adaptive_count(rtt_median_ms=50, interval_ms=50), 60)

    def test_mid_rtt(self):
        self.assertEqual(adaptive_count(rtt_median_ms=150, interval_ms=50), 30)

    def test_high_rtt_uses_estimated(self):
        self.assertEqual(adaptive_count(rtt_median_ms=300, interval_ms=50), 18)

    def test_huge_rtt_clamps_to_min(self):
        self.assertEqual(adaptive_count(rtt_median_ms=10_000, interval_ms=50), 10)


if __name__ == "__main__":
    unittest.main()
