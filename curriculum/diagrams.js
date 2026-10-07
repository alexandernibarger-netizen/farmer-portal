// Simple nature-metaphor diagrams, drawn as inline SVG (320x200). Colors come from CSS tokens.
const S = (inner, label, bg = "sky") => `<svg viewBox="0 0 320 200" class="dg" role="img" aria-label="${label}"><rect width="320" height="200" class="${bg}"/>${inner}</svg>`;
const G = (y = 168) => `<rect x="0" y="${y}" width="320" height="${200 - y}" class="soil"/>`;
const T = (x, y, s, o = {}) => `<text x="${x}" y="${y}" class="t${o.c ? " " + o.c : ""}" font-size="${o.fs || 10}" text-anchor="${o.a || "middle"}"${o.b ? ' font-weight="800"' : ""}>${s}</text>`;
const OT = (x, y, s, o = {}) => T(x, y, s, { ...o, c: "onsoil" });
function plant(x, y, h = 30, c = "bloom") {
  const r = Math.max(4, h / 6);
  return `<path d="M${x} ${y}V${y - h}" class="stem"/><ellipse cx="${x - 6}" cy="${y - h * 0.4}" rx="6" ry="3" class="leaf" transform="rotate(-30 ${x - 6} ${y - h * 0.4})"/><ellipse cx="${x + 6}" cy="${y - h * 0.6}" rx="6" ry="3" class="leaf" transform="rotate(30 ${x + 6} ${y - h * 0.6})"/><circle cx="${x}" cy="${y - h}" r="${r}" class="${c}"/>`;
}
function sprout(x, y, s = 1) {
  return `<path d="M${x} ${y}v${-8 * s}" class="stem"/><ellipse cx="${x - 4 * s}" cy="${y - 8 * s}" rx="${4 * s}" ry="${2 * s}" class="leaf"/><ellipse cx="${x + 4 * s}" cy="${y - 9 * s}" rx="${4 * s}" ry="${2 * s}" class="leaf2"/>`;
}
function tree(x, y, s = 1, o = {}) {
  const h = 40 * s, r = 26 * s, cy = y - h - r * 0.6;
  const roots = o.roots ? `<path d="M${x} ${y}q${-10 * s} ${10 * s} ${-26 * s} ${14 * s}M${x} ${y}q${2 * s} ${12 * s} ${-2 * s} ${22 * s}M${x} ${y}q${12 * s} ${8 * s} ${28 * s} ${12 * s}" class="root" stroke-width="${Math.max(1.5, 3 * s)}"/>` : "";
  const fr = (o.fruit || []).map(f => `<circle cx="${x + f[0] * s}" cy="${cy + f[1] * s}" r="${(f[3] || 4.5) * s}" class="${f[2] || "apple"}"/>`).join("");
  return roots + `<rect x="${x - 5 * s}" y="${y - h}" width="${10 * s}" height="${h}" rx="${2 * s}" class="trunk"/><circle cx="${x}" cy="${cy}" r="${r}" class="leaf"/><circle cx="${x - r * 0.55}" cy="${cy + r * 0.4}" r="${r * 0.62}" class="leaf2"/><circle cx="${x + r * 0.6}" cy="${cy + r * 0.35}" r="${r * 0.6}" class="leaf"/>` + fr;
}
function person(x, y, c = "shirt1", s = 1) {
  return `<circle cx="${x}" cy="${y - 30 * s}" r="${7 * s}" class="skin"/><path d="M${x - 10 * s} ${y}v${-12 * s}a${10 * s} ${10 * s} 0 0 1 ${20 * s} 0v${12 * s}z" class="${c}"/>`;
}
function bubble(x, y, w, lines, o = {}) {
  lines = [].concat(lines);
  const fs = o.fs || 9, lh = fs + 3, h = lines.length * lh + 8;
  const tail = o.tail === false ? "" : `<path d="M${x + (o.tx || 0) - 5} ${y + h - 2}l5 8l5-8z" class="paper${o.cls ? " " + o.cls : ""}"/>`;
  return tail + `<rect x="${x - w / 2}" y="${y}" width="${w}" height="${h}" rx="7" class="paper${o.cls ? " " + o.cls : ""}"/>` + lines.map((l, i) => T(x, y + 4 + lh * (i + 1) - 2, l, { fs })).join("");
}
function arr(x1, y1, x2, y2, o = {}) {
  const c = o.c || "ar";
  let d, ax, ay;
  if (o.q) { d = `M${x1} ${y1}Q${o.q[0]} ${o.q[1]} ${x2} ${y2}`; [ax, ay] = o.q; } else { d = `M${x1} ${y1}L${x2} ${y2}`; ax = x1; ay = y1; }
  const a = Math.atan2(y2 - ay, x2 - ax), L = 7;
  const p = k => `${(x2 - L * Math.cos(a + k)).toFixed(1)} ${(y2 - L * Math.sin(a + k)).toFixed(1)}`;
  return `<path d="${d}" class="${c}"${o.dash ? ' stroke-dasharray="4 3"' : ""}/><path d="M${x2} ${y2}L${p(-0.45)}L${p(0.45)}z" class="${c}h"/>`;
}
const X = (x, y, s = 8) => `<path d="M${x - s} ${y - s}l${2 * s} ${2 * s}M${x + s} ${y - s}l${-2 * s} ${2 * s}" class="xbad"/>`;
const OK = (x, y) => `<circle cx="${x}" cy="${y}" r="10" class="okbg"/><path d="M${x - 5} ${y}l3.5 4l7-8" class="okl"/>`;
const basket = (x, y, w) => `<path d="M${x - w / 2} ${y}h${w}l-8 24h${-(w - 16)}z" class="soil2"/><path d="M${x - w / 2 + 4} ${y + 8}h${w - 8}M${x - w / 2 + 6} ${y + 16}h${w - 12}" class="weave"/>`;
const sun = (x, y) => `<circle cx="${x}" cy="${y}" r="11" class="gold"/>` + [0, 45, 90, 135, 180, 225, 270, 315].map(d => { const a = d * Math.PI / 180; return `<path d="M${(x + 14 * Math.cos(a)).toFixed(1)} ${(y + 14 * Math.sin(a)).toFixed(1)}L${(x + 19 * Math.cos(a)).toFixed(1)} ${(y + 19 * Math.sin(a)).toFixed(1)}" class="ray"/>`; }).join("");
const house = (x, y, c = "paper") => `<path d="M${x - 16} ${y}v-20l16-14l16 14v20z" class="${c}"/><rect x="${x - 4}" y="${y - 11}" width="8" height="11" class="trunk"/>`;
const truck = (x, y) => `<rect x="${x - 24}" y="${y - 22}" width="30" height="16" rx="2" class="shirt2"/><path d="M${x + 6} ${y - 18}h10l6 7v5h-16z" class="shirt2"/><circle cx="${x - 14}" cy="${y - 5}" r="5" class="ink"/><circle cx="${x + 13}" cy="${y - 5}" r="5" class="ink"/>`;
const fence = (x1, x2, y) => { let s = `<path d="M${x1} ${y - 18}H${x2}M${x1} ${y - 8}H${x2}" class="rail"/>`; for (let x = x1; x <= x2; x += 14) s += `<rect x="${x - 2}" y="${y - 24}" width="4" height="24" class="trunk"/>`; return s; };

const DIAGRAMS = {
  complaints: () => S(
    bubble(55, 8, 92, "My faucet leaks!") + bubble(160, 8, 92, "Lawn's a jungle.") + bubble(265, 8, 92, "Roof's dripping!") +
    person(55, 80, "shirt2", .8) + person(160, 80, "shirt3", .8) + person(265, 80, "shirt1", .8) +
    arr(62, 84, 140, 104, { c: "ag" }) + arr(160, 84, 160, 102, { c: "ag" }) + arr(258, 84, 180, 104, { c: "ag" }) +
    basket(160, 106, 70) + T(160, 121, "YOU", { b: 1, fs: 10, c: "onsoil" }) +
    G(168) + plant(55, 168, 24, "sky2") + plant(160, 168, 24, "leaf2") + plant(265, 168, 24, "apple") +
    arr(140, 130, 70, 140) + arr(160, 131, 160, 140) + arr(180, 130, 250, 140) +
    OT(55, 186, "Plumber") + OT(160, 186, "Landscaper") + OT(265, 186, "Roofer"),
    "People complain, the complaints drop into your basket, and you plant each one with the right contractor"),

  soil: () => S(
    T(80, 24, "Things you love", { b: 1 }) + T(240, 24, "Things you don't care about", { b: 1 }) +
    `<rect x="10" y="140" width="140" height="50" rx="6" class="soil"/><rect x="170" y="140" width="140" height="50" rx="6" class="rocky"/>` +
    plant(45, 142, 70, "bloom") + plant(80, 142, 85, "gold") + plant(115, 142, 68, "sky2") +
    `<path d="M215 142q2-14 10-20" class="stem"/><circle cx="225" cy="121" r="4" class="wilt"/><path d="M265 142q-1-10-8-14" class="stem"/><circle cx="257" cy="127" r="3.5" class="wilt"/>` +
    [180, 200, 238, 282, 296].map((x, i) => `<ellipse cx="${x}" cy="${160 + (i % 2) * 14}" rx="7" ry="5" class="rock"/>`).join("") +
    OT(80, 172, "Rich soil: you connect") + T(240, 112, "Rocky soil: they don't", { c: "tm" }),
    "Plants grow tall in rich soil (your interests) and stay stunted in rocky soil"),

  companion: () => {
    const trades = ["Roofer", "Gutters", "Painter", "Plumber", "Electric", "HVAC", "Lawn", "Fence", "Concrete", "Power wash", "Pest", "Pools", "Windows", "Cleaning", "Lights"];
    const cols = ["apple", "gold", "sky2", "bloom", "leaf2"];
    let s = `<rect x="8" y="36" width="226" height="158" rx="8" class="soil"/>` + T(121, 26, "15 crops, one soil (same customers)", { b: 1 });
    trades.forEach((t, i) => { const x = 31 + (i % 5) * 45, y = 78 + Math.floor(i / 5) * 50; s += plant(x, y, 22, cols[(i + Math.floor(i / 5)) % 5]) + OT(x, y + 11, t, { fs: 7.5 }); });
    s += T(278, 26, "Not this", { b: 1, c: "bad" }) + `<rect x="244" y="110" width="68" height="40" rx="6" class="soil"/>` + plant(268, 112, 40, "apple") + plant(286, 112, 40, "apple") + sun(290, 50) + X(277, 86, 11) + T(278, 166, "Two roofers fight", { fs: 8.5 }) + T(278, 178, "for the same sun", { fs: 8.5 });
    return S(s, "A garden bed with 15 different trades sharing one soil; two of the same trade crowd each other");
  },

  growth: () => {
    let s = "";
    [["Now", "15", 5, 3], ["Later", "50", 10, 5], ["Automated", "500", 22, 12]].forEach(([n, c, cx, ry], k) => {
      const x0 = 8 + k * 105, w = 96;
      s += `<rect x="${x0}" y="58" width="${w}" height="104" rx="6" class="soil"/>` + T(x0 + w / 2, 30, c, { b: 1, fs: 18 }) + T(x0 + w / 2, 46, n, { c: "tm" });
      for (let i = 0; i < cx; i++) for (let j = 0; j < ry; j++) {
        const x = x0 + 8 + (w - 16) * (i + .5) / cx, y = 66 + 92 * (j + .9) / ry;
        s += k === 2 ? `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="1.6" class="leaf2"/>` : sprout(x, y, k ? .55 : 1);
      }
    });
    return S(s + arr(104, 110, 112, 110, { c: "ag" }) + arr(209, 110, 217, 110, { c: "ag" }) + T(160, 186, "15 is the seed bed, not the farm", { c: "tm" }), "15 sprouts now, 50 later, 500 once automated");
  },

  hungry: () => S(
    T(160, 20, "Only filter: would you trust their work?", { b: 1 }) + G(168) +
    `<path d="M50 150q45 30 90 0z" class="trunk"/>` +
    [70, 95, 120].map((x, i) => `<circle cx="${x}" cy="${136 - (i === 1 ? 6 : 0)}" r="11" class="gold"/><path d="M${x - 4} ${124 - (i === 1 ? 6 : 0)}l4-10l4 10z" class="beak"/><circle cx="${x - 4}" cy="${134 - (i === 1 ? 6 : 0)}" r="1.6" class="ink"/>`).join("") +
    bubble(95, 58, 92, ["Pick me! I'm free", "this week!"]) +
    basket(240, 140, 70) + `<circle cx="240" cy="116" r="28" class="bird"/><circle cx="252" cy="108" r="2.5" class="ink"/><path d="M266 112l10 4l-10 3z" class="beak"/><path d="M225 100l-6-14l10 8z" class="apple"/>` +
    OT(95, 186, "Hungry: call first") + OT(240, 186, "Big and full: harder sell"),
    "Hungry chicks with open beaks get fed first; a big, full bird is a harder sell"),

  tractor: () => S(
    G(168) + bubble(222, 10, 160, ["\"Are you staying busy?\""]) +
    `<rect x="40" y="128" width="64" height="24" rx="3" class="soil2"/><path d="M104 140h14" class="rail"/>` + person(72, 130, "shirt2", .8) +
    `<rect x="118" y="112" width="96" height="36" rx="4" class="shirt1"/><rect x="176" y="72" width="44" height="42" rx="3" class="paper"/>` + person(198, 112, "shirt3", .8) +
    `<circle cx="198" cy="150" r="20" class="trunk"/><circle cx="198" cy="150" r="8" class="soil2"/><circle cx="136" cy="156" r="12" class="trunk"/><circle cx="136" cy="156" r="5" class="soil2"/>` +
    OT(198, 188, "You ask = you drive", { b: 1 }) + OT(72, 188, "They answer = they ride") + T(72, 92, "Contractor", { c: "tm" }),
    "You drive the tractor because you ask the questions; the contractor rides in the trailer"),

  fork: () => S(
    `<path d="M30 190C70 160 90 140 120 120C150 70 200 60 260 100M120 120C160 160 210 160 260 118" class="trail"/>` +
    `<path d="M240 136v-30l22-18l22 18v30z" class="barn"/><path d="M234 108l28-24l28 24" class="roofl"/><rect x="254" y="118" width="16" height="18" class="paper"/>` +
    T(36, 176, "\"Is this [Name]?\"", { a: "start", fs: 9 }) +
    T(150, 52, "BUSY", { b: 1, c: "good" }) + T(150, 64, "favorite work? free time?", { fs: 8.5 }) +
    T(176, 182, "NOT BUSY", { b: 1, c: "good" }) + T(176, 194, "can you fit these in?", { fs: 8.5 }) +
    T(262, 156, "The close", { b: 1 }) + T(262, 168, "\"give me your info\"", { fs: 8.5 }),
    "The call splits into a busy path and a not-busy path; both end at the same barn, the close", "meadow"),

  twenty: () => S(
    G(168) + basket(95, 140, 110) +
    [55, 75, 95, 115, 135].map((x, i) => `<circle cx="${x}" cy="${132}" r="9" class="${i === 2 ? "gold" : "apple"}"/>`).join("") +
    arr(95, 120, 95, 72, { c: "ag" }) + T(95, 52, "1 in 5 = your 20%", { b: 1 }) + T(95, 64, "4 in 5 = their job", { c: "tm", fs: 9 }) +
    `<path d="M245 168V110" class="stem"/><circle cx="245" cy="104" r="14" class="puff"/>` +
    [[268, 90, 290, 62], [262, 80, 270, 46], [258, 96, 304, 92]].map(([a, b, c, d]) => `<path d="M${a} ${b}L${c} ${d}" class="seedl"/><circle cx="${c}" cy="${d}" r="2.5" class="trunk"/>`).join("") +
    bubble(230, 8, 150, ["\"...or do you know someone", "else who could take them?\""], { tail: false }) +
    OT(95, 188, "Free money for them") + OT(245, 188, "A no still spreads seeds"),
    "A basket of five apples with one gold apple for your 20%; a dandelion blows seeds to other contractors"),

  gate: () => S(
    G(168) + `<path d="M10 168H150" class="trail2"/>` +
    `<rect x="40" y="110" width="6" height="58" class="trunk"/><rect x="104" y="110" width="6" height="58" class="trunk"/><path d="M46 118l-30 16M46 134l-30 16M16 134v16" class="rail"/>` +
    person(80, 166, "shirt3", .8) + arr(66, 150, 128, 150, { c: "ag" }) + OK(140, 104) +
    bubble(80, 18, 140, ["\"I charge 20% per lead.", "Go ahead and give me", "your name, email, phone.\""]) +
    `<rect x="190" y="110" width="6" height="58" class="trunk"/><rect x="290" y="110" width="6" height="58" class="trunk"/><path d="M196 122H290M196 140H290M196 158H290M220 122v36M245 122v36M270 122v36" class="rail"/>` +
    X(243, 96, 9) + bubble(243, 26, 130, ["\"Does 20% work", "for you?\""]) +
    OT(80, 188, "Walk them through") + OT(243, 188, "Room to say no"),
    "An open gate where you walk them through by asking for their info, next to a closed gate where asking for a yes lets them say no"),

  tone: () => S(
    G(168) + sun(60, 40) + `<path d="M230 36q10-14 24-6q14-8 22 6q10 2 8 12h-60q-4-10 6-12z" class="cloudf"/>` + [244, 258, 272].map(x => `<path d="M${x} 62q-4 6 0 12" class="breeze"/>`).join("") +
    person(60, 166, "shirt2") + person(260, 166, "shirt3") +
    bubble(118, 92, 96, ["STRONG,", "DIRECT"], { fs: 11, tx: -40 }) + bubble(200, 100, 86, ["kind, warm"], { fs: 9, tx: 40 }) +
    OT(60, 188, "Some want sun") + OT(260, 188, "Some want a breeze") + T(160, 152, "Match their weather", { b: 1 }),
    "Some people respond to a strong, sunny tone, others to a gentle breeze"),

  marker: () => S(
    G(150) + [150, 180, 210, 240, 270, 300].map(x => sprout(x, 150, 1.4)).join("") +
    `<rect x="70" y="120" width="5" height="50" class="trunk"/><rect x="20" y="92" width="106" height="32" rx="3" class="paper"/>` + T(73, 106, "20% per lead", { b: 1, fs: 12 }) + T(73, 119, "agreed today", { fs: 8, c: "tm" }) +
    `<rect x="160" y="12" width="148" height="78" rx="10" class="phone"/>` + bubble(234, 20, 136, ["Looking forward to sending", "you those jobs. As a reminder", "I take 20% per lead."], { tail: false, fs: 8.5 }) +
    T(234, 82, "sent right after the call", { fs: 8, c: "onsoil" }) + OT(160, 186, "Label the row the day you plant it"),
    "A garden label stake reading 20 percent per lead, next to the confirmation text on a phone"),

  revenue: () => {
    let s = T(160, 26, "$1,000 job (the whole harvest)", { b: 1 });
    for (let i = 0; i < 5; i++) s += `<rect x="${30 + i * 52}" y="38" width="50" height="34" rx="3" class="${i === 4 ? "gold" : "leaf2"}"/>`;
    s += T(108, 60, "$800 to the contractor", { c: "onsoil", fs: 10 }) + T(264, 60, "$200 you", { b: 1, fs: 10 });
    s += `<path d="M30 80h260" class="axis"/>` + T(30, 92, "$0", { a: "start", fs: 8, c: "tm" }) + T(290, 92, "$1,000", { a: "end", fs: 8, c: "tm" });
    s += G(150) + basket(70, 126, 80) + [50, 62, 74, 86].map(x => `<circle cx="${x}" cy="120" r="6" class="apple"/>`).join("") + `<circle cx="98" cy="120" r="6" class="gold"/>`;
    s += T(190, 124, "20% of the full price,", { a: "start", fs: 9.5 }) + T(190, 137, "not what's left after costs.", { a: "start", fs: 9.5 });
    s += OT(160, 178, "They build it into the quote.") + OT(160, 192, "Nobody argues over their costs.");
    return S(s, "A bar showing a $1,000 job split into $800 for the contractor and $200 (20%) for you");
  },

  owl: () => S(
    G(168) + house(50, 168) + truck(270, 168) +
    `<rect x="154" y="112" width="12" height="56" class="trunk"/><ellipse cx="160" cy="92" rx="18" ry="22" class="owl"/><circle cx="153" cy="86" r="5" class="paper"/><circle cx="167" cy="86" r="5" class="paper"/><circle cx="153" cy="86" r="2" class="ink"/><circle cx="167" cy="86" r="2" class="ink"/><path d="M157 94l3 4l3-4z" class="beak"/><path d="M146 72l4 8M174 72l-4 8" class="trunkl"/>` +
    arr(140, 96, 72, 128, { c: "ag", dash: 1 }) + arr(180, 96, 250, 128, { c: "ag", dash: 1 }) +
    bubble(70, 18, 110, ["\"What did you pay?\""], { tail: false }) + bubble(250, 18, 120, ["\"What did you charge?\""], { tail: false }) +
    OT(50, 186, "Homeowner") + OT(160, 186, "You see both sides") + OT(270, 186, "Contractor"),
    "An owl on a fence post watching both the homeowner's house and the contractor's truck"),

  lowfruit: () => S(
    G(168) + tree(200, 168, 1.9, { fruit: [[-24, 28, "gold", 5], [22, 30, "gold", 5], [2, -20, "apple", 4]] }) +
    person(92, 168, "shirt3") + `<path d="M98 146l50-8" class="arm"/>` +
    `<path d="M155 156l-18 10M246 158l20 6M204 54l46-26" class="lead"/>` +
    T(120, 182, "Mowing", { b: 1, c: "onsoil" }) + T(280, 182, "Christmas lights", { b: 1, c: "onsoil" }) + T(272, 20, "Kitchen remodel", { c: "tm" }) +
    T(60, 30, "Reach low first", { b: 1 }) + T(60, 43, "easy to sell,", { fs: 9, c: "tm" }) + T(60, 55, "lots of demand", { fs: 9, c: "tm" }),
    "A tree with low-hanging fruit labeled mowing and Christmas lights that you can reach, and a kitchen remodel high up"),

  beewasp: () => S(
    T(160, 20, "50 to 100 comments a day", { b: 1 }) +
    bubble(82, 34, 148, ["\"I recently had a very similar", "problem and the guy I had", "fix it did a very good job.", "I'd love to connect you.\""], { cls: "pgood", fs: 8.5 }) +
    `<ellipse cx="82" cy="136" rx="16" ry="11" class="gold"/><path d="M76 126v20M86 126v20" class="stripe"/><ellipse cx="78" cy="122" rx="8" ry="5" class="wing"/><ellipse cx="90" cy="122" rx="8" ry="5" class="wing"/><circle cx="98" cy="134" r="2" class="ink"/>` +
    bubble(240, 34, 140, ["\"HIRE MY COMPANY!", "Best price in town,", "call now!!\""], { cls: "pbad", fs: 8.5 }) +
    `<ellipse cx="240" cy="132" rx="18" ry="7" class="wasp"/><path d="M232 126v12M242 125v14M252 127v10" class="stripe"/><ellipse cx="236" cy="120" rx="7" ry="4" class="wing"/><path d="M222 132l-8 2" class="trunkl"/>` + X(268, 116, 8) +
    G(168) + OT(82, 186, "Neighbor: welcome") + OT(240, 186, "Pitch: banned"),
    "A bee leaving a helpful neighbor comment next to a wasp posting a sales pitch that gets banned"),

  weeding: () => S(
    G(168) + person(40, 168, "shirt1") + `<rect x="66" y="120" width="34" height="56" rx="5" class="phone"/>` + truck(150, 168) + arr(104, 140, 124, 140) +
    bubble(118, 10, 200, ["\"[Homeowner] will reach out soon about", "the job. Please keep me updated", "on the verdict.\""], { fs: 8.5, tx: 30 }) +
    `<path d="M230 168q-6-24 4-44" class="stem"/><circle cx="234" cy="122" r="5" class="wilt"/><path d="M230 168q-4 6-10 8M230 168q2 8 8 10" class="root" stroke-width="2"/>` + arr(246, 140, 272, 152, { c: "ag" }) + plant(292, 168, 36, "bloom") +
    OT(80, 188, "Hand it off") + OT(256, 188, "No updates? Replace them", { fs: 8.5 }),
    "You text the handoff to a contractor; a wilted plant that never updates you gets pulled and replaced"),

  spiderweb: () => {
    const cx = 160, cy = 100, sx = 1.55;
    let s = "";
    [30, 56, 84].forEach(r => { s += `<polygon points="${[0, 1, 2, 3, 4, 5].map(i => { const a = (i * 60 - 90) * Math.PI / 180; return `${(cx + Math.cos(a) * r * sx).toFixed(1)},${(cy + Math.sin(a) * r).toFixed(1)}`; }).join(" ")}" class="web"/>`; });
    const pos = r => [0, 1, 2, 3, 4, 5].map(i => { const a = (i * 60 - 90) * Math.PI / 180; return [cx + Math.cos(a) * r * sx, cy + Math.sin(a) * r]; });
    pos(84).forEach(([x, y]) => s += `<path d="M${cx} ${cy}L${x.toFixed(1)} ${y.toFixed(1)}" class="web"/>`);
    const P = pos(56), names = ["Roofer", "Plumber", "Lawn", "Painter", "HVAC", "Fence"];
    P.forEach(([x, y], i) => {
      const dx = x - cx, dy = y - cy, L = Math.hypot(dx, dy), ux = dx / L, uy = dy / L, nx = -uy * 5, ny = ux * 5;
      s += arr(cx + ux * 20 + nx, cy + uy * 20 + ny, x - ux * 18 + nx, y - uy * 18 + ny, { c: "ag" }) + arr(x - ux * 18 - nx, y - uy * 18 - ny, cx + ux * 20 - nx, cy + uy * 20 - ny);
    });
    [[0, 2], [1, 4], [3, 5]].forEach(([a, b]) => { const [x1, y1] = P[a], [x2, y2] = P[b]; s += arr(x1, y1, x2, y2, { c: "ab", q: [(x1 + x2) / 2 * .55 + cx * .45, (y1 + y2) / 2 * .55 + cy * .45], dash: 1 }); });
    P.forEach(([x, y], i) => s += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="15" class="node"/>` + T(x, y + 3.5, names[i], { fs: 7.5, b: 1 }));
    pos(84).forEach(([x, y], i) => s += `<circle cx="${(x + (i % 2 ? 8 : -8)).toFixed(1)}" cy="${y.toFixed(1)}" r="4" class="bloom"/><circle cx="${(x + (i % 2 ? -4 : 4)).toFixed(1)}" cy="${(y + 3).toFixed(1)}" r="3.5" class="bloom"/>`);
    s += `<circle cx="${cx}" cy="${cy}" r="19" class="gold"/>` + T(cx, cy + 4, "YOU", { b: 1, fs: 11 });
    s += `<circle cx="14" cy="182" r="4" class="bloom"/>` + T(22, 185, "Homeowners + friends", { a: "start", fs: 8 }) + `<path d="M190 182h16" class="ag"/>` + T(210, 185, "you send", { a: "start", fs: 8 }) + `<path d="M252 182h16" class="ar"/>` + T(272, 185, "sent back", { a: "start", fs: 8 });
    return S(s, "The spiderweb: you in the middle, contractors around you, leads flowing both ways and between contractors, homeowners and friends on the outer ring");
  },

  harvest: () => S(
    G(150) + plant(50, 150, 50, "bloom") + T(50, 82, "Bid won", { b: 1 }) + OT(50, 172, "not yet") +
    `<path d="M160 150V100" class="stem"/><ellipse cx="152" cy="126" rx="8" ry="4" class="leaf"/><circle cx="168" cy="108" r="9" class="apple"/>` + T(160, 82, "Job done", { b: 1 }) + OT(160, 172, "not yet") +
    basket(270, 126, 70) + [255, 270, 285].map(x => `<circle cx="${x}" cy="120" r="7" class="apple"/>`).join("") + `<circle cx="292" cy="104" r="11" class="gold"/>` + T(292, 108, "$", { b: 1, fs: 12 }) +
    T(270, 82, "Paid", { b: 1 }) + T(270, 172, "CLOSED", { b: 1, c: "onsoil" }) +
    arr(84, 120, 126, 120, { c: "ag" }) + arr(194, 120, 226, 120, { c: "ag" }) + OT(160, 192, "Proof: the payment screenshot"),
    "A flower (bid won), fruit on the plant (job done), and fruit in the basket with a dollar sign (paid, closed)"),

  ladder: () => S(
    G(168) + tree(262, 168, 1.8) +
    `<path d="M150 168L224 30M176 168L246 36" class="ladderl"/>` +
    [[158, 150], [176, 116], [196, 80]].map(([x, y], i) => `<path d="M${x} ${y}h${26 - i * 1.5}" class="ladderl"/><circle cx="${x - 14}" cy="${y}" r="8" class="gold"/>` + T(x - 14, y + 3.5, String(i + 1), { b: 1, fs: 9 })).join("") +
    T(10, 154, "Polite follow-up", { a: "start", b: 1, fs: 9.5 }) +
    T(10, 112, "Under contract;", { a: "start", b: 1, fs: 9.5 }) + T(10, 124, "court if needed", { a: "start", fs: 9 }) +
    T(10, 76, "More leads if", { a: "start", b: 1, fs: 9.5 }) + T(10, 88, "you pay", { a: "start", fs: 9 }) +
    T(10, 24, "Climb one rung at a time", { a: "start", c: "tm" }),
    "A three-rung ladder: polite follow-up, contract and court reminder, future leads depend on paying"),

  seeds: () => S(
    G(168) + plant(160, 168, 70, "bloom") +
    [[40, "Their next job"], [102, "Their neighbor"], [222, "Their friend"], [282, "Their family"]].map(([x, l], i) =>
      `<path d="M160 ${100}Q${(160 + x) / 2} ${70} ${x} ${150}" class="seedl" stroke-dasharray="3 3"/>` + sprout(x, 168, 1.6) + OT(x, 186, l, { fs: 8.5 })).join("") +
    bubble(160, 8, 220, ["\"If you ever want to be connected with", "anyone else for other jobs, I'd be happy to help.\""], { tail: false, fs: 8.5 }),
    "One healthy plant drops seeds that sprout into the homeowner's next job, neighbor, friend and family"),

  shake: () => S(
    G(168) + tree(210, 168, 1.9, { fruit: [[-30, 10], [20, -14], [34, 22], [-10, 26]] }) +
    person(140, 168, "shirt1") + `<path d="M146 146l52-6M146 152l52 0" class="arm"/>` +
    `<path d="M196 110l-6 4M196 120l-8 2M226 108l6 4M228 120l8 2" class="motion"/>` +
    [[170, 150], [250, 140], [262, 160]].map(([x, y]) => `<circle cx="${x}" cy="${y}" r="5" class="apple"/>`).join("") +
    bubble(90, 12, 160, ["\"Have you got anyone who", "needs gutters for me?\""], { tx: 40 }) +
    OT(160, 188, "Leads don't fall on their own. Ask, specifically, often."),
    "You shake an apple tree (a contractor) by asking for a specific trade, and leads fall"),

  trade: () => S(
    G(168) + person(56, 168, "shirt1") + truck(272, 168) + `<path d="M0 160q80-14 160 0t160 0" class="water"/>` +
    arr(80, 92, 240, 92, { c: "ag", q: [160, 52] }) + T(160, 56, "Jobs you send", { b: 1 }) +
    arr(240, 120, 80, 120, { q: [160, 148] }) + T(160, 128, "Leads they can't do", { b: 1 }) +
    OT(56, 188, "You") + OT(272, 188, "Contractor") + T(160, 22, "Part of the deal. You don't pay for leads back.", { c: "tm", fs: 9 }),
    "Water flows both ways: jobs go from you to the contractor and leads come back"),

  oak: () => {
    let s = G(150) + T(160, 18, "One anchor in every row (all 15 industries)", { b: 1 });
    ["Roofers", "Plumbers", "Painters", "HVAC", "+11 more"].forEach((n, i) => {
      const x = 34 + i * 63;
      s += (i < 4 ? tree(x, 150, .72, { roots: 1 }) : `<circle cx="${x}" cy="110" r="14" class="ghost"/>` + T(x, 114, "x11", { fs: 9, c: "tm" }));
      s += sprout(x - 20, 150) + sprout(x + 20, 150) + sprout(x - 12, 150, .8) + sprout(x + 12, 150, .8);
      s += OT(x, 188, n, { fs: 9, b: 1 });
    });
    return S(s, "Rows of small sprouts, each row with one deep-rooted oak: an anchor in every industry");
  },

  graft: () => S(
    G(168) + tree(130, 168, 1.7, { roots: 1 }) +
    `<path d="M168 92q30-10 52-34" class="trunkl" stroke-width="5"/><circle cx="226" cy="52" r="14" class="sky2"/><circle cx="242" cy="62" r="10" class="gold"/><rect x="176" y="84" width="10" height="8" rx="2" class="paper" transform="rotate(-20 181 88)"/>` +
    bubble(262, 88, 104, ["Your upsell:", "website, AI receptionist,", "booking, ads"], { tail: false, fs: 8.5 }) +
    T(10, 22, "Only graft onto a strong tree", { a: "start", b: 1 }) + OT(250, 188, "Your anchor: deep roots"),
    "A new branch (your upsell) grafted onto a strong, deep-rooted tree"),

  prune: () => {
    const shears = (x, y) => `<path d="M${x} ${y}l20-10M${x} ${y}l20 10" class="shear"/><circle cx="${x - 5}" cy="${y - 4}" r="4" class="shearo"/><circle cx="${x - 5}" cy="${y + 4}" r="4" class="shearo"/>`;
    return S(
      G(168) + tree(80, 168, 1.8) + shears(118, 88) + OK(36, 40) +
      `<path d="M240 168q-2-40 2-70" class="stem" stroke-width="3"/><ellipse cx="236" cy="100" rx="8" ry="4" class="leaf"/><ellipse cx="248" cy="88" rx="8" ry="4" class="leaf"/>` + shears(258, 110) + X(286, 64, 9) +
      bubble(160, 8, 150, ["\"Upgrade with us or we can't", "keep sending you jobs.\""], { tail: false, fs: 8.5 }) +
      OT(80, 186, "True anchor: survives it") + OT(244, 186, "Not yet: you lose them"),
      "A strong tree survives hard pruning; a sapling does not. The leverage line only works on a true anchor");
  },

  receipt: () => S(
    G(168) + basket(130, 132, 120) + [92, 110, 128, 146, 164].map((x, i) => `<circle cx="${x}" cy="${124 - (i % 2) * 6}" r="9" class="${i % 2 ? "gold" : "apple"}"/>`).join("") +
    `<path d="M186 140l26-20" class="tag"/><rect x="206" y="64" width="104" height="66" rx="6" class="paper" transform="rotate(4 258 97)"/>` +
    T(258, 86, "Invoice or payment", { b: 1, fs: 9.5 }) + T(258, 100, "+", { fs: 10 }) + T(258, 114, "Service agreement", { b: 1, fs: 9.5 }) + OK(296, 66) +
    OT(160, 188, "They bought it. In writing."),
    "A full basket with a tag: invoice or payment plus service agreement"),

  stand: () => S(
    G(168) + house(40, 168) + truck(282, 168) +
    `<rect x="126" y="112" width="68" height="40" class="soil2"/><path d="M118 112h84l-8-24h-68z" class="awning"/><path d="M137 88l-4 24M151 88l-2 24M165 88v24M179 88l2 24M193 88l4 24" class="awnl"/>` + person(160, 112, "shirt1", .7) +
    arr(62, 140, 120, 140, { c: "ag" }) + T(90, 132, "pays you", { fs: 8.5 }) + arr(200, 140, 252, 140) + T(226, 132, "you pay", { fs: 8.5 }) +
    `<rect x="234" y="40" width="72" height="44" rx="4" class="paper"/>` + T(270, 54, "Quote A $900", { fs: 8 }) + T(270, 66, "Quote B $1,100", { fs: 8 }) + T(270, 78, "Quote C $1,000", { fs: 8 }) +
    `<rect x="12" y="30" width="134" height="38" rx="4" class="paper pbad"/>` + T(79, 46, "Licensed trade?", { b: 1, fs: 9.5, c: "bad" }) + T(79, 60, "Check the rules first.", { fs: 9 }) +
    OT(40, 186, "Homeowner") + OT(160, 186, "Your stand (late game)") + OT(282, 186, "Contractor"),
    "Your own farm stand: the homeowner pays you, you pay the contractor after comparing quotes, with a licensing warning sign"),

  pots: () => S(
    G(168) + T(160, 20, "Where will you be in 5 years if nothing changes?", { b: 1, fs: 10 }) +
    `<path d="M50 168l-8-40h56l-8 40z" class="pot"/>` + sprout(70, 128, 1.3) + T(70, 112, "Same pot", { c: "tm" }) +
    plant(210, 168, 90, "gold") + plant(244, 168, 70, "bloom") + plant(276, 168, 100, "sky2") +
    OT(70, 188, "Stays small") + OT(244, 188, "Room to spread out"),
    "A seedling stuck in a small pot next to plants growing tall in an open field"),

  introgate: () => S(
    G(168) + `<path d="M0 182H320" class="trail2"/>` + person(46, 168, "shirt1") + person(84, 168, "shirt2") + arr(104, 150, 186, 150, { c: "ag" }) +
    `<rect x="208" y="104" width="7" height="64" class="trunk"/><rect x="296" y="104" width="7" height="64" class="trunk"/><path d="M215 112H296" class="rail"/>` + `<rect x="226" y="90" width="58" height="20" rx="3" class="paper"/>` + T(255, 104, "The farm", { b: 1, fs: 9 }) +
    person(256, 168, "shirt3") + bubble(256, 30, 100, ["Alex gives", "the tour"]) +
    bubble(65, 34, 108, ["\"Want to work with", "me? Come meet Alex.\""]) +
    OT(65, 194, "You + a friend") + OT(256, 194, "Alex pitches"),
    "You walk a friend to the farm gate, where Alex gives the tour and makes the pitch"),

  roots: () => S(
    G(168) + tree(120, 168, 1.6, { roots: 1, fruit: [[-24, 4], [10, -16], [26, 14], [-6, 24], [32, -6]] }) +
    plant(258, 168, 34, "gold") + T(258, 120, "$250 bonus", { b: 1 }) + T(258, 132, "optional", { c: "tm", fs: 9 }) +
    T(120, 18, "Main income: contractor fees", { b: 1 }) + T(120, 30, "on real jobs", { c: "tm", fs: 9 }) +
    OT(252, 190, "One level only. No chains.", { fs: 8.5 }),
    "A fruit tree whose fruit is contractor fees on real jobs, with a small flower beside it for the optional $250 bonus")
};
if (typeof module !== "undefined") module.exports = { DIAGRAMS };
