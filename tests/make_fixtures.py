"""Generate deterministic, original test media using stdlib and local FFmpeg."""
from pathlib import Path
import struct
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'verification/fixtures'


def png(path, width, height, rgba):
    def chunk(tag, data):
        return struct.pack('!I', len(data)) + tag + data + struct.pack('!I', zlib.crc32(tag + data))
    rows = b''.join(b'\0' + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 6, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    data = bytearray()
    for y in range(180):
        for x in range(320):
            data.extend(((255, 0, 0, 255) if x < 160 else (0, 255, 0, 128)) if y < 90
                        else ((0, 0, 255, 255) if x < 160 else (0, 0, 0, 0)))
    png(OUT / 'alpha.png', 320, 180, data)
    ffmpeg = '/opt/homebrew/bin/ffmpeg'
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
                    '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=30:duration=3',
                    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=3',
                    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
                    str(OUT / 'video.mp4')], check=True)
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
                    '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=10:duration=2',
                    '-loop', '0', str(OUT / 'animation.gif')], check=True)
    (OUT / 'browser.html').write_text('''<!doctype html><html lang="ja"><meta charset="utf-8">
<style>body{margin:0;background:transparent;font:32px sans-serif;color:white}
div{background:#278254;width:260px;padding:20px;animation:move 2s infinite alternate}
@keyframes move{to{transform:translateX(40px)}}</style><div>ASE ブラウザ試験</div></html>''')
    print('Fixtures:', OUT)


if __name__ == '__main__':
    main()
