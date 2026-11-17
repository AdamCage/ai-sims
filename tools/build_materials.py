"""Original tileable stylized textures. Reproducible, no external runtime libs.
Authors these new textures; does not alter any third-party artwork.
"""
from pathlib import Path
import math, random, struct, wave
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'assets/release/textures';OUT.mkdir(parents=True,exist_ok=True)
# Material masters cover four metres. Channels come from the same periodic
# height field so grooves, bevels, grain and finish agree in a close-up.
import numpy as np
from PIL import Image, ImageDraw
N=1024
uv=np.arange(N,dtype=np.float32)/N
x,y=np.meshgrid(uv,uv)
turn=2*math.pi

def save_field(kind, base, detail, height, roughness):
    albedo=np.clip(np.asarray(base,dtype=np.float32)+detail[:,:,None],0,255).astype('uint8')
    dx=(np.roll(height,-1,axis=1)-np.roll(height,1,axis=1))*.5
    dy=(np.roll(height,-1,axis=0)-np.roll(height,1,axis=0))*.5
    normal=np.stack((-dx,dy,np.ones_like(dx)),axis=2)
    normal/=np.linalg.norm(normal,axis=2,keepdims=True)
    normal=np.clip(128+normal*127,0,255).astype('uint8')
    roughness=np.broadcast_to(roughness,x.shape).clip(0,255).astype('uint8')
    Image.fromarray(albedo).save(OUT/(kind+'_color.png'),optimize=True)
    Image.fromarray(normal).save(OUT/(kind+'_normal.png'),optimize=True)
    Image.fromarray(roughness).save(OUT/(kind+'_roughness.png'),optimize=True)

def seam(v,n,width):
    d=np.abs((v*n+.5)%1-.5)*N/n
    return np.clip(1-d/width,0,1)

rng=np.random.default_rng(660)
stone=np.sin(turn*(4*x+2*y))+.6*np.cos(turn*(7*y-x))+.35*np.sin(turn*(19*x+13*y))
# Terrazzo aggregate in a fine cement matrix. Duplicate border chips to tile.
chips=Image.new('L',(N,N),128);draw=ImageDraw.Draw(chips)
for _ in range(4300):
    a,b=rng.integers(0,N,2);r=int(rng.integers(1,4));ink=int(rng.choice([72,96,146,158,176]))
    for offx in ([0,N] if a<r*2 else ([0,-N] if a>N-r*2 else [0])):
        for offy in ([0,N] if b<r*2 else ([0,-N] if b>N-r*2 else [0])):
            px,py=int(a+offx),int(b+offy);draw.polygon([(px-r,py),(px,py-r),(px+r*2,py+r//2),(px+1,py+r)],fill=ink)
chip=(np.asarray(chips,dtype=np.float32)-128)*.48
joints=np.maximum(seam(x,2,2),seam(y,2,2))
save_field('floor',(187,186,176),stone*2+chip-joints*17,chip*.014-joints*.5,192+stone*3+chip*.4)
row=np.floor(y*12);joints=np.maximum(seam(y,12,2.2),seam(x+(row%3)/6,2,2.2))
grain=np.sin(turn*(105*y+.7*np.sin(turn*2*x)+.2*np.sin(turn*(6*x+y))))
wood=grain*3+7*np.sin(turn*(13*y+.3*np.cos(turn*x)))+3*np.cos(turn*(21*y+.5*np.sin(turn*3*x)))
save_field('wood',(177,141,107),wood+(row%3-1)*3-joints*34,wood*.04-joints*1.1,163-wood*.75+joints*42)
stucco=stone*1.6+np.sin(turn*(83*y+37*x))*1.8+np.cos(turn*(51*x-71*y))
save_field('wall',(216,211,196),stucco+chip*.12,stucco*.09+chip*.02,214+stucco*.5)
warp=np.cos(turn*128*x);weft=np.cos(turn*128*y);twill=np.sin(turn*(32*x-32*y))
cloth=4*np.where(twill>0,warp,weft)+2.5*twill+1.2*np.sin(turn*(27*x+19*y))
save_field('fabric',(174,179,171),cloth,cloth*.08,212+cloth)
brush=np.cos(turn*179*y)*2+np.sin(turn*(69*y+.04*np.cos(turn*2*x)))*2.5
rail=np.maximum(seam(x,2,3),seam(y,4,3));bolt=np.minimum(1,((np.sin(turn*x*2)**2+np.sin(turn*y*4)**2)*13))
save_field('metal',(142,154,160),brush+stone*1.8-rail*17-(1-bolt)*24,brush*.03-rail*.65-(1-bolt)*.6,126+brush*2+rail*25)
tile=np.maximum(seam(x,8,3.6),seam(y,8,3.6));glaze=stone*1.3+2*((np.floor(x*8)+np.floor(y*8))%2)
save_field('tile',(218,218,202),glaze-tile*42,glaze*.02-tile*1.1,140+tile*68+glaze)
for preset in OUT.glob('*.png.import'):
    preset.write_text(preset.read_text().replace('mipmaps/generate=false','mipmaps/generate=true'),encoding='utf8')
print('Built six 1024-pixel materials (color, relief-derived normal, roughness).')

# Small original nonverbal sound library; no voice/paid audio dependency.
# Keep release sounds byte-identical to the original generator's noise stream.
random.seed(41)
for _ in range(6*512*512): random.random()
audio=ROOT/'assets/release/audio';audio.mkdir(parents=True,exist_ok=True)
for name,freq,length in [('click',660,.055),('success',880,.13),('door',150,.25),('step',90,.07),('message',1046,.18),('impact',70,.15)]:
 samples=bytearray();rate=22050
 for i in range(int(rate*length)):
  t=i/rate;env=(1-t/length)**2
  value=math.sin(2*math.pi*freq*t)*.18*env
  if name in ['door','step','impact']:value+=(random.random()*2-1)*.12*env
  samples.extend(struct.pack('<h',int(value*32767)))
 with wave.open(str(audio/(name+'.wav')),'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(rate);f.writeframes(samples)
