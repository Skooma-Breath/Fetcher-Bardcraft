import base64
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from build_patch import file_map, load_previous_outputs, make_operations


class PreviousOutputTests(unittest.TestCase):
    def test_preserves_transitive_patch_ancestry(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "previous.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "files": [
                            {
                                "path": "conductor.lua",
                                "outputSha256": "CURRENT",
                                "priorOutputSha256": ["PREVIOUS", "OLDEST"],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            outputs = load_previous_outputs([manifest_path])

        self.assertEqual(outputs["conductor.lua"], {"current", "previous", "oldest"})


class DeltaOperationTests(unittest.TestCase):
    def test_binary_extra_file_round_trip(self) -> None:
        source = bytes(range(256)) * 3 + b"\x00upstream\r\nrecord\xff"
        output = source[:173] + b"\x00patched-dialogue\xff\r\n" + source[411:] + b"\x10\x00end"

        rebuilt = bytearray()
        for operation in make_operations(source, output):
            if "copyOffset" in operation:
                offset = int(operation["copyOffset"])
                length = int(operation["copyLength"])
                rebuilt.extend(source[offset : offset + length])
            else:
                rebuilt.extend(base64.b64decode(str(operation["data"])))

        self.assertEqual(bytes(rebuilt), output)


class SourceDiscoveryTests(unittest.TestCase):
    def test_ignores_transient_patch_backups(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "player.lua").write_text("current", encoding="utf-8")
            (root / "player.lua.before-test.bak").write_text("backup", encoding="utf-8")
            backup_dir = root / ".fetcher-bardcraft-backups" / "2.0.19"
            backup_dir.mkdir(parents=True)
            (backup_dir / "player.lua").write_text("released", encoding="utf-8")

            discovered = file_map(root)

        self.assertEqual(set(discovered), {"player.lua"})


if __name__ == "__main__":
    unittest.main()
