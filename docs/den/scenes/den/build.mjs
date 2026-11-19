// The anatomy of a den: a caged den of wild robot animals, run from outside by
// a robot T-Rex at a console (anatomy skill kit).
//
//   node docs/den/scenes/den/build.mjs        # writes docs/den/img/den-{dark,light}.svg + den.html
//
// What each part means (the README says it in words; no labels in the SVG):
//   the den (walls, floor, cage bars)   the Lima VM `agent`: you see in, nothing gets out
//   wolf, fox, raccoon at a crate       the agents: Claude Code, OpenCode, Docker containers
//   the server rack on the back wall    the Rex server, where the console's cable ends up
//   the T-Rex at the console            you on the Mac: tiny arms, one lever, the whole den
//   the cable through the gland         SSH (Rex, VS Code): the only wire, and it starts outside
//   the key cartridge in the hatch slot the keys going in (1Password -> the VM)
//   the beacon on the corner post       vm-up, which keeps the den alive (the one lit part)
//   no door anywhere                    no shared folders, no SSH agent, no way out
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
const WIDTH = 820;
const HEIGHT = 470;

// ── World ─────────────────────────────────────────────────────────────
const BASE = { x: -182, y: -114, w: 334, d: 206, r: 10 };
const BASE_H = 10;
const FOOT_H = 5;
const DEN = { x: -40, y: -104, w: 150, d: 114, r: 4 }; // x -40..110, y -104..10
const FLOOR_H = 4;
const WALL_T = 8;
const WALL_TOP = 62;
const CURB_T = 6;
const CURB_TOP = 12;
const X_IN = DEN.x + DEN.w - CURB_T; // 108: inner face of the front-right curb
const Y_IN = DEN.y + DEN.d - CURB_T; // 13: inner face of the front-left curb
const BAR_X = DEN.x + DEN.w - CURB_T / 2; // 111
const BAR_Y = DEN.y + DEN.d - CURB_T / 2; // 16
const RAIL_Z = WALL_TOP;
const RAIL_H = 3;

const P = k.fitProjection(
  [...k.boxCorners(BASE, -BASE_H - FOOT_H, 0), [BAR_X, BAR_Y, RAIL_Z + 24], [-70, 62, 122], [DEN.x, DEN.y, WALL_TOP + 4]],
  WIDTH,
  HEIGHT,
  { pad: 22, azimuth: 45, elevation: 40 },
);

const at = (p) => k.iso(p, P);
const S = (paths, style) => k.solidSvg(paths, style);
const L = (d, style) => k.lineSvg(d, style);
const D = (points, style) => k.dotsSvg(points, style);
const poly = (points) => k.pathOf(points.map(at), true);
const depth2 = ([x, y]) => k.depthOf([x, y, 0], P);
const view = G.viewOf(P);

// Vivid accents, only where the colour means something.
const COLOR = {
  beacon: "#3fd36b", // vm-up: the den is alive
  wolf: "#ff7a45", // Claude Code
  fox: "#22d3ee", // OpenCode
  raccoon: "#b48cff", // Docker
  key: "#f5b841", // the keys going in
  cable: "#4c8dff", // SSH, the Mac reaching in (the blue of the bridges diagram)
  rex: "#ff3b30", // the T-Rex's eye
};
const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
const mix = (hex, toward, f) => {
  const a = rgb(hex);
  const b = toward === "black" ? [0, 0, 0] : [255, 255, 255];
  return "#" + a.map((c, i) => Math.round(c + (b[i] - c) * f).toString(16).padStart(2, "0")).join("");
};
// A solid or a tube in one colour: shades darken, the top and edge lighten.
const tint = (svg, hex) =>
  `<g style="--anatomy-shade-0:${mix(hex, "black", 0.55)};--anatomy-shade-1:${mix(hex, "black", 0.42)};` +
  `--anatomy-shade-2:${mix(hex, "black", 0.28)};--anatomy-shade-3:${mix(hex, "black", 0.14)};` +
  `--anatomy-top:${mix(hex, "white", 0.12)};--anatomy-lit-top:${mix(hex, "white", 0.12)};--anatomy-lit-shade:${mix(hex, "black", 0.2)};` +
  `--anatomy-paper:${mix(hex, "black", 0.35)};--anatomy-face:${mix(hex, "black", 0.35)};` +
  `--anatomy-hi:${mix(hex, "white", 0.35)};--anatomy-mid:${hex};--anatomy-lo:${mix(hex, "black", 0.3)};--anatomy-lit:${mix(hex, "white", 0.45)}">${svg}</g>`;
// A glowing ball: a soft halo of its colour, then the ball, lit from the top.
const glowBall = (c, r, hex, halo = 2.6) => {
  const [sx, sy] = at(c);
  const rr = r * G.scaleOf(P) * halo;
  return `<circle cx="${sx.toFixed(1)}" cy="${sy.toFixed(1)}" r="${rr.toFixed(1)}" fill="${hex}" opacity=".28" style="filter:blur(${(rr / 2.2).toFixed(1)}px)"/>` +
    `<g style="--anatomy-shade-0:${mix(hex, "black", 0.3)};--anatomy-shade-1:${hex};--anatomy-shade-2:${mix(hex, "white", 0.35)};` +
    `--anatomy-shade-3:${mix(hex, "white", 0.7)};--anatomy-paper:${hex};--anatomy-face:${hex};--anatomy-hi:${mix(hex, "white", 0.5)};--anatomy-lit:${mix(hex, "white", 0.5)}">` +
    S(G.sphereOf(c, r, P), { tone: "hi" }) + "</g>";
};
const tube = (route, r, tone = "mid", opts = {}) => {
  const pieces = T.tubePieces(route, r, P, { maxLength: 10, ...opts });
  pieces.sort((a, b) => G.dot3(a.mid, view) - G.dot3(b.mid, view));
  return pieces.map((piece) => T.tubeSvg(piece, { tone })).join("");
};

// ── The base: a diorama plate on feet, with a ruler and a name plate ──
function base() {
  const out = [`<path class="iso-halo" d="${k.haloOf(BASE, -BASE_H - FOOT_H, BASE_H, P)}"/>`];
  const feet = [...k.corners(BASE, 24)].sort((a, b) => depth2(a) - depth2(b));
  for (const [x, y] of feet) {
    out.push(S(k.cylinder(x, y, 8, -BASE_H - FOOT_H, 1.6, P, 28), { tone: "lo" }));
    out.push(S(k.cylinder(x, y, 6, -BASE_H - FOOT_H + 1.6, FOOT_H - 1.6, P, 28), { tone: "mid" }));
  }
  out.push(S(k.slabOf(BASE, -BASE_H, BASE_H, P, 8, 1.6), { tone: "mid", inner: L(k.sideSeam(BASE, -BASE_H / 2, P, 8), { tone: "faint" }) }));
  out.push(L(k.planOutline(k.insetPlan(BASE, 6), 0, P), { tone: "lo" }));
  const screws = k.corners(BASE, 11);
  out.push(L(screws.map(([x, y]) => k.ring(x, y, 2.4, 0, P, 16)).join(""), { tone: "lo" }));
  out.push(D(screws.map(([x, y]) => at([x, y, 0])), { size: 0.55 }));
  // Ruler strip along the front-left edge.
  const strip = { x: -40, y: BASE.y + BASE.d - 16, w: 180, d: 6, r: 1 };
  out.push(S(k.slabOf(strip, 0, 0.6, P, 3), { tone: "lo", crease: "none" }));
  const ticks = k.topTicks(strip.x + 4, strip.x + strip.w - 4, 5, 5, strip.y + 0.8, 0.6, [2, 3.6], P);
  out.push(L(ticks.minor, { tone: "lo" }), L(ticks.major, { tone: "mid" }));
  out.push(D([at([strip.x + 2, strip.y + 3, 0.6]), at([strip.x + strip.w - 2, strip.y + 3, 0.6])], { size: 0.45 }));
  // Name plate on the front face, the one engraved word.
  out.push(k.faceTextSvg(k.sideMatrix([50, BASE.y + BASE.d], -BASE_H / 2 + 1.6, P, "left"), "DEN", { size: 4.2, tone: "lo", anchor: "middle" }));
  return out.join("");
}

// ── The den shell: floor, back walls, inside fittings ─────────────────
const WALL_RING = [
  [DEN.x, DEN.y],
  [DEN.x + DEN.w, DEN.y],
  [DEN.x + DEN.w, DEN.y + WALL_T],
  [DEN.x + WALL_T, DEN.y + WALL_T],
  [DEN.x + WALL_T, DEN.y + DEN.d],
  [DEN.x, DEN.y + DEN.d],
];
const CURB_RING = [
  [DEN.x + DEN.w, DEN.y + WALL_T],
  [DEN.x + DEN.w, DEN.y + DEN.d],
  [DEN.x + WALL_T, DEN.y + DEN.d],
  [DEN.x + WALL_T, Y_IN],
  [X_IN, Y_IN],
  [X_IN, DEN.y + WALL_T],
];
const FLOOR_IN = { x: DEN.x + WALL_T, y: DEN.y + WALL_T, w: X_IN - DEN.x - WALL_T, d: Y_IN - DEN.y - WALL_T, r: 0 };

function denBack() {
  const out = [`<path class="iso-halo" d="${k.haloOf(k.insetPlan(DEN, -3), 0, 2, P)}" style="filter:blur(5px)"/>`];
  out.push(S(k.slabOf(DEN, 0, FLOOR_H, P, 4, 0.6), { tone: "mid" }));
  // Floor plates: a grid that runs wall to curb, edge to edge.
  const grid = [];
  for (let x = FLOOR_IN.x + 25; x < FLOOR_IN.x + FLOOR_IN.w - 5; x += 25) grid.push(k.lineOnTop([x, FLOOR_IN.y], [x, FLOOR_IN.y + FLOOR_IN.d], FLOOR_H, P));
  for (let y = FLOOR_IN.y + 27; y < FLOOR_IN.y + FLOOR_IN.d - 5; y += 27) grid.push(k.lineOnTop([FLOOR_IN.x, y], [FLOOR_IN.x + FLOOR_IN.w, y], FLOOR_H, P));
  out.push(L(grid.join(""), { tone: "faint" }));
  out.push(L(k.onTop([[FLOOR_IN.x, FLOOR_IN.y + FLOOR_IN.d], [FLOOR_IN.x + FLOOR_IN.w, FLOOR_IN.y + FLOOR_IN.d], [FLOOR_IN.x + FLOOR_IN.w, FLOOR_IN.y]], FLOOR_H, P), { tone: "faint" }));
  // The back walls: one L of thick concrete, with two seams and a top.
  const seams = [24, 44].map((z) => L(k.ringSeam(WALL_RING, z, P), { tone: "faint" })).join("");
  out.push(S(k.extrude(WALL_RING, FLOOR_H, WALL_TOP - FLOOR_H, P, { convex: false, bevel: 0.8 }), { tone: "mid", inner: seams }));
  const wallTopDots = [];
  for (let x = DEN.x + 14; x < DEN.x + DEN.w - 4; x += 16) wallTopDots.push(at([x, DEN.y + WALL_T / 2, WALL_TOP]));
  for (let y = DEN.y + 22; y < DEN.y + DEN.d - 4; y += 16) wallTopDots.push(at([DEN.x + WALL_T / 2, y, WALL_TOP]));
  out.push(D(wallTopDots, { size: 0.45, tone: "lo" }));
  // Vent slots on the inner face of the right-back wall (closed slots).
  const yFace = DEN.y + WALL_T;
  const slots = [];
  for (let x = 30; x <= 92; x += 9) slots.push(poly([[x, yFace, 40], [x + 5, yFace, 40], [x + 5, yFace, 52], [x, yFace, 52]]));
  out.push(L(slots.join(""), { tone: "lo" }));
  // vm-up: a beacon on the back corner of the wall top, the den's one lit part.
  const bx = DEN.x + WALL_T / 2;
  const by = DEN.y + WALL_T / 2;
  out.push(S(k.cylinder(bx, by, 5.5, WALL_TOP, 2, P, 28), { tone: "lo" }));
  out.push(S(k.cylinder(bx, by, 3.2, WALL_TOP + 2, 7, P, 24), { tone: "mid", inner: L(k.sideArc(bx, by, 3.2, WALL_TOP + 5.5, P, 14), { tone: "faint" }) }));
  out.push(glowBall([bx, by, WALL_TOP + 13.5], 5, COLOR.beacon, 3));
  return out.join("");
}

// The Rex server: a rack against the left-back wall, with drive bays and lights.
function rack() {
  const R = { x: DEN.x + WALL_T, y: -58, w: 12, d: 30, r: 1.5 };
  const out = [S(k.slabOf(R, FLOOR_H, 34, P, 3, 0.5), { tone: "mid", inner: [14, 22, 30].map((z) => L(k.sideSeam(R, FLOOR_H + z, P, 3), { tone: "faint" })).join("") })];
  const xFace = R.x + R.w;
  const lights = [];
  for (const z of [10, 18, 26, 34]) for (const y of [R.y + 5, R.y + 9, R.y + 13]) lights.push(at([xFace, y, FLOOR_H + z - 3]));
  out.push(D(lights, { size: 0.5, tone: "hi" }));
  const bays = [];
  for (const z of [10, 18, 26, 34]) bays.push(poly([[xFace, R.y + 17, FLOOR_H + z - 5.5], [xFace, R.y + 27, FLOOR_H + z - 5.5], [xFace, R.y + 27, FLOOR_H + z - 1.5], [xFace, R.y + 17, FLOOR_H + z - 1.5]]));
  out.push(L(bays.join(""), { tone: "lo" }));
  out.push(L(k.planOutline(k.insetPlan(R, 2), FLOOR_H + 34, P, 3), { tone: "faint" }));
  return { depth: depth2([R.x + R.w / 2, R.y + R.d / 2]), svg: out.join("") };
}

// Docker: a slatted crate with corner straps.
function crate() {
  const C = { x: -30, y: -95, w: 26, d: 22, r: 1 };
  const h = 20;
  const inner = [6, 13].map((z) => L(k.sideSeam(C, FLOOR_H + z, P, 2), { tone: "lo" })).join("");
  const out = [S(k.slabOf(C, FLOOR_H, h, P, 2, 0.5), { tone: "mid", inner })];
  out.push(L(k.planOutline(k.insetPlan(C, 2.5), FLOOR_H + h, P, 2), { tone: "lo" }));
  const slats = [];
  for (let x = C.x + 2.5 + 5.25; x < C.x + C.w - 3; x += 5.25) slats.push(k.lineOnTop([x, C.y + 2.5], [x, C.y + C.d - 2.5], FLOOR_H + h, P));
  out.push(L(slats.join(""), { tone: "faint" }));
  out.push(D(k.corners(C, 1.6).map(([x, y]) => at([x, y, FLOOR_H + h])), { size: 0.5, tone: "lo" }));
  return { depth: depth2([C.x + C.w / 2, C.y + C.d / 2]), svg: out.join("") };
}

// ── A robot animal, parametric ────────────────────────────────────────
// axis "x": faces +x, its left side (+y) toward you; axis "y": faces +y.
function robot({ x, y, axis = "x", s = 1, kind = "wolf" }) {
  const P2 = (u, v) => (axis === "x" ? [x + u * s, y + v * s] : [x + v * s, y + u * s]);
  const plan = (u0, v0, du, dv, r) => {
    const [ax, ay] = P2(u0, v0);
    const [bx, by] = P2(u0 + du, v0 + dv);
    return { x: Math.min(ax, bx), y: Math.min(ay, by), w: Math.abs(bx - ax), d: Math.abs(by - ay), r: r * s };
  };
  const Z = (z) => FLOOR_H + z * s;
  const out = [];
  out.push(`<path class="iso-halo" d="${k.haloOf(plan(-12, -6, 26, 12, 4), FLOOR_H, 0.1, P)}" style="filter:blur(3px)"/>`);
  // Tail first: it trails behind (farther from you).
  const tailRoute = kind === "fox"
    ? [[-11, 0, 13], [-16, 0, 16], [-20, 0, 21], [-21, 0, 26]]
    : kind === "raccoon"
      ? [[-11, 0, 13], [-16, 0, 13], [-20, 0, 16], [-22, 0, 20]]
      : [[-11, 0, 14], [-15, 0, 17], [-18, 0, 22]];
  const tailPts = G.fillet(tailRoute.map(([u, v, z]) => [...P2(u, v), Z(z)]), 3 * s, 7, { P, tube: 1.5 * s });
  const tailR = kind === "fox" ? (t) => (1.2 + 2.6 * Math.sin(Math.PI * Math.min(1, t * 1.1))) * s : (t) => (1.6 - 0.8 * t) * s;
  // The fox's brush ends in a white tip, like a real one: drawn by the tube's own tone.
  out.push(tube(tailPts, tailR, kind === "fox" ? "hi" : "mid", kind === "raccoon" ? { rings: { pitch: 2.6 * s, tone: "lo" } } : {}));
  // Legs: four, under the body, far ones first.
  const legs = [[-8, -3.5], [7, -3.5], [-8, 3.5], [7, 3.5]].map(([u, v]) => P2(u, v)).sort((a, b) => depth2(a) - depth2(b));
  for (const [lx, ly] of legs) {
    out.push(S(k.cylinder(lx, ly, 2.2 * s, FLOOR_H, 1.4 * s, P, 16), { tone: "lo" }));
    out.push(S(k.cylinder(lx, ly, 1.5 * s, FLOOR_H + 1.4 * s, 7.6 * s, P, 14), { tone: "mid", crease: "none", inner: L(k.sideArc(lx, ly, 1.5 * s, Z(5), P, 10), { tone: "faint" }) }));
  }
  // Body, with a seam and a battery pack on the back.
  const body = plan(-11, -5, 22, 10, 4);
  out.push(S(k.slabOf(body, Z(9), 8 * s, P, 5, 0.6), { tone: "hi", crease: "lo", inner: L(k.sideSeam(body, Z(13), P, 5), { tone: "faint" }) }));
  const pack = plan(-6, -3, 9, 6, 1.2);
  out.push(S(k.slabOf(pack, Z(17), 3 * s, P, 3, 0.4), { tone: "mid" }));
  out.push(D(k.corners(pack, 1.2).map(([px, py]) => at([px, py, Z(20)])), { size: 0.4, tone: "lo" }));
  out.push(D([P2(-9, 0), P2(6, 0)].map(([px, py]) => at([px, py, Z(17)])), { size: 0.45, tone: "lo" }));
  // Head on a short neck, snout forward, two ears, eyes on the front face.
  const neck = plan(9, -2.5, 4, 5, 1.5);
  out.push(S(k.slabOf(neck, Z(15), 4 * s, P, 3), { tone: "mid", crease: "none" }));
  const head = plan(11, -4, 8, 8, 2.2);
  out.push(S(k.slabOf(head, Z(16), 7 * s, P, 4, 0.5), { tone: "hi", crease: "lo" }));
  const snoutLen = kind === "wolf" ? 6 : kind === "fox" ? 5 : 3.5;
  const snout = plan(19, -2.2, snoutLen, 4.4, 1.4);
  out.push(S(k.slabOf(snout, Z(16), 3.6 * s, P, 3, 0.3), { tone: "mid" }));
  const nose = P2(19 + snoutLen, 0);
  const earH = kind === "fox" ? 5.5 : kind === "wolf" ? 4.5 : 2.6;
  for (const v of [-2.6, 2.6].sort((a, b) => depth2(P2(13, a)) - depth2(P2(13, b)))) {
    const ear = plan(12.5, v - 1.2, 3, 2.4, 0.6);
    out.push(S(k.slabOf(ear, Z(23), earH * s, P, 2), { tone: "mid", crease: "none" }));
  }
  // Eyes and the antenna: the robot looks alive.
  const fx = axis === "x" ? head.x + head.w : null;
  const eyes = axis === "x"
    ? [[fx, y - 1.8 * s, Z(20.5)], [fx, y + 1.8 * s, Z(20.5)]]
    : [[x - 1.8 * s, head.y + head.d, Z(20.5)], [x + 1.8 * s, head.y + head.d, Z(20.5)]];
  out.push(L(eyes.map((e) => k.sideRing(e, 1.15 * s, axis === "x" ? "x" : "y", P, 14)).join(""), { tone: "mid" }));
  for (const e of eyes) out.push(glowBall(e, 0.75 * s, COLOR[kind], 2.4));
  out.push(D([at([...nose, Z(18)])], { size: 0.6, tone: "lo" }));
  if (kind === "raccoon") {
    // The mask: a band across the head that wraps its corners.
    out.push(L(k.sideSeam(head, Z(20.5) + 2 * s, P, 4), { tone: "lo" }), L(k.sideSeam(head, Z(20.5) - 2 * s, P, 4), { tone: "lo" }));
  }
  const ant = P2(15, 0);
  // The antenna: a socket on the head top and a thin rod in it.
  out.push(S(k.cylinder(ant[0], ant[1], 1.1 * s, Z(23), 0.7 * s, P, 12), { tone: "mid", crease: "none" }));
  out.push(S(k.cylinder(ant[0], ant[1], 0.32 * s, Z(23.7), 4.4 * s, P, 8), { tone: "mid", crease: "none" }));
  out.push(glowBall([...ant, Z(28.6)], 0.7 * s, COLOR[kind], 2));
  return { depth: depth2([x, y]), svg: out.join("") };
}

// ── The den front: curb, cage bars, top rail, the beacon ──────────────
function denFront() {
  const out = [S(k.extrude(CURB_RING, FLOOR_H, CURB_TOP - FLOOR_H, P, { convex: false, bevel: 0.6 }), { tone: "mid" })];
  const bars = [];
  for (let y = DEN.y + WALL_T + 12; y < BAR_Y - 6; y += 19) bars.push([BAR_X, y, 1.1]);
  for (let x = DEN.x + WALL_T + 12; x < BAR_X - 6; x += 19) bars.push([x, BAR_Y, 1.1]);
  bars.push([BAR_X, BAR_Y, 2.8]);
  bars.sort((a, b) => depth2(a) - depth2(b));
  for (const [bx, by, r] of bars) {
    out.push(S(k.cylinder(bx, by, r + 1, CURB_TOP, 1.2, P, 16), { tone: "lo" }));
    out.push(S(k.cylinder(bx, by, r, CURB_TOP + 1.2, RAIL_Z - CURB_TOP - 1.2, P, r > 2 ? 24 : 12), { tone: r > 2 ? "hi" : "mid", crease: "none" }));
  }
  // Top rail: two beams that sit on the wall tops at their far ends.
  const railY = { x: BAR_X - 2.5, y: DEN.y, w: 5, d: DEN.d, r: 1 };
  const railX = { x: DEN.x, y: BAR_Y - 2.5, w: DEN.w, d: 5, r: 1 };
  out.push(S(k.slabOf(railY, RAIL_Z, RAIL_H, P, 3, 0.4), { tone: "mid" }));
  out.push(S(k.slabOf(railX, RAIL_Z, RAIL_H, P, 3, 0.4), { tone: "mid" }));
  const railDots = [];
  for (let y = DEN.y + 6; y < DEN.y + DEN.d - 3; y += 20) railDots.push(at([BAR_X, y, RAIL_Z + RAIL_H]));
  for (let x = DEN.x + 6; x < DEN.x + DEN.w - 3; x += 20) railDots.push(at([x, BAR_Y, RAIL_Z + RAIL_H]));
  out.push(D(railDots, { size: 0.45, tone: "lo" }));
  // The corner post gets a plain cap; the beacon lives on the back corner.
  out.push(S(k.cylinder(BAR_X, BAR_Y, 4.2, RAIL_Z + RAIL_H, 1.6, P, 24), { tone: "mid" }));
  // The gland where the console's cable comes in (on the front-left curb).
  const F = G.frameAlong(GLAND, [0, 1, 0]);
  out.push(S(G.disc(0, 2.4, 3.4, F, P), { tone: "mid" }));
  out.push(S(G.disc(2.4, 4.4, 2.6, F, P, { steps: 6 }), { tone: "mid" }));
  out.push(S(G.disc(4.4, 5.6, 1.9, F, P), { tone: "hi", crease: "lo" }));
  return out.join("");
}
const GLAND = [-17, DEN.y + DEN.d, 8];

// ── Outside: the feeding hatch and the key cartridge ──────────────────
function hatch() {
  // A pass-through hatch outside the den: a hand wheel to open it, and above
  // it an intake slot where the gold key cartridge is being fed in.
  const Hb = { x: DEN.x + DEN.w, y: -74, w: 16, d: 24, r: 1.5 };
  const H = 44;
  const xF = Hb.x + Hb.w;
  const out = [`<path class="iso-halo" d="${k.haloOf(Hb, 0, 2, P)}" style="filter:blur(3px)"/>`];
  out.push(S(k.slabOf(Hb, 0, H, P, 3, 0.6), { tone: "mid", inner: [27, 40].map((z) => L(k.sideSeam(Hb, z, P, 3), { tone: "faint" })).join("") }));
  out.push(D(k.corners(Hb, 1.8).map(([hx, hy]) => at([hx, hy, H])), { size: 0.45, tone: "lo" }));
  // The hand wheel.
  const C = [xF, Hb.y + Hb.d / 2, 14];
  const F = G.frameOf(C, [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  out.push(S(G.disc(0, 1.4, 9, F, P), { tone: "mid" }));
  out.push(D(G.dotsOf(F, 1.4, 7.9, 10, P, { all: true }), { size: 0.4, tone: "lo" }));
  out.push(S(G.disc(1.4, 2.6, 6.6, F, P), { tone: "hi", crease: "lo" }));
  out.push(S(G.disc(2.6, 6, 1.4, F, P), { tone: "mid" }));
  out.push(S(G.ringBand(5, 6.4, 4, 5.2, F, P), { tone: "mid" }));
  out.push(L(G.circleOf(F, 6.4, 4, P), { tone: "mid" }));
  out.push(L(G.spokesOf(F, 6.4, 1.4, 4, 3, P, { phase: Math.PI / 6 }), { tone: "mid" }));
  // The intake slot: a dark opening with a frame, and a tray under it.
  const slot = [[xF, -69, 31], [xF, -55, 31], [xF, -55, 37.5], [xF, -69, 37.5]];
  out.push(`<path d="${poly(slot)}" fill="var(--anatomy-shade-0)" stroke="none"/>`);
  out.push(L(poly(slot), { tone: "mid" }));
  out.push(L(poly([[xF, -70.5, 29.6], [xF, -53.5, 29.6], [xF, -53.5, 38.9], [xF, -70.5, 38.9]]), { tone: "lo" }));
  const tray = { x: xF, y: -70.5, w: 9, d: 17, r: 1 };
  out.push(S(k.slabOf(tray, 29.6, 1.4, P, 2, 0.3), { tone: "mid" }));
  // The key cartridge, half in the slot, its key pointing into the den. The
  // body is gold; the key is engraved in dark amber, outside the tint, so it
  // never turns gold on gold.
  const Kc = { x: xF, y: -67.5, w: 14, d: 11, r: 1.6 };
  const kz = 31;
  const kh = 5;
  const top = kz + kh;
  const [cx, cy] = [Kc.x + Kc.w - 4.2, Kc.y + Kc.d / 2];
  out.push(tint(S(k.slabOf(Kc, kz, kh, P, 3, 0.5), { tone: "hi", crease: "lo" }), COLOR.key));
  const glyph = [
    L(k.ring(cx, cy, 2.6, top, P, 20), { tone: "mid" }),
    L(k.ring(cx, cy, 1, top, P, 12), { tone: "mid" }),
    L(k.lineOnTop([cx - 2.6, cy], [Kc.x + 2.2, cy], top, P), { tone: "mid", free: "end" }),
    L(k.lineOnTop([Kc.x + 4.6, cy], [Kc.x + 4.6, cy + 2.4], top, P), { tone: "mid", free: "end" }),
    L(k.lineOnTop([Kc.x + 2.8, cy], [Kc.x + 2.8, cy + 1.8], top, P), { tone: "mid", free: "end" }),
  ].join("");
  out.push(`<g style="--anatomy-mid:#5c3a00;--anatomy-weight:1.15">${glyph}</g>`);
  return out.join("");
}

// ── The robot T-Rex and its console ───────────────────────────────────
// The T-Rex is built in its own units (u forward along +x, v to its left
// along +y, z up), scaled by R, around its hip. It towers over the den, but
// runs it with tiny arms on one lever.
const R = 1.5;
const HIP = [-112, 64];
const tx = (u) => HIP[0] + u * R;
const ty = (v) => HIP[1] + v * R;
const tz = (z) => z * R;
const tplan = (u, v, du, dv, r) => ({ x: tx(u), y: ty(v), w: du * R, d: dv * R, r: r * R });

const CON = { x: -76, y: 50, w: 20, d: 26, r: 2 };
const CON_H = 34;
const LEVER = [-73.5, 63];
const KNOB = [LEVER[0], LEVER[1], CON_H + 21];
const BOSS = [CON.x + CON.w, CON.y + 6, 7];

function consoleBox() {
  const out = [`<path class="iso-halo" d="${k.haloOf(CON, 0, 2, P)}" style="filter:blur(3px)"/>`];
  out.push(S(k.slabOf(CON, 0, CON_H, P, 3, 0.6), { tone: "mid", inner: L(k.sideSeam(CON, 5, P, 3), { tone: "faint" }) }));
  // A screen inset on top with three text rows, and two buttons.
  const scr = { x: CON.x + 10, y: CON.y + 3, w: 7, d: 18, r: 1 };
  out.push(S(k.slabOf(scr, CON_H, 0.6, P, 2), { tone: "lo", crease: "none" }));
  out.push(L([0, 1, 2].map((i) => k.lineOnTop([scr.x + 1.6 + i * 1.8, scr.y + 2], [scr.x + 1.6 + i * 1.8, scr.y + 11 - i * 2.5], CON_H + 0.6, P)).join(""), { tone: "mid", free: true }));
  const buttons = [[CON.x + 4, CON.y + 18], [CON.x + 4, CON.y + 22]].sort((a, b) => depth2(a) - depth2(b));
  for (const [bx, by] of buttons) out.push(S(k.cylinder(bx, by, 1.3, CON_H, 1.3, P, 12), { tone: "hi", crease: "none" }));
  // Vent slots on the front face (+x).
  const xF = CON.x + CON.w;
  const vents = [];
  for (let z = 14; z <= 26; z += 3) vents.push(poly([[xF, CON.y + 11, z], [xF, CON.y + 22, z], [xF, CON.y + 22, z + 1.4], [xF, CON.y + 11, z + 1.4]]));
  out.push(L(vents.join(""), { tone: "lo" }));
  // The cable boss, low on the front face.
  const F = G.frameAlong(BOSS, [1, 0, 0]);
  out.push(tint(S(G.disc(0, 3, 2.6, F, P), { tone: "mid" }) + S(G.disc(1, 1.8, 3.3, F, P), { tone: "mid" }), COLOR.cable));
  // The lever stalk; its knob is drawn last, over the claws.
  out.push(S(k.cylinder(LEVER[0], LEVER[1], 2.8, CON_H, 1.4, P, 20), { tone: "lo" }));
  out.push(S(k.cylinder(LEVER[0], LEVER[1], 0.9, CON_H + 1.4, 17.6, P, 12), { tone: "mid", crease: "none" }));
  return out.join("");
}

function cable() {
  const route = G.fillet(
    [
      [BOSS[0] + 3, BOSS[1], BOSS[2]],
      [BOSS[0] + 9, BOSS[1], BOSS[2]],
      [BOSS[0] + 9, BOSS[1], 1.7],
      [BOSS[0] + 9, 26, 1.7],
      [GLAND[0], 26, 1.7],
      [GLAND[0], 26, GLAND[2]],
      [GLAND[0], GLAND[1] + 5.6, GLAND[2]],
    ],
    4.5,
    9,
    { P, tube: 1.7 },
  );
  return tint(tube(route, 1.7, "mid", { rings: { pitch: 2.4, tone: "lo", fade: [0.15, 0.6] } }), COLOR.cable);
}

function trex() {
  // Tail: a long taper behind, drawn first, with armour rings.
  const tailPts = G.fillet([[tx(-16), ty(0), tz(46)], [tx(-26), ty(1), tz(44)], [tx(-34), ty(4), tz(36)], [tx(-40), ty(7), tz(24)]], 10, 9, { P, tube: 8 });
  const back = tube(tailPts, (t) => (7.4 - 6 * t) * R, "mid", { rings: { pitch: 5, tone: "lo", fade: [0.2, 0.6] } });
  // A leg: toe plate with three claws, shin, knee ball, a heavy thigh.
  const leg = (v) => {
    const out = [];
    const foot = tplan(-3, v - 4.5, 17, 9, 2);
    out.push(`<path class="iso-halo" d="${k.haloOf(foot, 0, 1, P)}" style="filter:blur(2px)"/>`);
    out.push(S(k.slabOf(foot, 0, tz(3), P, 3, 0.4), { tone: "mid" }));
    const claws = [-3, 0, 3].map((dv) => [foot.x + foot.w, ty(v + dv)]).sort((a, b) => depth2(a) - depth2(b));
    for (const [cx, cy] of claws) out.push(S(G.sphereOf([cx, cy, tz(1.4)], 1.4 * R, P), { tone: "hi" }));
    out.push(S(k.cylinder(tx(3), ty(v), 3.2 * R, tz(3), tz(17), P, 20), { tone: "mid", crease: "none", inner: [9, 14].map((z) => L(k.sideArc(tx(3), ty(v), 3.2 * R, tz(z), P, 12), { tone: "faint" })).join("") }));
    out.push(S(G.sphereOf([tx(3), ty(v), tz(21)], 4.6 * R, P), { tone: "mid" }));
    out.push(S(k.cylinder(tx(0), ty(v), 6.4 * R, tz(22), tz(12), P, 32, 0.6), { tone: "hi", crease: "lo", inner: L(k.sideArc(tx(0), ty(v), 6.4 * R, tz(28), P, 18), { tone: "faint" }) }));
    return out.join("");
  };
  // Hull, then a raised chest: the forward lean of a T-Rex.
  const hull = tplan(-18, -10, 36, 20, 9);
  const chest = tplan(6, -8.5, 16, 17, 6);
  const body = [S(k.slabOf(hull, tz(34), tz(20), P, 8, 0.8), { tone: "hi", crease: "lo", inner: [40, 47].map((z) => L(k.sideSeam(hull, tz(z), P, 8), { tone: "faint" })).join("") })];
  body.push(S(k.slabOf(chest, tz(38), tz(22), P, 6, 0.6), { tone: "hi", crease: "lo", inner: L(k.sideSeam(chest, tz(48), P, 6), { tone: "faint" }) }));
  const rivets = [];
  for (let u = -12; u <= 4; u += 6) rivets.push(at([tx(u), ty(-6), tz(54)]), at([tx(u), ty(6), tz(54)]));
  body.push(D(rivets, { size: 0.5, tone: "lo" }));
  for (let i = 0; i < 5; i++) {
    const sp = tplan(-13 + i * 6, -1.5, 4.5, 3, 0.8);
    body.push(S(k.slabOf(sp, tz(54), tz(4 - Math.abs(i - 2) * 0.7), P, 2, 0.3), { tone: "mid", crease: "none" }));
  }
  const HJ = G.frameAlong([tx(0), ty(10), tz(42)], [0, 1, 0]);
  body.push(S(G.disc(0, 1.6 * R, 5.8 * R, HJ, P), { tone: "mid" }));
  body.push(D(G.dotsOf(HJ, 1.6 * R, 4.5 * R, 6, P, { all: true }), { size: 0.45, tone: "lo" }));
  // Neck up from the chest, then the head: long snout, open jaws, teeth.
  const neck = tplan(14, -6, 12, 12, 4);
  const head = tplan(12, -8, 34, 16, 4);
  const jaw = tplan(16, -6.5, 28, 13, 3);
  const HEAD_Z = 66;
  const JAW_Z = [56, 60];
  const top = [S(k.slabOf(neck, tz(58), tz(10), P, 4, 0.5), { tone: "mid", crease: "none", inner: L(k.sideSeam(neck, tz(63), P, 4), { tone: "faint" }) })];
  top.push(S(k.slabOf(jaw, tz(JAW_Z[0]), tz(JAW_Z[1] - JAW_Z[0]), P, 3, 0.4), { tone: "mid" }));
  const lower = [];
  for (let u = 22; u < 43; u += 3.4) lower.push([tx(u), ty(5)]);
  for (const [px, py] of lower) top.push(S(k.cylinder(px, py, 0.75 * R, tz(JAW_Z[1]), tz(2), P, 8), { tone: "hi", crease: "none" }));
  const upper = [];
  for (let u = 20.3; u < 44; u += 3.4) upper.push([tx(u), ty(6.4)]);
  for (const [px, py] of upper) top.push(S(k.cylinder(px, py, 0.75 * R, tz(HEAD_Z - 2.2), tz(2.2), P, 8), { tone: "hi", crease: "none" }));
  top.push(S(k.slabOf(head, tz(HEAD_Z), tz(12), P, 4, 0.6), { tone: "hi", crease: "lo", inner: L(k.sideSeam(head, tz(HEAD_Z + 3.5), P, 4), { tone: "faint" }) }));
  top.push(L(k.planOutline(k.insetPlan(head, 2.6 * R), tz(HEAD_Z + 12), P, 4), { tone: "faint" }));
  const brow = tplan(19, 4, 10, 4, 1);
  top.push(S(k.slabOf(brow, tz(HEAD_Z + 12), tz(2.2), P, 2), { tone: "mid", crease: "none" }));
  // The eye: a ring on the near face and a red glow, the T-Rex watching.
  const eye = [tx(23), head.y + head.d, tz(HEAD_Z + 7.5)];
  top.push(L(k.sideRing(eye, 3 * R, "y", P, 20), { tone: "mid" }));
  top.push(glowBall(eye, 1.4 * R, COLOR.rex, 2.6));
  top.push(D([at([tx(43), ty(-2.5), tz(HEAD_Z + 12)]), at([tx(43), ty(2.5), tz(HEAD_Z + 12)])], { size: 0.65, tone: "lo" }));
  // Tiny arms: shoulder on the chest, a short upper arm down to the elbow,
  // a forearm in to the lever, and a two-fingered hand closed on the knob.
  const arm = (side) => {
    const v = side * 9;
    const shoulder = [tx(17), ty(v), tz(47)];
    const elbow = [tx(19.5), ty(v), tz(41)];
    const wrist = [KNOB[0] - 3, KNOB[1] + side * 2.8, KNOB[2] + 0.8];
    const out = [];
    if (side > 0) {
      const SJ = G.frameAlong([tx(16.5), ty(8.5), tz(47)], [0, 1, 0]);
      out.push(S(G.disc(0, 0.6 * R, 1.7 * R, SJ, P), { tone: "mid" }));
    }
    out.push(tube(G.fillet([shoulder, [tx(18.4), ty(v), tz(44)], elbow], 1.5, 6, { P, tube: 1.1 * R }), 1.1 * R, "mid"));
    out.push(S(G.sphereOf(elbow, 1.35 * R, P), { tone: "hi" }));
    out.push(tube([elbow, wrist], 0.95 * R, "mid"));
    out.push(S(G.sphereOf(wrist, 1.15 * R, P), { tone: "hi" }));
    // Two fingers curl over the knob; each ends in a claw.
    for (const dz of [1.4, -1.2]) {
      const tip = [KNOB[0] + 1.3, KNOB[1] + side * 1.2, KNOB[2] + dz];
      const pts = G.fillet([wrist, [KNOB[0] - 1.2, KNOB[1] + side * 2.4, KNOB[2] + dz * 1.5], tip], 1.2, 6, { P, tube: 0.5 * R });
      out.push(tube(pts, 0.5 * R, "mid"));
      out.push(S(G.sphereOf(tip, 0.62 * R, P), { tone: "hi" }));
    }
    return out.join("");
  };
  const arms = [arm(-1), arm(1)];
  return { back, far: leg(-8), body: body.join(""), head: top.join(""), near: leg(8), arms };
}

// ── Assemble, back to front ───────────────────────────────────────────
const inside = [
  rack(),
  crate(),
  robot({ x: 14, y: -66, axis: "x", s: 1.6, kind: "raccoon" }),
  robot({ x: 25, y: -16, axis: "x", s: 1.8, kind: "wolf" }),
  robot({ x: 72, y: -68, axis: "y", s: 1.45, kind: "fox" }),
].sort((a, b) => a.depth - b.depth);

const rex = trex();
const body = [
  base(),
  denBack(),
  ...inside.map((item) => item.svg),
  denFront(),
  hatch(),
  cable(),
  rex.back,
  rex.far,
  rex.body,
  rex.head,
  rex.near,
  consoleBox(),
  rex.arms[0],
  S(G.sphereOf(KNOB, 2.8, P), { tone: "hi" }),
  rex.arms[1],
];

const LABEL =
  "A den on a diorama base: the anatomy of den. Inside a caged den, three wild robot animals (a wolf, a fox, and a raccoon at a crate) are the coding agents in the VM. " +
  "Outside, a robot T-Rex runs the den from a console with its tiny arms; one cable runs from the console through a sealed gland into the den. " +
  "A gold key cartridge is fed through a hatch, the only way keys go in, a beacon on the corner post keeps the den alive, and there is no door.";

mkdirSync(OUT, { recursive: true });
for (const theme of ["dark", "light"]) {
  writeFileSync(join(OUT, `den-${theme}.svg`), k.figureSvg({ width: WIDTH, height: HEIGHT, label: LABEL, body, standalone: theme }));
}
const card = (theme) =>
  k.pageHtml({
    title: "The den",
    theme,
    width: 880,
    body: k.plateHtml({
      fig: "Fig 1",
      title: "The den",
      hint: "Wild agents in, nothing out",
      readout: "vm-up · beacon on",
      keys: [
        { mark: "lit", label: "vm-up keeps the den alive" },
        { mark: "raised", label: "The VM: cage bars, no door" },
      ],
      caption: LABEL,
      body: k.figureSvg({ width: WIDTH, height: HEIGHT, label: LABEL, body }),
    }),
  });
writeFileSync(join(HERE, "den.html"), card("dark"));
writeFileSync(join(HERE, "den-light.html"), card("light"));
console.log("wrote docs/den/img/den-dark.svg docs/den/img/den-light.svg and the den.html pages");
