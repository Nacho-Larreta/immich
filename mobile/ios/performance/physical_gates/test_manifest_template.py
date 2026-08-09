from collections import Counter
import unittest

from manifest_template import (
    DEVICE_SLOTS,
    T093_CASES,
    T094_PRIMARY_SCENARIOS,
    create_manifest_template,
)


class ManifestTemplateTest(unittest.TestCase):
    def test_contains_exact_t091_matrix_and_canonical_warmup_name(self) -> None:
        manifest = create_manifest_template()
        samples = manifest["t091"]["samples"]

        self.assertEqual(33, len(samples))
        self.assertEqual(
            {
                ("D1", "online"): 11,
                ("D1", "airplane"): 11,
                ("D1", "blackHole"): 11,
            },
            Counter((sample["device"], sample["condition"]) for sample in samples),
        )
        self.assertEqual(
            {0},
            {sample["run"] for sample in samples if sample["warmup"]},
        )
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

    def test_contains_exact_single_device_contract(self) -> None:
        manifest = create_manifest_template()

        self.assertEqual(2, manifest["schemaVersion"])
        self.assertEqual(("D1",), DEVICE_SLOTS)
        self.assertEqual({"D1"}, set(manifest["devices"]))
        self.assertNotIn("limitingDevice", manifest)
        self.assertEqual("D1", manifest["t092"]["device"])
        self.assertEqual("D1", manifest["t093"]["device"])
        self.assertEqual("D1", manifest["t094"]["primaryDevice"])
        self.assertNotIn("secondaryDevice", manifest["t094"])
        self.assertNotIn("secondaryScenarios", manifest["t094"])

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

    def test_template_contains_exactly_93_artifact_records(self) -> None:
        manifest = create_manifest_template()

        def artifact_records(value):
            if type(value) is dict:
                if {"role", "format", "sha256", "byteCount"}.issubset(value):
                    yield value
                    return
                for child in value.values():
                    yield from artifact_records(child)
            elif type(value) is list:
                for child in value:
                    yield from artifact_records(child)

        self.assertEqual(93, len(list(artifact_records(manifest))))


if __name__ == "__main__":
    unittest.main()
