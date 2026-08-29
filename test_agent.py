import asyncio
import hashlib
import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import agent as agent_module
import server

from agent import MAX_RESPONSE_CHARS, AgentError, AgentTools, RemoteAgent, Workspace, apply_unified_patch


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

    async def test_missing_paths_are_structured_file_not_found_errors(self):
        operations = (
            lambda: self.tools.read_file({"path": "missing.txt"}),
            lambda: self.tools.stat_file({"path": "missing.txt"}),
            lambda: self.tools.delete_file({"path": "missing.txt"}),
        )
        for operation in operations:
            with self.assertRaises(AgentError) as raised:
                await operation()
            self.assertEqual(raised.exception.code, "file_not_found")

    async def test_write_file_overwrite_preserves_mode(self):
        target = self.root / "run.sh"
        target.write_text("#!/bin/sh\n")
        target.chmod(0o755)

        await self.tools.write_file(
            {"path": "run.sh", "content": "#!/bin/sh\necho ok\n", "overwrite": True}
        )

        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)

    async def test_execute_command_bounds_large_output(self):
        result = await self.tools.execute_command(
            {"command": "python -c 'import sys; sys.stdout.write(\"x\" * 1000000)'"}
        )

        self.assertEqual(result["exit_code"], 0)
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["stdout"]), 100_000)

    async def test_command_stream_reader_caps_buffered_bytes(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b"x" * 1_000_000)
        reader.feed_eof()

        buffered, overflow = await self.tools._read_limited_stream(reader)

        self.assertTrue(overflow)
        self.assertEqual(len(buffered), MAX_RESPONSE_CHARS * 4)

    def test_windows_unsandboxed_command_uses_cmd_and_process_group(self):
        with mock.patch.object(agent_module.os, "name", "nt"), mock.patch.dict(
            agent_module.os.environ,
            {
                "COMSPEC": r"C:\Windows\System32\cmd.exe",
                "PATH": r"C:\Windows\System32",
                "SystemRoot": r"C:\Windows",
            },
        ):
            argv, proc_cwd, _ = self.tools._command_argv_and_cwd("echo ok", ".")
            session = self.tools._subprocess_session_kwargs()
            env = self.tools._minimal_env()

        self.assertEqual(
            argv,
            [r"C:\Windows\System32\cmd.exe", "/d", "/s", "/c", "echo ok"],
        )
        self.assertEqual(proc_cwd, str(self.root.resolve()))
        self.assertEqual(
            session["creationflags"],
            getattr(agent_module.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200),
        )
        self.assertNotIn("start_new_session", session)
        self.assertEqual(env["COMSPEC"], r"C:\Windows\System32\cmd.exe")
        self.assertEqual(env["PATH"], r"C:\Windows\System32")
        self.assertEqual(env["SystemRoot"], r"C:\Windows")

    def test_posix_processes_start_new_session(self):
        with mock.patch.object(agent_module.os, "name", "posix"):
            session = self.tools._subprocess_session_kwargs()
        self.assertEqual(session, {"start_new_session": True})

    def test_macos_minimal_path_includes_homebrew(self):
        with mock.patch.object(agent_module.sys, "platform", "darwin"):
            env = self.tools._minimal_env()
        self.assertTrue(env["PATH"].startswith("/opt/homebrew/sbin:/opt/homebrew/bin:"))

    async def test_long_command_start_poll_and_incremental_offsets(self):
        started = await self.tools.start_command(
            {"command": "printf 'first\\n'; sleep 0.1; printf 'second\\n'"}
        )
        job_id = started["job_id"]
        self.assertEqual(started["status"], "running")

        first = await self.tools.poll_command({"job_id": job_id, "wait_seconds": 1})
        self.assertIn("first\n", first["stdout"])

        final = first
        while final["status"] == "running":
            final = await self.tools.poll_command(
                {
                    "job_id": job_id,
                    "stdout_offset": final["stdout_offset"],
                    "stderr_offset": final["stderr_offset"],
                    "wait_seconds": 1,
                }
            )

        self.assertEqual(final["status"], "exited")
        self.assertEqual(final["exit_code"], 0)
        if "second\n" not in final["stdout"]:
            all_output = await self.tools.poll_command({"job_id": job_id})
            self.assertIn("second\n", all_output["stdout"])

    async def test_long_command_cancel_terminates_job(self):
        started = await self.tools.start_command({"command": "sleep 30"})

        cancelled = await self.tools.cancel_command({"job_id": started["job_id"]})

        self.assertEqual(cancelled["status"], "cancelled")
        self.assertIsNotNone(cancelled["exit_code"])

    async def test_shutdown_terminates_all_running_long_commands(self):
        first = await self.tools.start_command({"command": "sleep 30"})
        second = await self.tools.start_command({"command": "sleep 30"})

        await self.tools.shutdown_command_jobs()

        for job_id in (first["job_id"], second["job_id"]):
            job = self.tools.command_jobs[job_id]
            self.assertEqual(job.status, "cancelled")
            self.assertIsNotNone(job.exit_code)

    async def test_list_commands_includes_started_jobs(self):
        started = await self.tools.start_command({"command": "printf done"})
        await self.tools.poll_command({"job_id": started["job_id"], "wait_seconds": 1})

        result = await self.tools.list_commands({})

        self.assertIn(started["job_id"], {job["job_id"] for job in result["jobs"]})

    async def test_long_command_output_buffer_is_bounded(self):
        started = await self.tools.start_command(
            {"command": f"python -c 'import sys; sys.stdout.write(\"x\" * {MAX_RESPONSE_CHARS * 2})'"}
        )
        job = self.tools.command_jobs[started["job_id"]]
        await asyncio.wait_for(job.tasks[-1], timeout=2)
        result = await self.tools.poll_command({"job_id": started["job_id"]})

        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["stdout"]), MAX_RESPONSE_CHARS)
        self.assertEqual(result["stdout_offset"], MAX_RESPONSE_CHARS * 2)

    async def test_unknown_long_command_job_is_structured_error(self):
        with self.assertRaises(AgentError) as raised:
            await self.tools.poll_command({"job_id": "missing"})
        self.assertEqual(raised.exception.code, "job_not_found")

    async def test_long_command_tracks_stdout_and_stderr_offsets_independently(self):
        started = await self.tools.start_command(
            {"command": "printf out; printf err >&2"}
        )
        job = self.tools.command_jobs[started["job_id"]]
        await asyncio.wait_for(job.tasks[-1], timeout=2)

        first = await self.tools.poll_command({"job_id": started["job_id"]})
        self.assertEqual(first["stdout"], "out")
        self.assertEqual(first["stderr"], "err")

        second = await self.tools.poll_command(
            {
                "job_id": started["job_id"],
                "stdout_offset": first["stdout_offset"],
                "stderr_offset": first["stderr_offset"],
            }
        )
        self.assertEqual(second["stdout"], "")
        self.assertEqual(second["stderr"], "")

    async def test_remote_long_poll_does_not_block_cancel_request(self):
        agent = RemoteAgent("ws://example.invalid", self.workspace, sandbox=False, network=False)
        started = await agent.tools.start_command({"command": "sleep 30"})
        token = agent.identity.token

        class FakeWebSocket:
            def __init__(self):
                self.index = 0
                self.sent: list[dict] = []

            def __aiter__(self):
                return self

            async def __anext__(self):
                self.index += 1
                if self.index == 1:
                    return json.dumps(
                        {
                            "type": "poll_command",
                            "request_id": "poll",
                            "token": token,
                            "job_id": started["job_id"],
                            "wait_seconds": 30,
                        }
                    )
                if self.index == 2:
                    await asyncio.sleep(0.05)
                    return json.dumps(
                        {
                            "type": "cancel_command",
                            "request_id": "cancel",
                            "token": token,
                            "job_id": started["job_id"],
                        }
                    )
                await asyncio.sleep(0.05)
                raise StopAsyncIteration

            async def send(self, raw: str):
                self.sent.append(json.loads(raw))

        ws = FakeWebSocket()
        await asyncio.wait_for(agent._connection_loop(ws), timeout=2)

        responses = {message.get("request_id"): message for message in ws.sent}
        self.assertEqual(responses["cancel"]["result"]["status"], "cancelled")
        self.assertIn(responses["poll"]["result"]["status"], {"cancelled", "exited"})

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

    def test_bare_hunk_finds_unique_context_away_from_line_one(self):
        (self.root / "edit.txt").write_text("header\nnoise\nalpha\nbeta\ngamma\n")
        patch = """*** Begin Patch
*** Update File: edit.txt
@@
 alpha
-beta
+BETA
 gamma
*** End Patch
"""

        apply_unified_patch(self.workspace, patch)

        self.assertEqual((self.root / "edit.txt").read_text(), "header\nnoise\nalpha\nBETA\ngamma\n")

    def test_bare_hunk_rejects_ambiguous_context(self):
        (self.root / "edit.txt").write_text("alpha\nbeta\nalpha\nbeta\n")
        patch = """*** Begin Patch
*** Update File: edit.txt
@@
 alpha
-beta
+BETA
*** End Patch
"""

        with self.assertRaises(AgentError) as raised:
            apply_unified_patch(self.workspace, patch)

        self.assertEqual(raised.exception.code, "patch_conflict")
        self.assertEqual(raised.exception.details["candidate_lines"], [1, 3])

    def test_explicit_hunk_prefers_match_nearest_declared_line(self):
        target = self.root / "edit.txt"
        target.write_text("alpha\nbeta\nnoise\nalpha\nbeta\n")
        patch = """--- a/edit.txt
+++ b/edit.txt
@@ -4,2 +4,2 @@
 alpha
-beta
+BETA
"""

        apply_unified_patch(self.workspace, patch)

        self.assertEqual(target.read_text(), "alpha\nbeta\nnoise\nalpha\nBETA\n")

    def test_multiple_hunks_apply_in_order(self):
        target = self.root / "edit.txt"
        target.write_text("one\ntwo\nthree\nfour\nfive\n")
        patch = """--- a/edit.txt
+++ b/edit.txt
@@ -1,2 +1,2 @@
 one
-two
+TWO
@@ -4,2 +4,2 @@
 four
-five
+FIVE
"""

        apply_unified_patch(self.workspace, patch)

        self.assertEqual(target.read_text(), "one\nTWO\nthree\nfour\nFIVE\n")

    def test_invalid_hunk_counts_do_not_modify_file(self):
        target = self.root / "edit.txt"
        original = "alpha\nbeta\n"
        target.write_text(original)
        patch = """--- a/edit.txt
+++ b/edit.txt
@@ -1,3 +1,2 @@
 alpha
-beta
+BETA
"""

        with self.assertRaises(AgentError) as raised:
            apply_unified_patch(self.workspace, patch)

        self.assertEqual(raised.exception.code, "invalid_patch")
        self.assertEqual(target.read_text(), original)

    def test_validation_failure_in_later_file_keeps_all_files_unchanged(self):
        first = self.root / "first.txt"
        second = self.root / "second.txt"
        first.write_text("old first\n")
        second.write_text("old second\n")
        patch = """--- a/first.txt
+++ b/first.txt
@@ -1 +1 @@
-old first
+new first
--- a/second.txt
+++ b/second.txt
@@ -1 +1 @@
-does not match
+new second
"""

        with self.assertRaises(AgentError) as raised:
            apply_unified_patch(self.workspace, patch)

        self.assertEqual(raised.exception.code, "patch_conflict")
        self.assertEqual(first.read_text(), "old first\n")
        self.assertEqual(second.read_text(), "old second\n")

    def test_create_existing_file_is_rejected_without_overwrite(self):
        target = self.root / "existing.txt"
        target.write_text("keep\n")
        patch = """*** Begin Patch
*** Add File: existing.txt
+replacement
*** End Patch
"""

        with self.assertRaises(AgentError) as raised:
            apply_unified_patch(self.workspace, patch)

        self.assertEqual(raised.exception.code, "patch_conflict")
        self.assertEqual(target.read_text(), "keep\n")

    def test_update_missing_file_reports_file_not_found(self):
        patch = """*** Begin Patch
*** Update File: missing.txt
@@
-old
+new
*** End Patch
"""

        with self.assertRaises(AgentError) as raised:
            apply_unified_patch(self.workspace, patch)

        self.assertEqual(raised.exception.code, "file_not_found")

    def test_patch_rejects_parent_traversal(self):
        patch = """*** Begin Patch
*** Add File: ../escape.txt
+nope
*** End Patch
"""

        with self.assertRaises(AgentError) as raised:
            apply_unified_patch(self.workspace, patch)

        self.assertIn(raised.exception.code, {"invalid_path", "path_outside_workspace"})
        self.assertFalse((self.root.parent / "escape.txt").exists())

    def test_update_preserves_file_mode(self):
        target = self.root / "run.sh"
        target.write_text("#!/bin/sh\necho old\n")
        target.chmod(0o755)
        patch = """*** Begin Patch
*** Update File: run.sh
@@
-echo old
+echo new
*** End Patch
"""

        apply_unified_patch(self.workspace, patch)

        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)

    def test_malformed_apply_patch_envelope_is_rejected(self):
        patch = """*** Begin Patch
*** Add File: a.txt
+hello
"""

        with self.assertRaises(AgentError) as raised:
            apply_unified_patch(self.workspace, patch)

        self.assertEqual(raised.exception.code, "invalid_patch")

    def test_bare_hunk_without_context_is_rejected(self):
        (self.root / "edit.txt").write_text("alpha\n")
        patch = """*** Begin Patch
*** Update File: edit.txt
@@
+insert only
*** End Patch
"""

        with self.assertRaises(AgentError) as raised:
            apply_unified_patch(self.workspace, patch)

        self.assertEqual(raised.exception.code, "invalid_patch")


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

    def test_already_exists_maps_to_conflict(self):
        self.assertEqual(server.status_for_agent_error("already_exists"), 409)

    def test_command_job_errors_map_to_expected_statuses(self):
        self.assertEqual(server.status_for_agent_error("job_not_found"), 404)
        self.assertEqual(server.status_for_agent_error("too_many_jobs"), 409)

    def test_long_command_operations_are_exposed_in_openapi(self):
        schema = server.app.openapi()
        operation_ids = {
            operation["operationId"]
            for path in schema["paths"].values()
            for operation in path.values()
            if isinstance(operation, dict) and "operationId" in operation
        }
        self.assertTrue(
            {"startCommand", "pollCommand", "cancelCommand", "listCommands"}.issubset(operation_ids)
        )

    def test_long_command_openapi_describes_agent_usage(self):
        schema = server.app.openapi()
        paths = schema["paths"]

        start = paths["/api/start-command"]["post"]
        poll = paths["/api/poll-command"]["post"]
        cancel = paths["/api/cancel-command"]["post"]
        listing = paths["/api/list-commands"]["post"]

        self.assertIn("executeCommand for short commands", start["description"])
        self.assertIn("returned stdout_offset", poll["description"])
        self.assertIn("process tree", cancel["description"])
        self.assertIn("recover a job_id", listing["description"])

        components = schema["components"]["schemas"]
        poll_request = components["PollCommandRequest"]["properties"]
        self.assertIn("Reuse the returned stdout_offset", poll_request["stdout_offset"]["description"])
        self.assertIn("Reuse the returned stderr_offset", poll_request["stderr_offset"]["description"])
        self.assertIn("long-poll", poll_request["wait_seconds"]["description"])

        poll_result = components["PollCommandResult"]["properties"]
        self.assertIn("next poll", poll_result["stdout_offset"]["description"])
        self.assertIn("older buffered output", poll_result["truncated"]["description"])

        summary = components["CommandJobSummary"]["properties"]
        self.assertIn("running, exited, failed, or cancelled", summary["status"]["description"])
        self.assertIn("null while running", summary["exit_code"]["description"])


if __name__ == "__main__":
    unittest.main()
