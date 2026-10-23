import zlib, struct, math, sys, base64
def inside_rrect(x,y,x0,y0,x1,y1,r):
    if x<x0 or x>x1 or y<y0 or y>y1: return False
    cx=min(max(x,x0+r),x1-r); cy=min(max(y,y0+r),y1-r)
    return (x-cx)**2+(y-cy)**2<=r*r
def lock(x,y):  # 24-unit padlock space
    if inside_rrect(x,y,4,8,20,22,2):
        return (x-12)**2+(y-15)**2>4  # keyhole hole
    d=math.hypot(x-12,y-6)
    if y<=6 and 3.1<=d<=5: return True
    if 6<y<=8 and (7<=x<=8.9 or 15.1<=x<=17): return True
    return False
BG=(10,10,10); AC=(0,191,165)
def px(u,v):  # u,v in 0..32
    if not inside_rrect(u,v,0,0,32,32,7): return None
    if not inside_rrect(u,v,2,2,30,30,5.2) : return AC
    if lock(u-4,v-4): return AC
    return BG
def render(n):
    ss=3; out=bytearray()
    for j in range(n):
        out.append(0)
        for i in range(n):
            r=g=b=a=0
            for sj in range(ss):
                for si in range(ss):
                    c=px((i+(si+.5)/ss)*32/n,(j+(sj+.5)/ss)*32/n)
                    if c: r+=c[0];g+=c[1];b+=c[2];a+=1
            t=ss*ss
            if a: out+=bytes((r//a,g//a,b//a,a*255//t))
            else: out+=bytes((0,0,0,0))
    def ch(t,d): 
        c=struct.pack(">I",len(d))+t+d
        return c+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
    return b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",n,n,8,6,0,0,0))+ch(b"IDAT",zlib.compress(bytes(out),9))+ch(b"IEND",b"")
for n in (16,32,150,180,192,512):
    open(f"i{n}.png","wb").write(render(n))
