"""The mock-model agent bundle is one the server accepts, pointed at the mock LLM."""

import importlib.util
import io
import tarfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "mock_model", Path(__file__).with_name("mock-model.py")
)
mock_model = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock_model)


class AgentBundleTests(unittest.TestCase):
    def test_bundle_holds_only_the_spec(self):
        with tarfile.open(fileobj=io.BytesIO(mock_model.agent_bundle(6796)), mode="r:gz") as tar:
            self.assertEqual(tar.getnames(), ["config.yaml"])
            spec_text = tar.extractfile("config.yaml").read().decode()
        self.assertEqual(spec_text, mock_model.agent_spec(6796))

    def test_server_validation_accepts_the_bundle(self):
        from omnigent.server.bundles import validate_agent_bundle

        parsed = validate_agent_bundle(
            mock_model.agent_bundle(7001), enforce_handler_allowlist=True
        )
        self.assertEqual(parsed.name, mock_model.AGENT_NAME)
        self.assertEqual(parsed.executor.model, mock_model.MODEL)
        self.assertEqual(parsed.executor.auth.base_url, "http://127.0.0.1:7001/v1")

    def test_multipart_carries_the_bundle_once(self):
        body, content_type = mock_model.multipart("bundle", "agent.tar.gz", b"payload")
        boundary = content_type.split("boundary=")[1]
        self.assertEqual(body.count(f"--{boundary}--".encode()), 1)
        self.assertIn(b'name="bundle"; filename="agent.tar.gz"', body)
        self.assertIn(b"\r\n\r\npayload\r\n", body)


if __name__ == "__main__":
    unittest.main()
