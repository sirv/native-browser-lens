import sys
import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch,Mock
import cairo

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
spec = importlib.util.spec_from_file_location('notebook', pathlib.Path(__file__).parents[1] / 'notebook.py')
notebook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notebook)


class AnnotationTests(unittest.TestCase):
    def test_fix_request_imports_results_into_the_reviewed_observation(self):
        app=Mock();app.state={'settings':{'codexModel':'chosen-model'}}
        def submit(function,*args):
            from concurrent.futures import Future
            future=Future();future.set_result(function(*args));return future
        app.executor.submit.side_effect=submit
        app.request.side_effect=[{'exportPath':'/job/evidence/report','handoffPath':'/job/evidence/handoff','repositoryPath':'/project'},{},{}]
        payload=dict(repository='/project',observationId='reviewed-observation',reviewedVersion=4,captureId='reviewed-capture',eventId='failure',successStatus=200,serverCommand='npm run dev',cancel=notebook.threading.Event())
        result=dict(directory='/job',before='/job/before/result.json',after='/job/after/result.json')
        with patch.object(notebook.autofix,'create_job',return_value={'directory':'/job'}),patch.object(notebook.autofix,'run',return_value=result) as run:
            response=notebook.Notebook.request(app,'autofix',payload)
        self.assertEqual(response['fixResult'],result)
        self.assertEqual(set(response),{'fixResult'},'Agent completion must not deliver a stale notebook snapshot.')
        self.assertEqual(app.request.call_count,3)
        self.assertEqual(run.call_args.kwargs['model'],'chosen-model')
        for call in app.request.call_args_list[1:3]:
            self.assertEqual(call.args[0],'importVerification')
            self.assertEqual(call.args[1]['observationId'],'reviewed-observation')
            self.assertEqual(call.args[1]['captureId'],'reviewed-capture')
        self.assertEqual(app.request.call_args_list[0].args[1]['reviewedVersion'],4)

    def test_fix_completion_refreshes_on_the_main_worker_even_after_partial_import(self):
        app=Mock();app.jobs=1
        response={'fixResult':{'directory':'/job'},'error':'Second import failed'}
        notebook.Notebook.completed(app,response,None)
        app.send.assert_called_once_with('bootstrap')

    def test_browser_launcher_keeps_flatpak_arguments_and_url_separate(self):
        app=Mock()
        with patch.object(notebook.subprocess,'Popen') as launch:
            notebook.Notebook.open_browser(app,['/usr/bin/flatpak','run','org.mozilla.firefox'],'https://fixture.example/?q=hello;world')
            self.assertEqual(launch.call_args.args[0],['/usr/bin/flatpak','run','org.mozilla.firefox','https://fixture.example/?q=hello;world'])
            notebook.Notebook.open_browser(app,'/usr/bin/firefox','about:debugging')
            self.assertEqual(launch.call_args.args[0],['/usr/bin/firefox','about:debugging'])

    def test_masks_are_opaque_at_frozen_image_coordinates_and_original_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            original = pathlib.Path(directory) / 'original.png'
            reviewed = pathlib.Path(directory) / 'reviewed.png'
            surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 200, 100)
            context = cairo.Context(surface)
            context.set_source_rgb(1, 1, 1)
            context.paint()
            surface.write_to_png(str(original))
            before = original.read_bytes()
            notebook.render_derivative(original, reviewed, [{'kind': 'mask', 'points': [{'x': .25, 'y': .25}, {'x': .75, 'y': .75}]}])
            result = cairo.ImageSurface.create_from_png(str(reviewed))
            pixels = result.get_data()
            stride = result.get_stride()
            self.assertEqual(bytes(pixels[50*stride+100*4:50*stride+100*4+4]), b'\0\0\0\xff')
            self.assertEqual(bytes(pixels[0:4]), b'\xff\xff\xff\xff')
            self.assertEqual(original.read_bytes(), before)
            self.assertEqual(reviewed.stat().st_mode & 0o777, 0o600)

    def test_letterboxing_does_not_shift_annotations(self):
        self.assertIsNone(notebook.image_point(20, 10, 400, 400, 200, 100))
        self.assertEqual(notebook.image_point(100, 150, 400, 400, 200, 100), {'x': .25, 'y': .25})


if __name__ == '__main__':
    unittest.main()
