"""Test the native code that ships in the iPhone app; no third-party Python packages."""
import ctypes as C
import math
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = ["01-beat.wav", "02-lead.wav", "03-back-1.wav", "04-back-2.wav"]
FPS = 44100

class Window(C.Structure):
    _fields_ = [('skip', C.c_int64), ('start', C.c_int64), ('count', C.c_int64)]

class AudioTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory()
        lib = Path(cls.work.name) / 'studio.so'
        link = '-dynamiclib' if sys.platform == 'darwin' else '-shared'
        subprocess.run(['cc', link, '-fPIC', '-O2', '-Wall', '-Wextra', '-Werror',
                        str(ROOT/'Audio/StudioDSP.c'), '-o', str(lib), '-lz', '-lm'], check=True)
        cls.dsp = C.CDLL(str(lib))
        cls.dsp.tr_window.argtypes = [C.c_int64]*3
        cls.dsp.tr_window.restype = Window
        cls.dsp.tr_blank_wave.argtypes = [C.c_char_p, C.c_int64]
        cls.dsp.tr_pack.argtypes = [C.c_char_p]*2
        cls.dsp.tr_mix.argtypes = [C.c_char_p, C.c_char_p, C.c_int64, C.POINTER(C.c_float), C.POINTER(C.c_float)]

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in NAMES:
            self.assertEqual(self.dsp.tr_blank_wave(os.fsencode(self.root/name), FPS), 0)

    def put(self, lane, start, samples):
        w = self.dsp.tr_window(start, len(samples), FPS)
        if w.count:
            with (self.root/NAMES[lane]).open('r+b') as f:
                f.seek(44 + 4 * w.start)
                f.write(b''.join(struct.pack('<hh', x, x) for x in samples[w.skip:w.skip+w.count]))

    def pcm(self, name):
        with wave.open(str(self.root/name)) as w:
            self.assertEqual((w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()), (2,2,FPS,FPS))
            return [x[0] for x in struct.iter_unpack('<hh', w.readframes(FPS))]

    def mix(self, gains, wet=(0,0,0,0)):
        vec = C.c_float * 4
        self.assertEqual(self.dsp.tr_mix(os.fsencode(self.root), os.fsencode(self.root/'mix.wav'), FPS,
                                        vec(*gains), vec(*wet)), 0)
        return self.pcm('mix.wav')

    def test_negative_positive_offsets_and_empty_intervals(self):
        for start, count, expected in [(-2,4,(2,0,2)),(4,5,(0,4,2)),(-8,2,(0,0,0)),(6,1,(0,0,0))]:
            w = self.dsp.tr_window(start, count, 6)
            self.assertEqual((w.skip,w.start,w.count), expected)
        self.put(2, -2, [11,22,33,44]); self.put(3, FPS-1, [93,94])
        self.assertEqual(self.pcm(NAMES[2])[:3], [33,44,0])
        self.assertEqual(self.pcm(NAMES[3])[-2:], [0,93])

    def test_independent_faders_and_monitor_exclusion(self):
        for i, level in enumerate([80,800,8000,4000]):
            self.put(i, 12, [level])
        self.assertEqual(self.mix([1,1,1,1])[12], 12880)
        self.assertEqual(self.mix([0.5,1,0,0.25])[12], 1840)

    def test_reverb_dry_stem_and_overload(self):
        self.put(1, 0, [10000])
        wet = self.mix([0,1,0,0], [0,0.5,0,0])
        self.assertEqual(wet[0], 10000); self.assertGreater(wet[1297], 1000)
        self.assertEqual(self.pcm(NAMES[1])[1297], 0)
        for i in range(4): self.put(i, 5, [32767,-32768])
        result = self.mix([1]*4)
        self.assertGreater(result[5], 30000); self.assertLess(result[6], -30000)

    def test_streaming_zip_dry_tracks_and_silent_back(self):
        for i in range(3): self.put(i, 9+i, [i+1])
        video = self.root/'00-video.mp4'
        video.write_bytes(os.urandom(200_001))
        archive = self.root/'stems.zip'
        self.assertEqual(self.dsp.tr_pack(os.fsencode(self.root), os.fsencode(archive)), 0)
        with zipfile.ZipFile(archive) as z:
            self.assertIsNone(z.testzip())
            self.assertEqual(sorted(z.namelist()), sorted(NAMES+[video.name]))
            for path in NAMES+[video.name]:
                self.assertEqual(z.read(path), (self.root/path).read_bytes())
        self.assertFalse(any(self.pcm(NAMES[3])))

    def test_missing_source_never_leaves_partial_artifact(self):
        archive = self.root/'broken.zip'
        self.assertNotEqual(self.dsp.tr_pack(os.fsencode(self.root), os.fsencode(archive)), 0)
        self.assertFalse(archive.exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
