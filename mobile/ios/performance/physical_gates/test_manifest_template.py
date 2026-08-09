import unittest

from manifest_template import (
    T093_CASES,
    T094_PRIMARY_SCENARIOS,
    T094_SECONDARY_SCENARIOS,
    create_manifest_template,
)


class ManifestTemplateTest(unittest.TestCase):
    def test_contains_exact_t091_matrix_and_canonical_warmup_name(self) -> None:
        manifest = create_manifest_template()
        samples = manifest["t091"]["samples"]

        self.assertEqual(66, len(samples))
        first_airplane = next(
            sample
            for sample in samples
            if sample["device"] == "D1"
            and sample["condition"] == "airplane"
            and sample["run"] == 0
        )
        self.assertEqual(
            "T091-D1-airplane-r00-warmup",
            first_airplane["capture"]["attempts"][0]["artifact"]["role"],
        )

    def test_contains_exact_t093_and_t094_matrices(self) -> None:
        manifest = create_manifest_template()

        self.assertEqual(
            set(T093_CASES),
            {
                (case["adapter"], case["operation"], case["fixture"])
                for case in manifest["t093"]["cases"]
            },
        )
        self.assertEqual(
            set(T094_PRIMARY_SCENARIOS),
            {scenario["name"] for scenario in manifest["t094"]["primaryScenarios"]},
        )
        self.assertEqual(
            set(T094_SECONDARY_SCENARIOS),
            {scenario["name"] for scenario in manifest["t094"]["secondaryScenarios"]},
        )


if __name__ == "__main__":
    unittest.main()
