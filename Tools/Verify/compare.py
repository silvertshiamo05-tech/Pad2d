import sys
def load(f):
    out=[]
    for l in open(f):
        t=l.split()
        if not t: continue
        out.append([tuple(map(float,p.split(','))) for p in t[1:]])
    return out
a=load(sys.argv[1]); b=load(sys.argv[2])
worst=0; bad=0; first=None
for i,(x,y) in enumerate(zip(a,b)):
    if len(x)!=len(y): bad+=1; first=first or (i,'len',len(x),len(y)); continue
    e=max((max(abs(p[0]-q[0]),abs(p[1]-q[1])) for p,q in zip(x,y)), default=0)
    if e!=e: e=1e9
    worst=max(worst,e)
    if e>0.05: bad+=1; first=first or (i,'err',e)
print(f"{sys.argv[3]:40s} parts ref={len(a)} mine={len(b)} mismatched={bad} maxErr={worst:.4f} {first or ''}")
