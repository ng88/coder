import hashlib
import tempfile
import unittest
from pathlib import Path

import server

from agent import AgentError, AgentTools, Workspace, apply_unified_patch


class AgentToolTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.workspace = Workspace(self.root)
        self.tools = AgentTools(self.workspace, sandbox=False, network=False)

    def tearDown(self):
        self.temp.cleanup()

    async def test_write_stat_move_delete_round_trip(self):
        written = await self.tools.write_file(
            {"path": "nested/a.txt", "content": "hello\n", "create_parents": True}
        )
        expected_hash = hashlib.sha256(b"hello\n").hexdigest()
        self.assertEqual(written["sha256"], expected_hash)

        stat_result = await self.tools.stat_file({"path": "nested/a.txt"})
        self.assertEqual(stat_result["size"], 6)
        self.assertEqual(stat_result["sha256"], expected_hash)

        moved = await self.tools.move_file(
            {"source": "nested/a.txt", "destination": "other/b.txt", "create_parents": True}
        )
        self.assertEqual(moved["sha256"], expected_hash)
        self.assertFalse((self.root / "nested/a.txt").exists())
        self.assertEqual((self.root / "other/b.txt").read_text(), "hello\n")

        deleted = await self.tools.delete_file({"path": "other/b.txt"})
        self.assertTrue(deleted["deleted"])
        self.assertFalse((self.root / "other/b.txt").exists())

    async def test_write_refuses_overwrite_by_default(self):
        (self.root / "a.txt").write_text("old")
        with self.assertRaises(AgentError) as raised:
            await self.tools.write_file({"path": "a.txt", "content": "new"})
        self.assertEqual(raised.exception.code, "already_exists")
        self.assertEqual((self.root / "a.txt").read_text(), "old")

    async def test_structured_mutations_reject_parent_traversal(self):
        with self.assertRaises(AgentError) as raised:
            await self.tools.write_file({"path": "../escape.txt", "content": "x"})
        self.assertIn(raised.exception.code, {"invalid_path", "path_outside_workspace"})

        (self.root / "source.txt").write_text("x")
        with self.assertRaises(AgentError) as raised:
            await self.tools.move_file({"source": "source.txt", "destination": "../escape.txt"})
        self.assertIn(raised.exception.code, {"invalid_path", "path_outside_workspace"})


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.workspace = Workspace(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_shifted_hunk_matches_near_declared_line(self):
        target = self.root / "a.txt"
        target.write_text("header\nalpha\nbeta\ngamma\n")
        patch = """--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 alpha
-beta
+BETA
 gamma
"""
        apply_unified_patch(self.workspace, patch)
        self.assertEqual(target.read_text(), "header\nalpha\nBETA\ngamma\n")

    def test_conflict_reports_excerpts_and_line_endings(self):
        (self.root / "a.txt").write_text("one\ntwo\nthree\n")
        patch = """--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,2 @@
 alpha
-beta
+BETA
"""
        with self.assertRaises(AgentError) as raised:
            apply_unified_patch(self.workspace, patch)
        self.assertEqual(raised.exception.code, "patch_conflict")
        self.assertEqual(raised.exception.details["expected_line"], 1)
        self.assertEqual(raised.exception.details["expected_excerpt"], ["alpha", "beta"])
        self.assertEqual(raised.exception.details["actual_excerpt"], ["one", "two", "three"])
        self.assertEqual(raised.exception.details["line_endings"], "LF")

    def test_apply_patch_envelope_add_update_delete(self):
        (self.root / "old.txt").write_text("remove me\n")
        (self.root / "edit.txt").write_text("alpha\nbeta\ngamma\n")
        patch = """*** Begin Patch
*** Add File: added.txt
+hello
+world
*** Update File: edit.txt
@@
 alpha
-beta
+BETA
 gamma
*** Delete File: old.txt
*** End Patch
"""

        changed = apply_unified_patch(self.workspace, patch)

        self.assertEqual(changed, ["added.txt", "edit.txt", "old.txt"])
        self.assertEqual((self.root / "added.txt").read_text(), "hello\nworld\n")
        self.assertEqual((self.root / "edit.txt").read_text(), "alpha\nBETA\ngamma\n")
        self.assertFalse((self.root / "old.txt").exists())


class OpenAPITests(unittest.TestCase):
    def test_all_descriptions_are_at_most_300_characters(self):
        schema = server.app.openapi()
        descriptions = []

        def collect(value, path="$"):
            if isinstance(value, dict):
                for key, child in value.items():
                    child_path = f"{path}.{key}"
                    if key == "description" and isinstance(child, str):
                        descriptions.append((child_path, child))
                    collect(child, child_path)
            elif isinstance(value, list):
                for index, child in enumerate(value):
                    collect(child, f"{path}[{index}]")

        collect(schema)
        too_long = [(path, len(text)) for path, text in descriptions if len(text) > 300]
        self.assertEqual(too_long, [])


if __name__ == "__main__":
    unittest.main()
