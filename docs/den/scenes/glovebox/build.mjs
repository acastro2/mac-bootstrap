// The anatomy of a den, drawn as a lab glovebox (anatomy skill kit).
//
//   node docs/den/scenes/glovebox/build.mjs            # dark + light SVG and an HTML card
//
// The sealed cabinet is the agent VM. You work through the glove ports (Rex over
// SSH): your hands reach in, your body stays out. Keys only go in through the
// airlock (1Password -> the VM). The pressure gauge reads below zero: a glovebox
// is held at negative pressure, so a leak pulls air in, never out (no host
// mounts, no SSH agent). One sealed cable gland is the only line back out, to a
// terminal block on the bench (`code .` and the browse tunnel). The lamp on the
// lid is vm-up, which keeps the box alive. Words live in the README, not here.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

const KIT = join(homedir(), ".agents/skills/anatomy");
const k = await import(join(KIT, "kit/iso-kit.mjs"));
const G = await import(join(KIT, "kit/lathe.mjs"));
const T = await import(join(KIT, "kit/tube.mjs"));

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, "..", "..", "img");
const WIDTH = 760;
const HEIGHT = 440;

const BENCH = { x: -150, y: -95, w: 290, d: 185, r: 8 };
const BENCH_H = 10;
const FOOT_H = 5;
const PLINTH = { x: -74, y: -59, w: 138, d: 88, r: 5 };
const BODY = { x: -70, y: -55, w: 130, d: 80, r: 4 };
const LID = { x: -73, y: -58, w: 136, d: 86, r: 5 };
const FRONT = BODY.y + BODY.d; // the +y face: window, ports, gauge, gland
const Z_PLINTH = 6;
const Z_LID = 76;
const LID_H = 6;
const WIN = { x0: -58, x1: 30, z0: 16, z1: 68 };
const PORTS = [-36, 8];
const PORT_Z = 38;
const GAUGE = [45, 58];
const GLAND = [45, 24];
const LOCK = { x: 60, y: -38, w: 40, d: 40, r: 3 };
const LOCK_Z = 4;
const LOCK_H = 44;
const HATCH = [LOCK.x + LOCK.w, LOCK.y + LOCK.d / 2, LOCK_Z + LOCK_H / 2];
const TERM = { x: -66, y: 46, w: 34, d: 26, r: 3 };
const TERM_H = 14;
const KEY = { x: 112, y: -30, w: 18, d: 22, r: 2 };
const FILTER = [-30, -22];
const LAMP = [42, -36];

const P = k.fitProjection(
  [...k.boxCorners(BENCH, -BENCH_H - FOOT_H, 0), [FILTER[0], FILTER[1], Z_LID + LID_H + 16], [LAMP[0], LAMP[1], Z_LID + LID_H + 18]],
  WIDTH,
  HEIGHT,
  { pad: 26, azimuth: 45 },
);

const at = (p) => k.iso(p, P);
const S = (paths, style) => k.solidSvg(paths, style);
const L = (d, style) => k.lineSvg(d, style);
const D = (points, style) => k.dotsSvg(points, style);
const poly = (points) => k.pathOf(points.map(at), true);
const byDepth = (points) => [...points].sort((a, b) => k.depthOf([a[0], a[1], 0], P) - k.depthOf([b[0], b[1], 0], P));
const onFront = (x, z, out = 0) => [x, FRONT + out, z];

function bench() {
  const out = [`<path class="iso-halo" d="${k.haloOf(BENCH, -BENCH_H - FOOT_H, BENCH_H, P)}"/>`];
  for (const [x, y] of byDepth(k.corners(BENCH, 22))) {
    out.push(S(k.cylinder(x, y, 7, -BENCH_H - FOOT_H, 1.6, P, 28), { tone: "lo" }));
    out.push(S(k.cylinder(x, y, 5.4, -BENCH_H - FOOT_H + 1.6, FOOT_H - 1.6, P, 28), { tone: "mid" }));
  }
  out.push(S(k.slabOf(BENCH, -BENCH_H, BENCH_H, P, 8, 1.6), { tone: "mid" }));
  out.push(L(k.planOutline(k.insetPlan(BENCH, 5), 0, P), { tone: "lo" }));
  const screws = k.corners(BENCH, 10);
  out.push(L(screws.map(([x, y]) => k.ring(x, y, 2.2, 0, P, 16)).join(""), { tone: "lo" }));
  out.push(D(screws.map(([x, y]) => at([x, y, 0])), { size: 0.5 }));
  // Ruler strip along the front edge.
  const strip = { x: -130, y: BENCH.y + BENCH.d - 14, w: 250, d: 6, r: 1 };
  out.push(S(k.slabOf(strip, 0, 0.6, P, 3), { tone: "lo", crease: "none" }));
  const ticks = k.topTicks(strip.x + 4, strip.x + strip.w - 4, 5, 5, strip.y + 0.8, 0.6, [2, 3.6], P);
  out.push(L(ticks.minor, { tone: "lo" }), L(ticks.major, { tone: "mid" }));
  out.push(D([at([strip.x + 2, strip.y + 3, 0.6]), at([strip.x + strip.w - 2, strip.y + 3, 0.6])], { size: 0.45 }));
  return out.join("");
}

function cabinet() {
  const out = [`<path class="iso-halo" d="${k.haloOf(PLINTH, 0, 2, P)}" style="filter:blur(4px)"/>`];
  out.push(S(k.slabOf(PLINTH, 0, Z_PLINTH, P, 6, 0.6), { tone: "mid" }));
  out.push(D(k.corners(PLINTH, 4).map(([x, y]) => at([x, y, Z_PLINTH])), { size: 0.45 }));
  // The sealed body, with a weld band near the top.
  out.push(S(k.slabOf(BODY, Z_PLINTH, Z_LID - Z_PLINTH, P, 6, 0.6), {
    tone: "hi",
    crease: "lo",
    inner: L(k.sideSeam(BODY, Z_LID - 4, P, 6), { tone: "faint" }) + L(k.sideSeam(BODY, Z_PLINTH + 4, P, 6), { tone: "faint" }),
  }));
  // Engraved plate on the plinth front.
  out.push(k.faceTextSvg(k.sideMatrix([-6, PLINTH.y + PLINTH.d], Z_PLINTH - 1.6, P, "left"), "AGENT", { size: 3.2, tone: "lo", anchor: "middle" }));
  // Window: frame, glass inset, two glare lines that run edge to edge.
  const frame = [onFront(WIN.x0, WIN.z0), onFront(WIN.x1, WIN.z0), onFront(WIN.x1, WIN.z1), onFront(WIN.x0, WIN.z1)];
  const glass = [onFront(WIN.x0 + 3, WIN.z0 + 3), onFront(WIN.x1 - 3, WIN.z0 + 3), onFront(WIN.x1 - 3, WIN.z1 - 3), onFront(WIN.x0 + 3, WIN.z1 - 3)];
  out.push(`<path class="iso-top" d="${poly(glass)}" style="opacity:.55"/>`);
  out.push(L(poly(frame), { tone: "mid" }), L(poly(glass), { tone: "lo" }));
  out.push(L(k.segment(onFront(WIN.x0 + 12, WIN.z1 - 3), onFront(WIN.x0 + 3, WIN.z1 - 14), P), { tone: "faint" }));
  out.push(L(k.segment(onFront(WIN.x0 + 22, WIN.z1 - 3), onFront(WIN.x0 + 3, WIN.z1 - 24), P), { tone: "faint" }));
  const frameScrews = [];
  for (let x = WIN.x0 + 1.5; x <= WIN.x1 - 1; x += 11) frameScrews.push(at(onFront(x, WIN.z0 + 1.5)), at(onFront(x, WIN.z1 - 1.5)));
  out.push(D(frameScrews, { size: 0.4, tone: "lo" }));
  // Glove ports: a flanged ring, a bolt circle, the dark cuff opening.
  for (const x of PORTS) {
    const F = G.frameAlong([x, FRONT, PORT_Z], [0, 1, 0]);
    out.push(S(G.disc(0, 0.6, 9, F, P), { tone: "lo", crease: "none" }));
    out.push(S(G.ringBand(0, 4, 9, 13, F, P), { tone: "mid" }));
    out.push(S(G.ringBand(4, 6, 8, 10.5, F, P), { tone: "mid" }));
    out.push(D(G.dotsOf(F, 4, 11.6, 10, P, { all: true }), { size: 0.45, tone: "lo" }));
    out.push(L(G.circleOf(F, 0.7, 6.5, P), { tone: "faint" }));
  }
  // Pressure gauge: below zero, so a leak pulls air in, never out.
  {
    const F = G.frameOf([GAUGE[0], FRONT, GAUGE[1]], [0, 1, 0], [1, 0, 0], [0, 0, 1]);
    out.push(S(G.disc(0, 2, 8.5, F, P), { tone: "mid" }));
    out.push(S(G.disc(2, 3.2, 7.4, F, P), { tone: "hi", crease: "lo" }));
    out.push(L(G.spokesOf(F, 3.2, 5.2, 6.6, 12, P, { from: Math.PI * 0.2, to: Math.PI * 1.8 }), { tone: "lo" }));
    out.push(L(G.spokesOf(F, 3.2, 4.4, 6.6, 3, P, { from: Math.PI * 0.2, to: Math.PI * 1.8 }), { tone: "mid" }));
    // Needle: from the hub toward -30 on a 0..100 dial, left of the zero mark.
    const hub = G.pointOf(F, 3.3, 0, 0);
    const tip = G.pointOf(F, 3.3, 5.6, Math.PI * 0.62);
    out.push(`<path class="iso-line" data-tone="lit" data-free="end" d="${k.pathOf([at(hub), at(tip)])}" style="stroke-width:1.1"/>`);
    out.push(D([at(hub)], { size: 0.7, tone: "hi" }));
  }
  // The one sealed cable gland: body, then a hex-like nut.
  {
    const F = G.frameAlong([GLAND[0], FRONT, GLAND[1]], [0, 1, 0]);
    out.push(S(G.disc(0, 2.5, 5.2, F, P), { tone: "mid" }));
    out.push(S(G.disc(2.5, 5, 3.6, F, P, { steps: 6 }), { tone: "mid" }));
    out.push(S(G.disc(5, 7, 2.4, F, P), { tone: "hi", crease: "lo" }));
  }
  return out.join("");
}

function lid() {
  const out = [S(k.slabOf(LID, Z_LID, LID_H, P, 6, 0.8), { tone: "mid" })];
  out.push(L(k.planOutline(k.insetPlan(LID, 4), Z_LID + LID_H, P, 6), { tone: "faint" }));
  out.push(D(k.corners(LID, 3).map(([x, y]) => at([x, y, Z_LID + LID_H])), { size: 0.5, tone: "lo" }));
  const top = Z_LID + LID_H;
  // Exhaust filter housing: a knurled canister with a ribbed cap.
  const [fx, fy] = FILTER;
  out.push(S(k.cylinder(fx, fy, 15, top, 2, P, 48), { tone: "lo" }));
  out.push(S(k.cylinder(fx, fy, 13, top + 2, 11, P, 48, 0.6), { tone: "mid", inner: L(k.sideArc(fx, fy, 13, top + 8, P, 32), { tone: "faint" }) }));
  out.push(L(k.knurl(fx, fy, 13, top + 8, top + 13, 40, P), { tone: "lo" }));
  out.push(S(k.cylinder(fx, fy, 6, top + 13, 3, P, 32), { tone: "mid" }));
  out.push(L(k.ring(fx, fy, 11, top + 13, P, 48), { tone: "lo" }));
  out.push(L(k.radialTicks(fx, fy, 11, 24, 6, top + 13, [1.2, 2.2], P).minor, { tone: "lo" }));
  out.push(D([at([fx, fy, top + 16])], { size: 0.6, tone: "lo" }));
  // vm-up: a lamp on a short post, the one lit part.
  const [lx, ly] = LAMP;
  out.push(S(k.cylinder(lx, ly, 7, top, 2, P, 32), { tone: "lo" }));
  out.push(S(k.cylinder(lx, ly, 4, top + 2, 8, P, 24), { tone: "mid", inner: L(k.sideArc(lx, ly, 4, top + 6, P, 16), { tone: "faint" }) }));
  out.push(S(G.sphereOf([lx, ly, top + 13], 5, P), { tone: "hi", lit: true }));
  return out.join("");
}

function airlock() {
  const out = [`<path class="iso-halo" d="${k.haloOf(k.insetPlan(LOCK, -2), 0, 2, P)}" style="filter:blur(4px)"/>`];
  out.push(S(k.slabOf(k.insetPlan(LOCK, -2), 0, LOCK_Z, P, 4, 0.5), { tone: "mid" }));
  out.push(S(k.slabOf(LOCK, LOCK_Z, LOCK_H, P, 4, 0.6), {
    tone: "hi",
    crease: "lo",
    inner: L(k.sideSeam(LOCK, LOCK_Z + LOCK_H - 4, P, 4), { tone: "faint" }),
  }));
  out.push(D(k.corners(LOCK, 3).map(([x, y]) => at([x, y, LOCK_Z + LOCK_H])), { size: 0.45, tone: "lo" }));
  // Outer hatch with a hand wheel.
  const F = G.frameOf(HATCH, [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  out.push(S(G.disc(0, 1.6, 15, F, P), { tone: "mid" }));
  out.push(D(G.dotsOf(F, 1.6, 13.4, 12, P, { all: true }), { size: 0.45, tone: "lo" }));
  out.push(S(G.disc(1.6, 3, 11, F, P), { tone: "hi", crease: "lo" }));
  out.push(S(G.disc(3, 7.6, 1.6, F, P), { tone: "mid" }));
  out.push(S(G.ringBand(6, 7.6, 6.2, 7.6, F, P), { tone: "mid" }));
  out.push(L(G.circleOf(F, 7.6, 6.2, P), { tone: "mid" }));
  out.push(L(G.spokesOf(F, 7.6, 1.6, 6.2, 3, P, { phase: Math.PI / 6 }), { tone: "mid" }));
  // Hinge knuckles on the hatch side.
  for (const dz of [-9, 9]) {
    const H = G.frameAlong([HATCH[0] + 1, HATCH[1] - 15.5, HATCH[2] + dz], [0, 0, 1]);
    out.push(S(G.disc(-3, 3, 1.6, H, P), { tone: "mid" }));
  }
  return out.join("");
}

// The one line out: a real cable from the gland nose, down to the bench and
// across to a connector boss on the terminal block (`code .` and the browse
// tunnel). Pieces are depth-sorted by their centres.
const CABLE_R = 1.4;
const BOSS = [TERM.x + TERM.w, TERM.y + TERM.d / 2, 1.9];
function cable() {
  const route = G.fillet(
    [
      [GLAND[0], FRONT + 7, GLAND[1]],
      [GLAND[0], FRONT + 16, GLAND[1]],
      [GLAND[0], FRONT + 16, CABLE_R],
      [GLAND[0], BOSS[1], CABLE_R],
      [BOSS[0] + 3, BOSS[1], CABLE_R],
    ],
    4.2,
    9,
    { P, tube: CABLE_R },
  );
  const view = G.viewOf(P);
  const pieces = T.tubePieces(route, CABLE_R, P, { maxLength: 14 });
  pieces.sort((a, b) => G.dot3(a.mid, view) - G.dot3(b.mid, view));
  return pieces.map((piece) => T.tubeSvg(piece, { tone: "mid" })).join("");
}

function boss() {
  const F = G.frameAlong(BOSS, [1, 0, 0]);
  return S(G.disc(0, 3, 1.9, F, P), { tone: "mid" }) + S(G.disc(1, 1.6, 2.3, F, P), { tone: "mid" });
}

function terminal() {
  const out = [`<path class="iso-halo" d="${k.haloOf(TERM, 0, 2, P)}" style="filter:blur(3px)"/>`];
  out.push(S(k.slabOf(TERM, 0, TERM_H, P, 4, 0.6), { tone: "mid" }));
  out.push(L(k.planOutline(k.insetPlan(TERM, 3), TERM_H, P, 4), { tone: "faint" }));
  const pins = [];
  for (let i = 0; i < 4; i++) pins.push([TERM.x + 8 + i * 6, TERM.y + 9]);
  for (const [x, y] of byDepth(pins)) out.push(S(k.cylinder(x, y, 1.6, TERM_H, 2.4, P, 16), { tone: "hi", crease: "none" }));
  for (let i = 0; i < 3; i++) out.push(L(k.lineOnTop([TERM.x + 6, TERM.y + 15 + i * 3], [TERM.x + 22 - i * 4, TERM.y + 15 + i * 3], TERM_H, P), { tone: "lo", free: true }));
  return out.join("");
}

function keyCartridge() {
  const out = [`<path class="iso-halo" d="${k.haloOf(KEY, 0, 2, P)}" style="filter:blur(3px)"/>`];
  out.push(S(k.slabOf(KEY, 0, 6, P, 3, 0.5), { tone: "hi", crease: "lo" }));
  const [cx, cy] = [KEY.x + 6, KEY.y + KEY.d / 2];
  out.push(L(k.ring(cx, cy, 3, 6, P, 20), { tone: "mid" }));
  out.push(L(k.lineOnTop([cx + 3, cy], [KEY.x + KEY.w - 3, cy], 6, P), { tone: "mid" }));
  out.push(L(k.lineOnTop([KEY.x + KEY.w - 6, cy], [KEY.x + KEY.w - 6, cy + 3], 6, P), { tone: "mid", free: "end" }));
  out.push(L(k.lineOnTop([KEY.x + KEY.w - 3.5, cy], [KEY.x + KEY.w - 3.5, cy + 2.4], 6, P), { tone: "mid", free: "end" }));
  return out.join("");
}

const LABEL =
  "A lab glovebox on a bench: the anatomy of a den. The sealed cabinet is the agent VM. Two glove ports let you work inside without getting in (Rex over SSH). " +
  "An airlock with a hand-wheel hatch is the only way keys go in (1Password to the VM). A pressure gauge reads below zero: nothing leaks out. " +
  "One sealed cable gland runs to a terminal block on the bench (code . and the browse tunnel). A lamp on the lid is vm-up, which keeps the box alive.";

const body = [bench(), cabinet(), lid(), airlock(), terminal(), boss(), cable(), keyCartridge()];

mkdirSync(OUT, { recursive: true });
for (const theme of ["dark", "light"]) {
  const svg = k.figureSvg({ width: WIDTH, height: HEIGHT, label: LABEL, body, standalone: theme });
  writeFileSync(join(OUT, `anatomy-${theme}.svg`), svg);
}
const card = k.plateHtml({
  fig: "Fig 1",
  title: "The den glovebox",
  hint: "Hands in, never the body",
  readout: "gauge −30 Pa · sealed",
  keys: [
    { mark: "lit", label: "vm-up: keeps the box alive" },
    { mark: "raised", label: "The VM, sealed, at negative pressure" },
  ],
  caption: LABEL,
  body: k.figureSvg({ width: WIDTH, height: HEIGHT, label: LABEL, body }),
});
writeFileSync(join(HERE, "glovebox.html"), k.pageHtml({ title: "The den glovebox", theme: "dark", body: card, width: 820 }));
console.log("wrote", join(OUT, "anatomy-dark.svg"), join(OUT, "anatomy-light.svg"), join(HERE, "glovebox.html"));
