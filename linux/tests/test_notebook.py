import sys
import importlib.util
import pathlib
import tempfile
import unittest
import cairo

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
spec = importlib.util.spec_from_file_location('notebook', pathlib.Path(__file__).parents[1] / 'notebook.py')
notebook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notebook)


class AnnotationTests(unittest.TestCase):
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
