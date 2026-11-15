"""Original tileable stylized textures. Reproducible, no external runtime libs.
Authors these new textures; does not alter any third-party artwork.
"""
from pathlib import Path
import math,random,struct,zlib,json,wave
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'assets/release/textures';OUT.mkdir(parents=True,exist_ok=True)
def png(path,w,h,data):
 def chunk(t,d):return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
 raw=b''.join(b'\0'+data[y*w*3:(y+1)*w*3] for y in range(h))
 path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b''))
random.seed(41);N=512
for name in ['floor','wood','wall','fabric','metal','tile']:
 pixels=bytearray();normals=bytearray();rough=bytearray()
 for y in range(N):
  for x in range(N):
   noise=random.uniform(-3,3);grout=0;nx=0.;ny=0.
   if name=='floor':
    grout=1 if x%128<3 or y%128<3 else 0;base=(126,147,145);grain=noise+(3 if (x//128+y//128)%2 else -3);nx=.06*math.sin(x/17);ny=.06*math.sin(y/19)
   elif name=='wood':
    grout=1 if x%128<2 or (y+(x//128)*173)%512<3 else 0;grain=noise+6*math.sin(x*.7+4*math.sin(y*.009))+3*math.sin(x*.14);base=(156,115,78);nx=.15*math.cos(x*.7);ny=.01
   elif name=='wall':base=(215,215,199);grain=noise*.7+1.8*math.sin(y*1.7);nx=noise/80;ny=noise/80
   elif name=='fabric':base=(190,194,190);grain=noise+(5 if (x%4<2) != (y%4<2) else -5);nx=.12*math.sin(x*math.pi/2);ny=.12*math.sin(y*math.pi/2)
   elif name=='metal':base=(133,151,159);grain=noise*.5+2*math.sin(y*1.1);nx=0;ny=.04*math.cos(y*1.1)
   else:base=(219,226,217);grain=noise*.4;grout=1 if x%128<4 or y%128<4 else 0;nx=0;ny=0
   pixels.extend(max(0,min(255,int(c+grain-(28 if grout else 0)))) for c in base)
   normals.extend((int(128+nx*127),int(128+ny*127),255));r=205 if name!='metal' else 135;rough.extend((r,r,r))
 for suffix,data in [('color',pixels),('normal',normals),('roughness',rough)]:png(OUT/(name+'_'+suffix+'.png'),N,N,data)
# Small original nonverbal sound library; no voice/paid audio dependency.
audio=ROOT/'assets/release/audio';audio.mkdir(parents=True,exist_ok=True)
for name,freq,length in [('click',660,.055),('success',880,.13),('door',150,.25),('step',90,.07),('message',1046,.18),('impact',70,.15)]:
 samples=bytearray();rate=22050
 for i in range(int(rate*length)):
  t=i/rate;env=(1-t/length)**2
  value=math.sin(2*math.pi*freq*t)*.18*env
  if name in ['door','step','impact']:value+=(random.random()*2-1)*.12*env
  samples.extend(struct.pack('<h',int(value*32767)))
 with wave.open(str(audio/(name+'.wav')),'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(rate);f.writeframes(samples)
print('Built',len(list(OUT.glob('*.png'))),'original texture maps and six sound effects')
