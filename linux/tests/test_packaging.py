import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('lens_package',Path(__file__).resolve().parents[2]/'scripts/package-linux.py')
package=importlib.util.module_from_spec(spec);spec.loader.exec_module(package)


class PackagingTests(unittest.TestCase):
    def test_codex_bundle_requires_and_copies_its_sibling_execution_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'bin';source.mkdir();target=root/'bundle';target.mkdir()
            (source/'codex').write_bytes(b'CLI fixture')
            with patch.object(package.shutil,'which',return_value=str(source/'codex')):
                with self.assertRaisesRegex(ValueError,'codex-code-mode-host'):package.bundle_codex(target)
                self.assertEqual(list(target.iterdir()),[])
                (source/'codex-code-mode-host').write_bytes(b'execution runtime fixture')
                package.bundle_codex(target)
            self.assertEqual((target/'codex').read_bytes(),b'CLI fixture')
            self.assertEqual((target/'codex-code-mode-host').read_bytes(),b'execution runtime fixture')
