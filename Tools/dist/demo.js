// Typing demo for the download page: the same keys typed with Korean input left on (left pane)
// and with Duo (right pane), with a keyboard and two hands below. The frames come from the real
// engine (Tools/dist/demo-frames.json, written by DemoFramesTests); this file only plays them.
(() => {
  const NS = "http://www.w3.org/2000/svg";
  const $ = (id) => document.getElementById(id);
  const META = {
    mix: { tab: "한국어 사이에 영어", caption: "한/영 키를 한 번도 누르지 않았는데 meeting이 그대로 나와요." },
    dev: { tab: "영어 뒤에 조사", caption: "PR을, CI가처럼 영어 뒤에 붙는 조사도 그대로 이어져요." },
    flip: {
      tab: "둘 다 말이 될 때",
      caption: "go와 해는 둘 다 말이 돼서 뜻에 따라 갈려요. 오른쪽 ⌘를 톡 누르면 바로 바뀌어요.",
      noteKo: "보통은 지우고 → 한/영 키 → 다시 쳐야 해요",
      noteDuo: "오른쪽 ⌘ 한 번: 해 → go",
      good: "✓ 오른쪽 ⌘ 한 번으로 고침",
    },
  };
  const scenes = JSON.parse($("demo-frames").textContent).filter((s) => META[s.id]);
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // MARK: keyboard

  const U = 64;
  const PAD = 4;
  const ROWS = [
    "` 1 2 3 4 5 6 7 8 9 0 - = delete:1.5",
    "tab:1.5 q w e r t y u i o p [ ] \\",
    "caps:1.75 a s d f g h j k l ; ' return:1.75",
    "lshift:2.25 z x c v b n m , . / rshift:2.25",
    "fn control option lcmd:1.25 space:5 rcmd:1.25 roption left updown right",
  ];
  const JAMO = {
    q: "ㅂ", w: "ㅈ", e: "ㄷ", r: "ㄱ", t: "ㅅ", y: "ㅛ", u: "ㅕ", i: "ㅑ", o: "ㅐ", p: "ㅔ",
    a: "ㅁ", s: "ㄴ", d: "ㅇ", f: "ㄹ", g: "ㅎ", h: "ㅗ", j: "ㅓ", k: "ㅏ", l: "ㅣ",
    z: "ㅋ", x: "ㅌ", c: "ㅊ", v: "ㅍ", b: "ㅠ", n: "ㅜ", m: "ㅡ",
  };
  const SHIFTED = {
    "`": "~", 1: "!", 2: "@", 3: "#", 4: "$", 5: "%", 6: "^", 7: "&", 8: "*", 9: "(", 0: ")",
    "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
  };
  const MODS = {
    delete: ["delete", "", true], tab: ["tab", ""], caps: ["caps lock", ""], return: ["return", "", true],
    lshift: ["shift", "⇧"], rshift: ["shift", "⇧", true], fn: ["fn", ""], control: ["control", "⌃"],
    option: ["option", "⌥"], roption: ["option", "⌥", true], lcmd: ["command", "⌘"], rcmd: ["command", "⌘", true],
    left: ["", "◀"], updown: ["", "▲▼"], right: ["", "▶"], space: ["", ""],
  };
  const FINGER_KEYS = {
    L5: "` 1 tab q caps a lshift z fn control", L4: "2 w s x option", L3: "3 e d c", L2: "4 5 r t f g v b",
    R2: "6 7 y u h j n m", R3: "8 i k ,", R4: "9 o l .", R5: "0 - = delete p [ ] \\ ; ' return / rshift",
    L1: "lcmd", R1: "space rcmd roption",
  };
  const FINGER_OF = {};
  for (const [finger, list] of Object.entries(FINGER_KEYS)) for (const id of list.split(" ")) FINGER_OF[id] = finger;

  const svg = $("kb");
  const el = (name, attrs = {}, parent) => {
    const node = document.createElementNS(NS, name);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    if (parent) parent.append(node);
    return node;
  };
  const text = (parent, cls, x, y, value, anchor = "start") => {
    const t = el("text", { class: cls, x, y, "text-anchor": anchor }, parent);
    t.textContent = value;
  };

  const defs = el("defs", {}, svg);
  const fade = el("linearGradient", { id: "kb-fade", x1: 0, y1: 300, x2: 0, y2: 420, gradientUnits: "userSpaceOnUse" }, defs);
  el("stop", { offset: 0, "stop-color": "#fff" }, fade);
  el("stop", { offset: 1, "stop-color": "#000" }, fade);
  const mask = el("mask", { id: "kb-mask", maskUnits: "userSpaceOnUse", x: -40, y: -40, width: 1020, height: 480 }, defs);
  el("rect", { x: -40, y: -40, width: 1020, height: 480, fill: "url(#kb-fade)" }, mask);

  el("rect", { class: "base", x: -14, y: -14, width: 956, height: 348, rx: 24 }, svg);
  const keyLayer = el("g", {}, svg);
  const handLayer = el("g", { mask: "url(#kb-mask)" }, svg);
  const ringLayer = el("g", {}, svg);

  const keys = {};
  ROWS.forEach((row, r) => {
    let x = 0;
    for (const spec of row.split(" ")) {
      const [id, w = "1"] = spec.split(":");
      const width = parseFloat(w) * U;
      const y = r * U;
      const g = el("g", { class: "k" }, keyLayer);
      el("rect", { class: "cap", x: x + PAD, y: y + PAD, width: width - 2 * PAD, height: U - 2 * PAD, rx: 9 }, g);
      const left = x + PAD + 10;
      const right = x + width - PAD - 10;
      if (JAMO[id]) {
        text(g, "l", left, y + PAD + 22, id.toUpperCase());
        text(g, "j", right, y + U - PAD - 10, JAMO[id], "end");
      } else if (SHIFTED[id] !== undefined) {
        text(g, "s", x + width / 2, y + PAD + 20, SHIFTED[id], "middle");
        text(g, "l", x + width / 2, y + U - PAD - 12, id, "middle");
      } else if (MODS[id]) {
        const [word, symbol, alignRight] = MODS[id];
        if (word) text(g, "m", alignRight ? right : left, y + U - PAD - 10, word, alignRight ? "end" : "start");
        if (symbol) {
          if (word) text(g, "s", alignRight ? left : right, y + PAD + 19, symbol, alignRight ? "start" : "end");
          else text(g, "s", x + width / 2, y + U / 2 + 5, symbol, "middle");
        }
      }
      const ring = el("rect", { class: "ring", x: x + PAD - 2, y: y + PAD - 2, width: width - 2 * PAD + 4, height: U - 2 * PAD + 4, rx: 11 }, ringLayer);
      keys[id] = { g, ring, cx: x + width / 2, cy: y + U / 2, x, y, w: width };
      x += width;
    }
  });

  const callout = el("g", { class: "callout" }, ringLayer);
  {
    const k = keys.rcmd;
    el("rect", { x: k.cx - 66, y: k.y - 44, width: 132, height: 34, rx: 17 }, callout);
    el("path", { d: `M ${k.cx - 8} ${k.y - 11} L ${k.cx} ${k.y - 1} L ${k.cx + 8} ${k.y - 11} Z` }, callout);
    text(callout, "", k.cx, k.y - 21, "오른쪽 ⌘ 톡!", "middle");
  }

  // MARK: hands

  const FINGERS = {
    L5: { home: "a", len: 96, w: 29 }, L4: { home: "s", len: 114, w: 33 }, L3: { home: "d", len: 122, w: 35 },
    L2: { home: "f", len: 112, w: 35 }, R2: { home: "j", len: 112, w: 35 }, R3: { home: "k", len: 122, w: 35 },
    R4: { home: "l", len: 114, w: 33 }, R5: { home: ";", len: 96, w: 29 }, L1: { w: 40 }, R1: { w: 40 },
  };
  const hands = { L: { off: { x: 0, y: 0 }, fingers: [] }, R: { off: { x: 0, y: 0 }, fingers: [] } };
  for (const side of ["L", "R"]) {
    const hand = hands[side];
    const order = side === "L" ? ["L5", "L4", "L3", "L2"] : ["R2", "R3", "R4", "R5"];
    const centerX = order.reduce((sum, f) => sum + keys[FINGERS[f].home].cx, 0) / 4 + (side === "L" ? 14 : -14);
    for (const name of order) {
      const f = FINGERS[name];
      const tip = { x: keys[f.home].cx, y: keys[f.home].cy };
      f.homeTip = tip;
      f.base = { x: tip.x + (centerX - tip.x) * 0.08, y: tip.y + f.len };
    }
    const index = FINGERS[side === "L" ? "L2" : "R2"];
    const thumb = FINGERS[side + "1"];
    const inward = side === "L" ? 1 : -1;
    thumb.base = { x: index.base.x + 2 * inward, y: index.base.y + 86 };
    thumb.homeTip = { x: side === "L" ? keys.f.cx + 54 : keys.j.cx - 54, y: keys.space.cy + 4 };
    hand.palmOrder = side === "L" ? [...order, "L1"] : [...order].reverse().concat("R1");
    const pinky = FINGERS[order[side === "L" ? 0 : 3]];
    hand.wrist = [
      { x: thumb.base.x - 12 * inward, y: thumb.base.y + 80 },
      { x: pinky.base.x + 4 * inward, y: pinky.base.y + 150 },
    ];
    hand.fingerNames = [...order, side + "1"];

    const g = el("g", { class: "hand" }, handLayer);
    const outline = el("g", { class: "outline" }, g);
    const fill = el("g", { class: "fill" }, g);
    const nails = el("g", {}, g);
    hand.palm = [
      el("path", { "stroke-width": 32, "stroke-linejoin": "round" }, outline),
      el("path", { "stroke-width": 26, "stroke-linejoin": "round" }, fill),
    ];
    for (const name of hand.fingerNames) {
      const f = FINGERS[name];
      f.name = name;
      f.pos = { ...f.homeTip };
      f.target = { ...f.homeTip };
      f.lines = [
        el("line", { "stroke-width": f.w + 5, "stroke-linecap": "round" }, outline),
        el("line", { "stroke-width": f.w, "stroke-linecap": "round" }, fill),
      ];
      f.nail = el("ellipse", { class: "nail", rx: f.w * 0.26, ry: f.w * 0.33 }, nails);
      hand.fingers.push(f);
    }
  }

  function drawHands() {
    for (const hand of Object.values(hands)) {
      const off = hand.off;
      const points = hand.palmOrder.map((n) => ({ x: FINGERS[n].base.x + off.x, y: FINGERS[n].base.y + off.y }))
        .concat(hand.wrist.map((p) => ({ x: p.x + off.x, y: p.y + off.y })));
      const d = "M " + points.map((p) => `${p.x.toFixed(1)} ${p.y.toFixed(1)}`).join(" L ") + " Z";
      for (const path of hand.palm) path.setAttribute("d", d);
      for (const f of hand.fingers) {
        const bx = f.base.x + off.x;
        const by = f.base.y + off.y;
        for (const line of f.lines) {
          line.setAttribute("x1", bx.toFixed(1));
          line.setAttribute("y1", by.toFixed(1));
          line.setAttribute("x2", f.pos.x.toFixed(1));
          line.setAttribute("y2", f.pos.y.toFixed(1));
        }
        const dx = bx - f.pos.x;
        const dy = by - f.pos.y;
        const len = Math.hypot(dx, dy) || 1;
        const nx = f.pos.x + (dx / len) * f.w * 0.2;
        const ny = f.pos.y + (dy / len) * f.w * 0.2;
        const angle = (Math.atan2(dy, dx) * 180) / Math.PI - 90;
        f.nail.setAttribute("cx", nx.toFixed(1));
        f.nail.setAttribute("cy", ny.toFixed(1));
        f.nail.setAttribute("transform", `rotate(${angle.toFixed(1)} ${nx.toFixed(1)} ${ny.toFixed(1)})`);
      }
    }
  }

  let lastTime = 0;
  function step(time) {
    const dt = Math.min(64, time - (lastTime || time));
    lastTime = time;
    const a = 1 - Math.exp(-dt / 30);
    for (const hand of Object.values(hands)) {
      let sx = 0;
      let sy = 0;
      for (const f of hand.fingers) {
        f.pos.x += (f.target.x - f.pos.x) * a;
        f.pos.y += (f.target.y - f.pos.y) * a;
        if (!f.name.endsWith("1")) {
          sx += f.pos.x - f.homeTip.x;
          sy += f.pos.y - f.homeTip.y;
        }
      }
      hand.off.x += (sx * 0.2 - hand.off.x) * a * 0.5;
      hand.off.y += (sy * 0.2 - hand.off.y) * a * 0.5;
    }
    drawHands();
    requestAnimationFrame(step);
  }

  // MARK: keys pressed for a token

  function pressesFor(token) {
    if (token === " ") return [{ key: "space", finger: "R1" }];
    if (token === "{rcmd}") return [{ key: "rcmd", finger: "R1" }];
    let base = token;
    let shift = false;
    const shiftedBase = Object.keys(SHIFTED).find((k) => SHIFTED[k] === token);
    if (shiftedBase !== undefined) {
      base = shiftedBase;
      shift = true;
    } else if (token !== token.toLowerCase()) {
      base = token.toLowerCase();
      shift = true;
    }
    const finger = FINGER_OF[base];
    if (!finger) return [];
    const list = [{ key: base, finger }];
    if (shift) list.push(finger[0] === "L" ? { key: "rshift", finger: "R5" } : { key: "lshift", finger: "L5" });
    return list;
  }
  const moveTo = (p) => { FINGERS[p.finger].target = { x: keys[p.key].cx, y: keys[p.key].cy }; };
  const goHome = (p) => { FINGERS[p.finger].target = { ...FINGERS[p.finger].homeTip }; };
  const keyDown = (p) => {
    keys[p.key].g.classList.add("down");
    keys[p.key].ring.classList.add("on");
  };
  const keyUp = (p) => {
    keys[p.key].g.classList.remove("down");
    keys[p.key].ring.classList.remove("on");
  };
  function releaseAll() {
    for (const k of Object.values(keys)) {
      k.g.classList.remove("down");
      k.ring.classList.remove("on");
    }
    for (const f of Object.values(FINGERS)) f.target = { ...f.homeTip };
    callout.classList.remove("on");
  }

  // MARK: panes

  const span = (cls, value) => {
    const s = document.createElement("span");
    if (cls) s.className = cls;
    s.textContent = value;
    return s;
  };
  function chip(hud) {
    const c = span("chip", "");
    hud.readings.forEach((reading, i) => {
      const r = span(`r ${reading.lang}${i === hud.selected ? " sel" : ""}`, "");
      r.append(span(`lb ${reading.lang}`, reading.lang === "en" ? "A" : "한"), reading.text);
      c.append(r);
    });
    c.append(span("kc", "오른쪽 ⌘"));
    return c;
  }
  // Words are compared by position: both panes typed the same keys, so their spaces line up.
  function paint(target, committed, marked, other, mark, hud) {
    target.textContent = "";
    const words = committed.split(" ");
    words.forEach((word, i) => {
      if (i > 0) target.append(" ");
      if (!word) return;
      const complete = mark.final || i < words.length - 1;
      const differs = other[i] !== undefined && other[i] !== word;
      target.append(span(complete && differs && mark.cls ? mark.cls : "", word));
    });
    if (marked) {
      const m = span("marked", marked);
      if (hud) m.append(chip(hud));
      target.append(m);
    }
    if (!mark.final) target.append(span("caret", ""));
  }
  function render(scene, k, final = false) {
    const f = k >= 0 ? scene.frames[k] : { duo: "", duoMarked: "", ko: "", koMarked: "" };
    const duoWords = (f.duo + f.duoMarked).split(" ");
    const koWords = (f.ko + f.koMarked).split(" ");
    paint($("text-ko"), f.ko, f.koMarked, duoWords, { cls: "wrong", final });
    paint($("text-duo"), f.duo, f.duoMarked, koWords, { cls: final ? "right" : "", final }, f.hud);
    const keysEl = $("keys");
    keysEl.textContent = "";
    const shown = scene.tokens.slice(0, k + 1);
    const start = Math.max(0, shown.length - 34);
    if (start > 0) keysEl.append("…");
    shown.slice(start).forEach((t, i) => {
      const now = start + i === k && !final;
      if (t === "{rcmd}") keysEl.append(span(now ? "cmdk now" : "cmdk", "오른쪽 ⌘"));
      else keysEl.append(span(now ? "now" : "", now && t === " " ? "␣" : t));
    });
  }
  function setNotes(meta, on) {
    $("note-ko").textContent = meta.noteKo || "";
    $("note-duo").textContent = meta.noteDuo || "";
    $("note-ko").classList.toggle("on", on && !!meta.noteKo);
    $("note-duo").classList.toggle("on", on && !!meta.noteDuo);
  }
  function setVerdicts(scene, on) {
    const meta = META[scene.id];
    $("verdict-ko").textContent = "✗ 지우고 다시 쳐야 해요";
    $("verdict-duo").textContent = meta.good || "✓ 뜻한 대로";
    $("verdict-ko").classList.toggle("on", on);
    $("verdict-duo").classList.toggle("on", on);
  }

  // MARK: tabs and playback

  const tabs = scenes.map((scene, i) => {
    const b = document.createElement("button");
    b.type = "button";
    b.setAttribute("role", "tab");
    b.textContent = META[scene.id].tab;
    b.addEventListener("click", () => start(i));
    $("demo-tabs").append(b);
    return b;
  });
  function select(i) {
    tabs.forEach((b, j) => b.setAttribute("aria-selected", String(i === j)));
    const scene = scenes[i];
    $("caption").textContent = META[scene.id].caption;
    const last = scene.frames[scene.frames.length - 1];
    $("demo").setAttribute("aria-description",
      `${scene.tokens.join("").replace("{rcmd}", " (오른쪽 ⌘) ")}를 치면 한글 모드는 ${last.ko}, Duo는 ${last.duo}`);
  }

  const CANCEL = Symbol("cancel");
  let runId = 0;
  let visible = true;
  let wakers = [];
  async function wait(ms, id) {
    await new Promise((resolve) => setTimeout(resolve, ms));
    while (!visible && id === runId) await new Promise((resolve) => wakers.push(resolve));
    if (id !== runId) throw CANCEL;
  }
  const jitter = (base, spread) => base + Math.random() * spread;

  async function play(i, id) {
    const scene = scenes[i];
    const meta = META[scene.id];
    select(i);
    releaseAll();
    setVerdicts(scene, false);
    setNotes(meta, false);
    render(scene, -1);
    await wait(700, id);
    for (let k = 0; k < scene.tokens.length; k++) {
      const token = scene.tokens[k];
      const isFlip = token === "{rcmd}";
      if (isFlip) await wait(800, id);
      const presses = pressesFor(token);
      presses.forEach(moveTo);
      await wait(isFlip ? 160 : 75, id);
      presses.forEach(keyDown);
      render(scene, k);
      if (isFlip) {
        callout.classList.add("on");
        setNotes(meta, true);
      }
      await wait(isFlip ? 320 : 85, id);
      presses.forEach(keyUp);
      presses.forEach(goHome);
      if (isFlip) {
        await wait(1300, id);
        callout.classList.remove("on");
      }
      await wait(token === " " ? jitter(120, 60) : jitter(25, 70), id);
    }
    render(scene, scene.tokens.length - 1, true);
    setVerdicts(scene, true);
    await wait(3600, id);
  }

  async function start(i) {
    const id = ++runId;
    wakers.splice(0).forEach((wake) => wake());
    if (reduceMotion) {
      const scene = scenes[i];
      select(i);
      releaseAll();
      render(scene, scene.tokens.length - 1, true);
      setVerdicts(scene, true);
      setNotes(META[scene.id], true);
      return;
    }
    try {
      for (let n = i; ; n = (n + 1) % scenes.length) await play(n, id);
    } catch (e) {
      if (e !== CANCEL) throw e;
    }
  }

  // ?demo=<scene>.<frame> holds one frame still (for screenshots).
  function still(spec) {
    const [i, k] = spec.split(".").map(Number);
    const scene = scenes[i];
    if (!scene) return false;
    select(i);
    const frame = Math.min(k, scene.tokens.length - 1);
    const final = k >= scene.tokens.length;
    render(scene, frame, final);
    setVerdicts(scene, final);
    const presses = final ? [] : pressesFor(scene.tokens[frame]);
    presses.forEach((p) => { moveTo(p); keyDown(p); });
    for (const f of Object.values(FINGERS)) f.pos = { ...f.target };
    if (scene.tokens[frame] === "{rcmd}" && !final) {
      callout.classList.add("on");
      setNotes(META[scene.id], true);
    }
    return true;
  }

  new IntersectionObserver((entries) => {
    visible = entries.some((e) => e.isIntersecting) && !document.hidden;
    if (visible) wakers.splice(0).forEach((wake) => wake());
  }).observe($("demo"));
  document.addEventListener("visibilitychange", () => {
    visible = !document.hidden;
    if (visible) wakers.splice(0).forEach((wake) => wake());
  });

  const stillSpec = new URLSearchParams(location.search).get("demo");
  if (stillSpec && still(stillSpec)) {
    for (const hand of Object.values(hands)) {
      let sx = 0;
      let sy = 0;
      for (const f of hand.fingers) if (!f.name.endsWith("1")) { sx += f.pos.x - f.homeTip.x; sy += f.pos.y - f.homeTip.y; }
      hand.off = { x: sx * 0.2, y: sy * 0.2 };
    }
    drawHands();
  } else {
    drawHands();
    if (!reduceMotion) requestAnimationFrame(step);
    start(0);
  }
})();
