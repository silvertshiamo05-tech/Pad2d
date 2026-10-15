// Dumps puppet geometry from the original Inochi2D 0.8 runtime (renderless),
// one line per drawn part in draw order: "<count> x,y x,y ...".
import inochi2d;
import inochi2d.core.nodes.composite;
import std.stdio, std.conv, std.string, std.algorithm, std.array, std.format;

__gshared double now_ = 0;
double timeFunc() { return now_; }

void dumpPart(Puppet p, Part part) {
    if (!part.enabled) return;
    if (part.textureIds.length == 0) return;
    auto data = part.getMesh();
    bool[ushort] used;
    foreach (i; data.indices) used[i] = true;
    auto idx = used.keys.sort.array;
    mat4 m = p.transform.matrix * part.getDynamicMatrix();
    string line = format("%d", idx.length);
    foreach (i; idx) {
        vec2 v = part.vertices[i] - data.origin + part.deformation[i];
        vec4 r = m * vec4(v.x, v.y, 0, 1);
        line ~= format(" %.2f,%.2f", r.x, r.y);
    }
    writeln(line);
}

void collect(Node n, ref Part[] parts) {
    if (auto pt = cast(Part)n) {
        parts ~= pt;
        foreach (c; pt.children) collect(c, parts);
    } else foreach (c; n.children) collect(c, parts);
}

void main(string[] args) {
    inInit(&timeFunc);
    Puppet p = inLoadPuppet(args[1]);
    string mode = args.length > 2 ? args[2] : "rest";
    p.renderParameters = mode != "rest";
    p.enableDrivers = mode == "physics";
    if (args.length > 4) {
        auto idx = p.findParameterIndex(args[3]);
        auto vals = args[4].split(",").map!(to!float).array;
        p.parameters[idx].value = vec2(vals[0], vals.length > 1 ? vals[1] : 0);
    }
    import std.process : environment;
    int frames = mode == "physics" ? environment.get("FRAMES", "120").to!int : 1;
    foreach (f; 0 .. frames) {
        now_ += 1.0 / 60;
        inUpdate();
        p.update();
    }
    import std.math : cmp;
    auto roots = p.getRootParts().dup;
    roots.sort!((a, b) => cmp(a.zSort, b.zSort) > 0, SwapStrategy.stable);
    foreach (rp; roots) {
        if (!rp.renderEnabled) continue;
        if (auto c = cast(Composite)rp) {
            if (!c.enabled) continue;
            Part[] parts;
            foreach (ch; c.children) collect(ch, parts);
            import std.math : cmp;
            parts.sort!((a, b) => cmp(a.zSort, b.zSort) > 0, SwapStrategy.stable);
            foreach (pt; parts) dumpPart(p, pt);
        } else if (auto pt = cast(Part)rp) {
            dumpPart(p, pt);
        }
    }
}
