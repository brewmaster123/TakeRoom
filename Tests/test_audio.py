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
DOUBLE_NAMES = ["05-double-1.wav", "06-double-2.wav"]
PRODUCTION_NAMES = NAMES + DOUBLE_NAMES
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
        cls.dsp.tr_pack_processed.argtypes = [C.c_char_p, C.c_char_p, C.c_uint]
        cls.dsp.tr_mix.argtypes = [C.c_char_p, C.c_char_p, C.c_int64, C.POINTER(C.c_float), C.POINTER(C.c_float)]

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in PRODUCTION_NAMES:
            self.assertEqual(self.dsp.tr_blank_wave(os.fsencode(self.root/name), FPS), 0)

    def put(self, lane, start, samples):
        w = self.dsp.tr_window(start, len(samples), FPS)
        if w.count:
            with (self.root/PRODUCTION_NAMES[lane]).open('r+b') as f:
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

    def test_production_mix_with_cut_and_acapella(self):
        effects = (C.c_float * 48)(*([1,0,0,1,1,1,0,0]*6))
        cuts = (C.c_int64*2)(1000,3000)
        self.put(0,0,[1000]*4000)
        self.put(1,0,[2000]*4000)
        self.put(4, 2000, [700])
        self.put(5, 2500, [900])
        result = self.dsp.tr_produce(os.fsencode(self.root), C.c_int64(FPS), effects,
                                    C.c_float(0),C.c_float(0),cuts,1,1)
        self.assertEqual(result,0)
        self.assertEqual(self.pcm("Master.wav")[2000],2700)
        self.assertEqual(self.pcm("Master.wav")[3500],3000)
        self.assertEqual(self.pcm("processed-01-beat.wav")[2000],0)
        self.assertEqual(self.pcm("Acapella.wav")[3500],2000)
        self.assertEqual(self.pcm("Acapella.wav")[2500], 2900)
        self.assertEqual(self.pcm("processed-" + DOUBLE_NAMES[0])[2000], 700)
        for name in PRODUCTION_NAMES:
            (self.root/("processed-"+name)).replace(self.root/name)
        (self.root/"00-video.mp4").write_bytes(b"video")
        archive=self.root/"processed.zip"
        self.assertEqual(self.dsp.tr_pack_processed(os.fsencode(self.root),os.fsencode(archive),0),0)
        with zipfile.ZipFile(archive) as z:
            self.assertIsNone(z.testzip())
            self.assertCountEqual(z.namelist(), PRODUCTION_NAMES + ["00-video.mp4", "Master.wav", "Acapella.wav"])

    def test_zip_preserves_selected_extra_video_slots_and_unicode(self):
        for name in ["00-video.mp4", "Master.wav", "Acapella.wav"]:
            (self.root / name).write_bytes(b"media")
        extras = self.root / "Доп. видео для монтажа"
        extras.mkdir()
        (extras / "02.mov").write_bytes(b"original video with audio")
        (extras / "04.mov").write_bytes(b"another original video")
        archive = self.root / "extras.zip"
        self.assertEqual(self.dsp.tr_pack_processed(os.fsencode(self.root), os.fsencode(archive), 0b1010), 0)
        with zipfile.ZipFile(archive) as zipped:
            self.assertIsNone(zipped.testzip())
            videos = [name for name in zipped.namelist() if name.endswith(".mov")]
            self.assertEqual(videos, ["Доп. видео для монтажа/02.mov", "Доп. видео для монтажа/04.mov"])
            self.assertEqual(zipped.read(videos[0]), b"original video with audio")
        output = self.root / "unpacked"
        subprocess.run([sys.executable, "-X", "utf8", "-m", "zipfile", "-e", str(archive), str(output)],
                       env={**os.environ, "LC_ALL": "C"}, check=True)
        for name in ("02.mov", "04.mov"):
            self.assertEqual((output / extras.name / name).read_bytes(), (extras / name).read_bytes())
        self.assertNotEqual(self.dsp.tr_pack_processed(os.fsencode(self.root), os.fsencode(archive), 0b1111), 0)
        self.assertFalse(archive.exists())

    def test_estimated_beat_and_silence(self):
        class Grid(C.Structure):
            _fields_=[("tempo",C.c_double),("phase",C.c_double),("root",C.c_int),("minor",C.c_int)]
        self.dsp.tr_analyze.restype=Grid
        self.dsp.tr_analyze.argtypes=[C.POINTER(C.c_float),C.c_int,C.c_double]
        signal=(C.c_float * 96000)()
        silent=self.dsp.tr_analyze(signal,len(signal),8000)
        self.assertEqual((silent.tempo,silent.root),(0,-1))
        for i in range(len(signal)):
            phase=i%4000
            if phase<200:
                signal[i]=math.sin(phase*0.8)*math.exp(-phase/60)
        grid=self.dsp.tr_analyze(signal,len(signal),8000)
        self.assertAlmostEqual(grid.tempo,120,delta=2)

    def test_live_processor_matches_export_and_moves_backing(self):
        effects=(C.c_float*48)(*([1,0.1,0.2,1,1,1,0.1,0.3]*6))
        self.put(0,0,[int(5000*math.sin(i*0.1)) for i in range(FPS)])
        self.put(1,200,[14000]*1000)
        self.put(2,100,[10000]*400)
        self.put(5, 300, [9500]*400)
        cuts=(C.c_int64*2)(1200,2700)
        self.dsp.tr_produce(os.fsencode(self.root),C.c_int64(FPS),effects,C.c_float(0.6),C.c_float(0.4),cuts,1,0)
        expected=self.pcm('Master.wav')
        self.dsp.tr_live_open.restype=C.c_void_p
        self.dsp.tr_live_open.argtypes=[C.c_char_p,C.c_int64]
        self.dsp.tr_live_update.argtypes=[C.c_void_p,C.c_void_p,C.c_void_p,C.c_float,C.c_float,C.c_void_p,C.c_int]
        self.dsp.tr_live_transport.argtypes=[C.c_void_p,C.c_int64,C.c_int,C.c_int,C.c_int64,C.c_int64]
        self.dsp.tr_live_render.argtypes=[C.c_void_p,C.POINTER(C.c_float),C.POINTER(C.c_float),C.c_int]
        self.dsp.tr_live_close.argtypes=[C.c_void_p]
        handle=self.dsp.tr_live_open(os.fsencode(self.root),FPS)
        self.assertTrue(handle)
        try:
            shifts=(C.c_int64*6)()
            self.dsp.tr_live_update(handle,effects,shifts,0.6,0.4,cuts,1)
            self.dsp.tr_live_transport(handle,0,1,0,0,FPS)
            left=(C.c_float*FPS)();right=(C.c_float*FPS)()
            self.dsp.tr_live_render(handle,left,right,FPS)
            self.assertEqual([round(x*32768) for x in left],expected)
            # Isolate and move double 2 by 1000 frames without rebuilding files.
            isolated=(C.c_float*48)(*([0,0,0,1,1,1,0,0]*6))
            isolated[40]=1
            shifts[5]=1000
            self.dsp.tr_live_update(handle,isolated,shifts,0,0,None,0)
            self.dsp.tr_live_transport(handle,0,1,0,0,FPS)
            self.dsp.tr_live_render(handle,left,right,FPS)
            onset=next(i for i,x in enumerate(left) if abs(x)>0.1)
            self.assertEqual(onset,1300)
        finally: self.dsp.tr_live_close(handle)

    def test_reference_delay_match_and_silence_rejection(self):
        import random
        class Match(C.Structure):
            _fields_=[('lag',C.c_int),('score',C.c_double),('margin',C.c_double)]
        self.dsp.tr_match.argtypes=[C.POINTER(C.c_float),C.c_int,C.POINTER(C.c_float),C.c_int,C.c_int,C.c_int,C.c_int]
        self.dsp.tr_match.restype=Match
        rng=random.Random(42)
        ref=(C.c_float*1000)(*[rng.uniform(-1,1) for _ in range(1000)])
        recorded=(C.c_float*1200)()
        for i in range(1000): recorded[i+125]=ref[i]+rng.uniform(-0.15,0.15)
        result=self.dsp.tr_match(ref,1000,recorded,1200,-150,150,20)
        self.assertEqual(result.lag,125)
        self.assertGreater(result.score,0.97)
        silent=(C.c_float*1000)()
        self.assertEqual(self.dsp.tr_match(ref,1000,silent,1000,-150,150,20).score,0)

    def test_tempo_full_supported_range(self):
        class Grid(C.Structure):
            _fields_=[('tempo',C.c_double),('phase',C.c_double),('root',C.c_int),('minor',C.c_int)]
        self.dsp.tr_analyze.restype=Grid
        self.dsp.tr_analyze.argtypes=[C.POINTER(C.c_float),C.c_int,C.c_double]
        rate=8000
        for bpm in [60,70,120,157,164,200]:
            signal=(C.c_float*(rate*24))()
            beat=60*rate/bpm
            for i in range(len(signal)):
                phase=i%beat
                if phase<200: signal[i]=math.sin(phase*0.8)*math.exp(-phase/60)
            grid=self.dsp.tr_analyze(signal,len(signal),rate)
            self.assertAlmostEqual(grid.tempo,bpm,delta=2,msg=str(bpm))

    def test_long_fragment_header(self):
        path=self.root/'long.wav'
        frames=697*FPS
        self.assertEqual(self.dsp.tr_blank_wave(os.fsencode(path),frames),0)
        with wave.open(str(path)) as wav:
            self.assertEqual(wav.getnframes(),frames)
            self.assertEqual(wav.getframerate(),FPS)

if __name__ == '__main__':
    unittest.main(verbosity=2)
