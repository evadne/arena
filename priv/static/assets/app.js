import { Socket } from "./phoenix.mjs";
import { SnapshotBuffer, mergeSnapshotMap, interpolateActor } from "./snapshot_buffer.mjs";

import { FrameDecoder } from "./frame_decoder.mjs";

const snapshots = new SnapshotBuffer();
const frames = new FrameDecoder();
let frameResyncPending = false;

const $ = (id) => document.getElementById(id);
const state = {
  socket: null,
  channel: null,
  userId: null,
  lobby: null,
  game: null,
  fogCells: [],
  connected: false,
  joining: false,
  keys: new Set(),
  shoot: false,
  reload: false,
  aim: 0,
  mouse: null,
  scheme: readStorage("breach-scheme", "wasd"),
  muted: readStorage("breach-muted", "false") === "true",
  sound: null,
  shots: new Map(),
  lastAmmo: null,
  audioEvents: new Set(),
  volume: Number(readStorage("breach-volume", "0.5")),
};
const canvas = $("game-canvas"),
  ctx = canvas.getContext("2d");
let view = { scale: 1, x: 0, y: 0, width: 0, height: 0 },
  noticeTimer;
function readStorage(key, fallback) {
  try {
    return localStorage.getItem(key) || fallback;
  } catch {
    return fallback;
  }
}
function saveStorage(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {}
}
$("player-name").value = readStorage("breach-name", "");
$("control-scheme").value = state.scheme;
const incomingCode = new URL(location.href).searchParams.get("lobby");
if (incomingCode)
  $("lobby-code").value = incomingCode
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "")
    .slice(0, 12);
function notify(message, error = false) {
  clearTimeout(noticeTimer);
  $("notice").textContent = message;
  $("notice").classList.toggle("error", error);
  $("notice").hidden = false;
  noticeTimer = setTimeout(() => {
    $("notice").hidden = true;
  }, 7000);
}
function friendly(reason) {
  return String(reason || "Unable to complete the request.")
    .replace(/_/g, " ")
    .replace(/^./, (c) => c.toUpperCase());
}
function action(event, payload = {}, callback) {
  if (!state.channel || !state.connected)
    return notify("Connect to an operation first.", true);
  state.channel
    .push(event, payload, 5000)
    .receive("ok", (reply) => callback?.(reply))
    .receive("error", (reply) => notify(friendly(reply.reason), true))
    .receive("timeout", () =>
      notify("The server is taking a little longer. Please try again.", true),
    );
}
function setConnection(connected, label) {
  state.connected = connected;
  $("connection").classList.toggle("online", connected);
  $("connection").innerHTML = "";
  const dot = document.createElement("i");
  $("connection").append(
    dot,
    document.createTextNode(label || (connected ? "CONNECTED" : "OFFLINE")),
  );
  if (!connected) releaseInput();
  updateUI();
}
function join(code) {
  if (state.joining) return;
  code = code.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (!/^[A-Z0-9]{4,12}$/.test(code))
    return notify("Use an operation code of 4–12 letters or numbers.", true);
  let name = $("player-name").value.trim() || "Operator";
  name = name.slice(0, 20);
  saveStorage("breach-name", name);
  $("player-name").value = name;
  state.joining = true;
  disconnect(false);
  setConnection(false, "CONNECTING");
  state.joining = true;
  const socket = new Socket("/socket", { params: {} });
  state.socket = socket;
  socket.onError(() => {
    if (state.socket === socket) setConnection(false, "RECONNECTING");
  });
  socket.onClose(() => {
    if (state.socket === socket) setConnection(false, "RECONNECTING");
  });
  socket.connect();
  const channel = socket.channel(`lobby:${code}`, { name, protocol: 3 });
  state.channel = channel;
  channel.on("lobby", (lobby) => {
    state.lobby = lobby;
    if (lobby.status === "waiting") {
      state.game = null;
      frames.reset();
      frameResyncPending = false;
      snapshots.clear();
      state.shots.clear();
    }
    renderRoster();
    updateUI();
  });
  channel.on("snapshot", receiveSnapshot);
  channel.on("frame", (frame) => {
    if (state.channel !== channel) return;
    const result = frames.apply(frame);
    if (result.status === "applied") {
      frameResyncPending = false;
      receiveSnapshot(result.snapshot);
      channel.push("frame_ack", { seq: result.seq });
    } else if (result.status === "resync" && !frameResyncPending) {
      frameResyncPending = true;
      channel.push("frame_resync", {});
    }
  });
  channel.on("chat", addChat);
  channel.onError(() => {
    if (state.channel === channel) setConnection(false, "RECONNECTING");
  });
  channel.onClose(() => {
    if (state.channel === channel) setConnection(false, "DISCONNECTED");
  });
  channel
    .join(8000)
    .receive("ok", (reply) => {
      if (state.channel !== channel) return;
      state.joining = false;
      state.userId = reply.user_id;
      state.lobby = reply.lobby;
      state.game = null;
      frames.reset();
      frameResyncPending = false;
      snapshots.clear();
      state.shots.clear();
      state.lastAmmo = null;
      state.audioEvents.clear();
      if (reply.game) receiveSnapshot(reply.game);
      setConnection(true);
      renderRoster();
      $("chat-log").replaceChildren();
      (reply.lobby.chat || []).forEach(addChat);
      if (!(reply.lobby.chat || []).length)
        addSystem("Secure frequency established. Your squad is listening.");
      const url = new URL(location.href);
      url.searchParams.set("lobby", reply.lobby.code);
      history.replaceState({}, "", url);
      notify(
        "Operation connected. Share the invite link to assemble your squad.",
      );
    })
    .receive("error", (reply) => {
      state.joining = false;
      disconnect();
      notify(friendly(reply.reason), true);
    })
    .receive("timeout", () => {
      state.joining = false;
      disconnect();
      notify("Could not reach the operation. Please try again.", true);
    });
}
function disconnect(clearUrl = true) {
  releaseInput();
  const oldChannel = state.channel,
    oldSocket = state.socket;
  state.channel = null;
  state.socket = null;
  oldChannel?.leave();
  oldSocket?.disconnect();
  state.userId = null;
  state.lobby = null;
  state.game = null;
  frames.reset();
  frameResyncPending = false;
  snapshots.clear();
  state.connected = false;
  state.joining = false;
  state.shots.clear();
  if (clearUrl) {
    const url = new URL(location.href);
    url.searchParams.delete("lobby");
    history.replaceState({}, "", url);
  }
  $("chat-log").replaceChildren();
  const empty = document.createElement("div");
  empty.className = "chat-empty";
  empty.textContent =
    "Your private squad frequency. Connect to an operation to talk.";
  $("chat-log").append(empty);
  setConnection(false);
  renderRoster();
}
$("create-lobby").addEventListener("click", () => {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const random = crypto.getRandomValues(new Uint8Array(6));
  join(Array.from(random, (n) => alphabet[n % alphabet.length]).join(""));
});
$("join-form").addEventListener("submit", (e) => {
  e.preventDefault();
  join($("lobby-code").value);
});
$("leave-lobby").addEventListener("click", () => disconnect());
$("copy-invite").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(location.href);
    notify("Invite link copied. Send it to your squad.");
  } catch {
    notify(`Invite code: ${state.lobby?.code}. Share this page’s address.`);
  }
});
$("start-game").addEventListener("click", () => {
  $("notice").hidden = true;
  clearTimeout(noticeTimer);
  action("start", {}, () => canvas.focus({ preventScroll: true }));
});
$("play-again").addEventListener("click", () => action("reset"));
$("command-strip").addEventListener("click", (event) => {
  const button = event.target.closest("[data-order]");
  if (button) action("order", { order: button.dataset.order });
});
$("formations").addEventListener("click", (e) => {
  const button = e.target.closest("button");
  if (button) action("formation", { formation: button.dataset.formation });
});
$("control-scheme").addEventListener("change", (e) => {
  state.scheme = e.target.value;
  saveStorage("breach-scheme", state.scheme);
  releaseInput();
  document.querySelector(".control-item>div").replaceChildren(
    ...(state.scheme === "edsf"
      ? ["E", "D", "S", "F"]
      : ["W", "A", "S", "D"]
    ).map((key) => {
      const k = document.createElement("kbd");
      k.textContent = key;
      return k;
    }),
  );
});
$("control-scheme").dispatchEvent(new Event("change"));
$("chat-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const input = $("chat-input"),
    text = input.value.trim();
  if (text)
    action("chat", { text }, () => {
      input.value = "";
    });
});
function addSystem(text) {
  const line = document.createElement("div");
  line.className = "chat-message system";
  line.textContent = text;
  $("chat-log").append(line);
}
function addChat(message) {
  const log = $("chat-log");
  const nearBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 50;
  if (
    message.id &&
    log.querySelector(`[data-message-id="${CSS.escape(String(message.id))}"]`)
  )
    return;
  log.querySelector(".chat-empty")?.remove();
  const row = document.createElement("div");
  row.className = "chat-message";
  if (message.id) row.dataset.messageId = message.id;
  const name = document.createElement("b");
  name.textContent = message.name || "Operator";
  const body = document.createElement("span");
  body.textContent = message.text;
  row.append(name, body);
  log.append(row);
  while (log.children.length > 100) log.firstChild.remove();
  if (nearBottom) log.scrollTop = log.scrollHeight;
}
function isLeader() {
  return !!state.userId && state.lobby?.leader_id === state.userId;
}
function phase() {
  return state.game?.status || state.lobby?.status || "waiting";
}
function rosterName(slot, member, player) {
  if (member)
    return `${member.name}${member.id === state.userId ? " (you)" : ""}`;
  const botName =
    (player?.bot && player.name) ||
    state.lobby?.bot_names?.[slot] ||
    ["Jason", "Morgan", "Riley", "Alex"][slot];
  return `${String(botName).replace(/(?:\s*\(AI\))+$/i, "")} (AI)`;
}
function renderRoster() {
  const roster = $("roster");
  roster.replaceChildren();
  const members = state.lobby?.members || [];
  for (let slot = 0; slot < 4; slot++) {
    const member = members.find((m) => m.slot === slot),
      me = member?.id === state.userId;
    const player = state.game?.players?.find((p) => p.slot === slot);
    const row = document.createElement("div");
    row.className = `operator ${member ? "human" : ""} ${me ? "self" : ""}`;
    const number = document.createElement("span");
    number.className = "operator-number";
    number.textContent = String(slot + 1).padStart(2, "0");
    const info = document.createElement("div");
    info.className = "operator-info";
    const name = document.createElement("div");
    name.className = "operator-name";
    name.id = `operator-name-${slot}`;
    name.textContent = rosterName(slot, member, player);
    name.title = name.textContent;
    const detail = document.createElement("div");
    detail.className = "operator-detail";
    detail.id = `operator-status-${slot}`;
    detail.textContent = member
      ? state.lobby.leader_id === member.id
        ? "SQUAD LEADER"
        : "OPERATOR / READY"
      : "AUTONOMOUS SUPPORT";
    if (player)
      detail.textContent =
        player.hp > 0
          ? `${Math.ceil(player.hp)} HP / ${player.bot ? "AI SUPPORT" : "ACTIVE"}`
          : "OPERATOR DOWN";
    info.append(name, detail);
    row.append(number, info);
    if (!member && state.lobby && phase() === "waiting") {
      const b = document.createElement("button");
      b.className = "operator-action";
      b.textContent = "TAKE";
      b.title = `Move to slot ${slot + 1}`;
      b.addEventListener("click", () => action("slot", { slot }));
      row.append(b);
    } else if (member && !me && isLeader()) {
      const b = document.createElement("button");
      b.className = "operator-action";
      b.textContent = "↑";
      b.title = `Transfer leadership to ${member.name}`;
      b.setAttribute("aria-label", b.title);
      b.addEventListener("click", () =>
        action("transfer", { user_id: member.id }),
      );
      row.append(b);
    } else if (!member) {
      const b = document.createElement("span");
      b.className = "ai-badge";
      b.textContent = "AI";
      row.append(b);
    } else if (state.lobby.leader_id === member.id) {
      const b = document.createElement("span");
      b.className = "ai-badge";
      b.textContent = "LDR";
      row.append(b);
    }
    roster.append(row);
  }
  $("squad-count").textContent = `${members.length} / 4`;
}
function updateUI() {
  const joined = !!state.lobby,
    status = phase(),
    playing = status === "playing",
    over = status === "won" || status === "lost",
    leader = isLeader();
  document.body.classList.toggle("operation-active", playing || over);
  document.body.classList.toggle("is-connected", joined);
  $("command-strip").hidden = !playing;
  document.querySelectorAll("[data-order]").forEach((button) => {
    button.classList.toggle(
      "selected",
      button.dataset.order === (state.game?.order || "auto"),
    );
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.order === (state.game?.order || "auto")),
    );
    button.disabled = !playing || !state.connected || !!state.game?.spectator;
  });
  if (playing && state.uiPhase !== "playing") {
    $("notice").hidden = true;
    clearTimeout(noticeTimer);
  }
  state.uiPhase = status;
  $("entry-panel").hidden = joined;
  $("session-panel").hidden = !joined;
  $("session-code").textContent = state.lobby?.code || "—";
  $("lobby-state").textContent = joined
    ? playing
      ? "ACTIVE"
      : over
        ? "DEBRIEF"
        : "CONNECTED"
    : "STANDBY";
  $("create-lobby").disabled = state.joining;
  document.querySelector("#join-form button").disabled = state.joining;
  $("chat-input").disabled = !state.connected || playing;
  $("chat-input").placeholder = playing
    ? "Radio silence during operation"
    : "Message your squad…";
  document
    .querySelector(".comms-dot")
    .classList.toggle("radio-silent", playing);
  document.querySelector("#chat-form button").disabled =
    !state.connected || playing;
  $("briefing").hidden = playing || over;
  $("end-screen").hidden = !over;
  $("player-hud").hidden = !playing;
  $("map-bottom-note").hidden = playing || over;
  $("start-game").disabled =
    !state.connected || !leader || status !== "waiting";
  $("start-game").innerHTML = playing
    ? "OPERATION ACTIVE <span>•</span>"
    : over
      ? "OPERATION ENDED <span>■</span>"
      : "DEPLOY SQUAD <span>↗</span>";
  $("map-title").textContent = playing
    ? state.game?.spectator
      ? "SPECTATING / FULL OVERVIEW"
      : "OPERATION IN PROGRESS"
    : over
      ? "AFTER ACTION REPORT"
      : "TACTICAL OVERVIEW";
  $("map-subtitle").textContent = state.lobby
    ? (
        state.game?.map?.archetype || `OPERATION ${state.lobby.code}`
      ).toUpperCase()
    : "PROCEDURAL TRAINING FACILITY";
  $("mission-status").textContent = playing
    ? state.game?.spectator
      ? "Operator down. Follow your squad."
      : "Keep your squad together."
    : over
      ? status === "won"
        ? "All hostiles neutralized."
        : "Squad lost. Regroup and adapt."
      : joined
        ? "Your operation is ready."
        : "Ready when you are.";
  $("mission-description").textContent = playing
    ? `${state.game?.enemies_remaining ?? "—"} hostiles remaining · ${state.game?.players?.filter((p) => p.hp > 0).length ?? 4} operators standing`
    : over
      ? "Return to briefing for a new procedural facility."
      : joined
        ? leader
          ? "You lead the squad. Deploy whenever you’re ready."
          : "Your squad leader will begin the operation."
        : "Create an operation to assemble your team.";
  document.querySelectorAll("[data-formation]").forEach((button) => {
    button.classList.toggle(
      "selected",
      button.dataset.formation === (state.lobby?.formation || "stack"),
    );
    button.disabled = !state.connected || !leader || status !== "waiting";
  });
  if (over) {
    $("end-label").textContent =
      status === "won" ? "OPERATION COMPLETE" : "OPERATION FAILED";
    $("end-title").textContent =
      status === "won" ? "Facility secured." : "Squad down.";
    $("end-description").textContent =
      status === "won"
        ? `${state.game.enemies_total ? `${state.game.enemies_total} hostiles` : "All hostiles"} neutralized in ${formatTime(state.game.elapsed_ms)}. ${state.game.players.filter((p) => p.hp > 0).length} operators survived.`
        : "Every corner is a lesson. Regroup with your squad and try a new approach.";
    $("play-again").disabled = !leader || !state.connected;
    $("play-again").textContent = leader
      ? "RETURN TO BRIEFING ↗"
      : "WAITING FOR SQUAD LEADER";
  }
  if (!state.game) $("mission-clock").textContent = "00:00";
}
function formatTime(ms = 0) {
  const sec = Math.floor(ms / 1000);
  return `${String(Math.floor(sec / 60)).padStart(2, "0")}:${String(sec % 60).padStart(2, "0")}`;
}
function setText(element, value) {
  if (element.textContent !== value) element.textContent = value;
}
function setHTML(element, value) {
  if (element.innerHTML !== value) element.innerHTML = value;
}
function receiveSnapshot(game) {
  if (!game) {
    state.game = null;
    snapshots.clear();
    updateUI();
    renderRoster();
    return;
  }
  if (state.game?.seed !== game.seed || game.tick < (state.game?.tick || 0)) {
    snapshots.clear();
    state.shots.clear();
    state.audioEvents.clear();
  }
  game = mergeSnapshotMap(game, state.game);
  if (!game) return;
  state.game = game;
  snapshots.push(game, performance.now());
  const visible = new Set((game.visible_tiles || []).map(([x, y]) => `${x},${y}`));
  const explored = new Set((game.explored_tiles || []).map(([x, y]) => `${x},${y}`));
  const size = game.map.tile_size;
  const cells = game.map.floor_tiles || Array.from(
    { length: Math.ceil(game.map.height / size) }, (_, y) => Array.from(
      { length: Math.ceil(game.map.width / size) }, (_, x) => [x, y],
    ),
  ).flat();
  state.fogCells = cells.map(([x, y]) => ({
    x: x * size, y: y * size,
    color: visible.has(`${x},${y}`) ? "#c9dc8910" : explored.has(`${x},${y}`) ? "#070f0a55" : "#060c08aa",
  }));
  for (const shot of game.shots || [])
    if (!state.shots.has(shot.id))
      state.shots.set(shot.id, { ...shot, at: performance.now() });
  const me = game.players.find((p) => p.id === state.userId);
  if (me) {
    setHTML($("hud-health"), `${Math.max(0, Math.ceil(me.hp))} <small>HP</small>`);
    $("hud-health-bar").style.width = `${Math.max(0, me.hp)}%`;
    setHTML($("hud-ammo"), `${String(me.ammo).padStart(2, "0")} <small>/ ∞</small>`);
    setText($("hud-reload"),
      me.hp <= 0
        ? "OPERATOR DOWN"
        : me.reload_ms > 0
          ? "RELOADING…"
          : me.ammo === 0
            ? "EMPTY / PRESS R"
            : "R TO RELOAD");
    setText($("ammo-label"), me.hp <= 0 ? "SPECTATING SQUAD" : "CARBINE / 5.56");

    state.lastAmmo = me.ammo;
  }
  game.players.forEach((p) => {
    const name = $(`operator-name-${p.slot}`);
    if (name) {
      setText(name, rosterName(
        p.slot,
        state.lobby?.members?.find((m) => m.slot === p.slot),
        p,
      ));
      name.title = name.textContent;
    }
    const el = $(`operator-status-${p.slot}`);
    if (el)
      setText(el, p.hp > 0
          ? `${Math.ceil(p.hp)} HP / ${p.bot ? "AI SUPPORT" : "ACTIVE"}`
          : "OPERATOR DOWN");
  });
  for (const event of game.events || []) {
    if (!state.audioEvents.has(event.id)) {
      state.audioEvents.add(event.id);
      playEventSound(event, me, game);
    }
  }
  if (state.audioEvents.size > 3000)
    state.audioEvents = new Set([...state.audioEvents].slice(-1000));
  setText($("mission-clock"), formatTime(game.elapsed_ms));
  const uiKey = [game.seed, game.status, game.spectator, game.order,
    game.enemies_remaining, game.players.filter((p) => p.hp > 0).length].join("|");
  if (state.snapshotUIKey !== uiKey) {
    state.snapshotUIKey = uiKey;
    updateUI();
  }
}
function inputFocused() {
  return (
    ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement?.tagName) ||
    document.activeElement?.isContentEditable
  );
}
function releaseInput() {
  state.keys.clear();
  state.shoot = false;
  state.reload = false;
  if (state.channel && state.connected)
    state.channel.push("input", {
      x: 0,
      y: 0,
      aim: state.aim,
      shoot: false,
      reload: false,
    });
}
window.addEventListener("keydown", (event) => {
  if (inputFocused() || event.ctrlKey || event.metaKey || event.altKey) return;
  const key = event.key.toLowerCase();
  if (
    ["1", "2", "3", "4"].includes(key) &&
    phase() === "playing" &&
    !state.game?.spectator &&
    !event.repeat
  ) {
    event.preventDefault();
    action("order", {
      order: ["hold", "form_up", "aggro", "auto"][Number(key) - 1],
    });
    return;
  }
  if (
    (state.scheme === "edsf"
      ? ["e", "d", "s", "f", "r"]
      : ["w", "a", "s", "d", "r"]
    ).includes(key)
  ) {
    if (phase() === "playing") event.preventDefault();
    state.keys.add(key);
    if (key === "r" && !event.repeat) state.reload = true;
  }
});
window.addEventListener("keyup", (event) =>
  state.keys.delete(event.key.toLowerCase()),
);
window.addEventListener("blur", releaseInput);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) releaseInput();
});
document.addEventListener("focusin", () => {
  if (inputFocused()) releaseInput();
});
canvas.addEventListener("pointermove", (event) => {
  const rect = canvas.getBoundingClientRect();
  state.mouse = {
    x: (event.clientX - rect.left - view.x) / view.scale,
    y: (event.clientY - rect.top - view.y) / view.scale,
  };
  updateAim();
});
canvas.addEventListener("pointerdown", (event) => {
  if (event.button !== 0) return;
  canvas.focus({ preventScroll: true });
  state.shoot = true;
  canvas.setPointerCapture?.(event.pointerId);
  updateAim();
  if (state.connected && phase() === "playing" && !state.game?.spectator)
    state.channel.push("input", {
      ...movement(),
      aim: state.aim,
      shoot: true,
      reload: false,
    });
});
window.addEventListener("pointerup", () => {
  state.shoot = false;
});
canvas.addEventListener("pointercancel", releaseInput);
canvas.addEventListener("lostpointercapture", () => {
  state.shoot = false;
});
canvas.addEventListener("contextmenu", (e) => e.preventDefault());
function updateAim() {
  const me = state.game?.players.find((p) => p.id === state.userId);
  if (me && state.mouse)
    state.aim = Math.atan2(state.mouse.y - me.y, state.mouse.x - me.x);
}
function movement() {
  const k = state.keys,
    edsf = state.scheme === "edsf";
  return {
    x: Number(k.has(edsf ? "f" : "d")) - Number(k.has(edsf ? "s" : "a")),
    y: Number(k.has(edsf ? "d" : "s")) - Number(k.has(edsf ? "e" : "w")),
  };
}
setInterval(() => {
  if (
    !state.connected ||
    phase() !== "playing" ||
    state.game?.spectator ||
    inputFocused() ||
    document.hidden
  )
    return;
  updateAim();
  state.channel.push("input", {
    ...movement(),
    aim: state.aim,
    shoot: state.shoot,
    reload: state.reload,
  });
  state.reload = false;
}, 1000 / 30);
function unlockAudio() {
  if (state.muted) return;
  const Audio = window.AudioContext || window.webkitAudioContext;
  if (Audio) {
    state.sound ??= new Audio();
    state.sound.resume();
  }
}
function syncSoundUI() {
  $("sound-toggle").textContent = state.muted ? "SOUND OFF" : "SOUND ON";
  $("sound-toggle").setAttribute(
    "aria-label",
    state.muted ? "Enable sound" : "Mute sound",
  );
  $("sound-toggle").setAttribute("aria-pressed", String(!state.muted));
}
syncSoundUI();
$("sound-toggle").addEventListener("click", () => {
  state.muted = !state.muted;
  saveStorage("breach-muted", String(state.muted));
  syncSoundUI();
  unlockAudio();
});
$("sound-volume").value = String(state.volume * 100);
$("sound-volume").addEventListener("input", (event) => {
  state.volume = Number(event.target.value) / 100;
  saveStorage("breach-volume", String(state.volume));
});
window.addEventListener("pointerdown", unlockAudio);
window.addEventListener("keydown", unlockAudio);
// Only server-authorized audible events create sound. Never infer hidden enemy actions.
// Server distance gain is listener-specific; wall occlusion also adds a low-pass filter.
function playEventSound(event, listener, game) {
  if (
    state.muted ||
    !state.sound ||
    document.hidden ||
    state.sound.state !== "running"
  )
    return;
  const audio = state.sound,
    now = audio.currentTime,
    master = audio.createGain(),
    filter = audio.createBiquadFilter(),
    pan = audio.createStereoPanner();
  master.gain.value =
    Math.min(1, Math.max(0, event.volume ?? 0.7)) * state.volume * 0.3;
  filter.type = "lowpass";
  filter.frequency.value = event.occluded ? 850 : 11000;
  pan.pan.value =
    listener && Number.isFinite(event.x)
      ? Math.max(-0.9, Math.min(0.9, (event.x - listener.x) / 300))
      : 0;
  filter.connect(pan);
  pan.connect(master);
  master.connect(audio.destination);
  const tone = (freq, end, offset, duration, level, type = "sine") => {
    const osc = audio.createOscillator(),
      gain = audio.createGain(),
      start = now + offset;
    osc.type = type;
    osc.frequency.setValueAtTime(freq, start);
    osc.frequency.exponentialRampToValueAtTime(
      Math.max(15, end),
      start + duration,
    );
    gain.gain.setValueAtTime(0.0001, start);
    gain.gain.exponentialRampToValueAtTime(level, start + 0.005);
    gain.gain.exponentialRampToValueAtTime(0.0001, start + duration);
    osc.connect(gain);
    gain.connect(filter);
    osc.start(start);
    osc.stop(start + duration + 0.01);
  };
  const noise = (offset, duration, level, cutoff = 5000) => {
    const buffer = audio.createBuffer(
        1,
        Math.ceil(audio.sampleRate * duration),
        audio.sampleRate,
      ),
      data = buffer.getChannelData(0);
    for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;
    const source = audio.createBufferSource(),
      gain = audio.createGain(),
      shape = audio.createBiquadFilter();
    source.buffer = buffer;
    shape.type = "lowpass";
    shape.frequency.value = cutoff;
    gain.gain.setValueAtTime(level, now + offset);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + offset + duration);
    source.connect(shape);
    shape.connect(gain);
    gain.connect(filter);
    source.start(now + offset);
  };
  switch (event.type) {
    case "shot":
      noise(0, 0.085, 0.7, event.team === "enemy" ? 3800 : 6200);
      tone(event.team === "enemy" ? 95 : 130, 35, 0, 0.14, 0.85, "triangle");
      noise(0.045, 0.15, 0.18, 1800);
      break;
    case "reload":
      noise(0, 0.035, 0.3, 4500);
      tone(850, 280, 0, 0.04, 0.15, "square");
      noise(0.18, 0.06, 0.4, 3300);
      noise(0.39, 0.035, 0.25, 5200);
      break;
    case "hit":
      noise(0, 0.065, 0.45, 900);
      tone(180, 55, 0, 0.12, 0.5, "triangle");
      break;
    case "death":
      tone(130, 32, 0, 0.38, 0.45, "triangle");
      noise(0, 0.18, 0.25, 700);
      break;
    case "round_end": {
      const won = event.team === "friendly" || game.status === "won";
      const notes = won ? [261.63, 329.63, 392, 523.25] : [220, 174.61, 146.83];
      notes.forEach((note, i) =>
        tone(note, note, i * 0.14, 0.35, 0.35, "sine"),
      );
      break;
    }
    default:
      break;
  }
  setTimeout(() => {
    master.disconnect();
    filter.disconnect();
    pan.disconnect();
  }, 1600);
}

// The deployment preview is deliberately a blueprint, never an enemy-location leak.
const preview = {
  width: 1024,
  height: 704,
  tile_size: 32,
  rooms: [
    { x: 64, y: 64, w: 256, h: 192, label: "STORAGE" },
    { x: 352, y: 64, w: 288, h: 192, label: "OFFICES" },
    { x: 672, y: 64, w: 288, h: 192, label: "SERVER ROOM" },
    { x: 64, y: 320, w: 256, h: 320, label: "RECEIVING" },
    { x: 352, y: 352, w: 288, h: 288, label: "OPERATIONS" },
    { x: 672, y: 320, w: 288, h: 320, label: "WORKSHOP" },
  ],
  walls: [
    { x: 32, y: 32, w: 960, h: 14 },
    { x: 32, y: 658, w: 960, h: 14 },
    { x: 32, y: 32, w: 14, h: 640 },
    { x: 978, y: 32, w: 14, h: 640 },
    { x: 320, y: 32, w: 16, h: 224 },
    { x: 640, y: 32, w: 16, h: 224 },
    { x: 32, y: 256, w: 120, h: 16 },
    { x: 224, y: 256, w: 264, h: 16 },
    { x: 560, y: 256, w: 220, h: 16 },
    { x: 852, y: 256, w: 140, h: 16 },
    { x: 320, y: 336, w: 16, h: 336 },
    { x: 640, y: 336, w: 16, h: 336 },
    { x: 32, y: 320, w: 160, h: 16 },
    { x: 264, y: 320, w: 136, h: 16 },
    { x: 480, y: 320, w: 264, h: 16 },
    { x: 824, y: 320, w: 168, h: 16 },
    { x: 110, y: 105, w: 110, h: 35 },
    { x: 706, y: 99, w: 55, h: 90 },
    { x: 810, y: 99, w: 55, h: 90 },
    { x: 110, y: 470, w: 100, h: 80 },
    { x: 725, y: 450, w: 170, h: 40 },
  ],
};
function resize() {
  const rect = canvas.getBoundingClientRect(),
    ratio = Math.min(devicePixelRatio || 1, 2);
  if (
    canvas.width !== Math.round(rect.width * ratio) ||
    canvas.height !== Math.round(rect.height * ratio)
  ) {
    canvas.width = Math.round(rect.width * ratio);
    canvas.height = Math.round(rect.height * ratio);
  }
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  view.width = rect.width;
  view.height = rect.height;
}
function rayEnd(x, y, angle, map, max = 850) {
  const dx = Math.cos(angle),
    dy = Math.sin(angle);
  let distance = max;
  for (const wall of map.walls) {
    const tx1 = dx === 0 ? -Infinity : (wall.x - x) / dx,
      tx2 = dx === 0 ? Infinity : (wall.x + wall.w - x) / dx,
      ty1 = dy === 0 ? -Infinity : (wall.y - y) / dy,
      ty2 = dy === 0 ? Infinity : (wall.y + wall.h - y) / dy;
    if (dx === 0 && (x < wall.x || x > wall.x + wall.w)) continue;
    if (dy === 0 && (y < wall.y || y > wall.y + wall.h)) continue;
    const low = Math.max(Math.min(tx1, tx2), Math.min(ty1, ty2)),
      high = Math.min(Math.max(tx1, tx2), Math.max(ty1, ty2));
    if (low <= high && high >= 0)
      distance = Math.min(distance, Math.max(0, low));
  }
  return { x: x + dx * distance, y: y + dy * distance };
}
function render(now) {
  resize();
  const game = state.game,
    map = game?.map || preview;
  const width = view.width,
    height = view.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = "#080e0c";
  ctx.fillRect(0, 0, width, height);
  if (game) {
    const verticalSpace = width < 760 ? 205 : 180;
    view.scale = Math.max(
      0.08,
      Math.min((width - 36) / map.width, (height - verticalSpace) / map.height),
    );
    view.x = (width - map.width * view.scale) / 2;
    view.y = 90 + (height - verticalSpace - map.height * view.scale) / 2;
  } else {
    view.scale = Math.min(
      (width < 760 ? width * 1.7 : width * 0.72) / map.width,
      (height * 0.74) / map.height,
    );
    view.x = width < 760 ? width * 0.09 : width * 0.41;
    view.y = (height - map.height * view.scale) / 2 - 20;
  }
  ctx.save();
  ctx.translate(view.x, view.y);
  ctx.scale(view.scale, view.scale);
  const s = map.tile_size || 32;
  ctx.fillStyle = "#101d15";
  if (map.floor_tiles) {
    for (const [x, y] of map.floor_tiles) ctx.fillRect(x * s, y * s, s, s);
  } else ctx.fillRect(0, 0, map.width, map.height);
  if (map.exterior_tiles) {
    ctx.fillStyle = "#0b1610";
    for (const [x, y] of map.exterior_tiles) ctx.fillRect(x * s, y * s, s, s);
  }
  ctx.strokeStyle = "#6a8d5410";
  ctx.lineWidth = 0.7 / view.scale;
  if (map.floor_tiles) {
    for (const [x, y] of map.floor_tiles) ctx.strokeRect(x * s, y * s, s, s);
  } else {
    ctx.beginPath();
    for (let x = 0; x <= map.width; x += s) {
      ctx.moveTo(x, 0);
      ctx.lineTo(x, map.height);
    }
    for (let y = 0; y <= map.height; y += s) {
      ctx.moveTo(0, y);
      ctx.lineTo(map.width, y);
    }
    ctx.stroke();
  }
  for (const [i, room] of (map.rooms || []).entries()) {
    ctx.fillStyle = i % 2 ? "#66825b13" : "#8ba06e0e";
    ctx.fillRect(room.x, room.y, room.w, room.h);
    ctx.strokeStyle = "#8da57425";
    ctx.lineWidth = 0.8 / view.scale;
    ctx.setLineDash([4 / view.scale, 5 / view.scale]);
    ctx.strokeRect(
      room.x + 7,
      room.y + 7,
      Math.max(0, room.w - 14),
      Math.max(0, room.h - 14),
    );
    ctx.setLineDash([]);
    ctx.fillStyle = "#8eaa6e60";
    ctx.font = `${8 / view.scale}px "IBM Plex Mono",monospace`;
    ctx.textAlign = "left";
    ctx.fillText(
      room.label || `SECTOR ${String(i + 1).padStart(2, "0")}`,
      room.x + 17,
      room.y + 27,
    );
  }
  // Team visibility is server-generated. Hidden enemies are absent from snapshots.
  if (game) {
    for (const cell of state.fogCells) {
      ctx.fillStyle = cell.color;
      ctx.fillRect(cell.x, cell.y, s + 0.5, s + 0.5);
    }
  }
  for (const wall of map.walls) {
    ctx.fillStyle = game ? "#536948" : "#334a2e";
    ctx.fillRect(wall.x, wall.y, wall.w, wall.h);
    ctx.strokeStyle = game ? "#869b69" : "#678153";
    ctx.lineWidth = 1 / view.scale;
    ctx.strokeRect(
      wall.x + 0.5,
      wall.y + 0.5,
      Math.max(0, wall.w - 1),
      Math.max(0, wall.h - 1),
    );
    if (!game && wall.w > 24 && wall.h > 24) {
      ctx.strokeStyle = "#94a07a33";
      ctx.beginPath();
      ctx.moveTo(wall.x + 3, wall.y + 3);
      ctx.lineTo(wall.x + wall.w - 3, wall.y + wall.h - 3);
      ctx.moveTo(wall.x + wall.w - 3, wall.y + 3);
      ctx.lineTo(wall.x + 3, wall.y + wall.h - 3);
      ctx.stroke();
    }
  }
  if (game && map.entry) {
    const { x, y, label } = map.entry;
    ctx.save();
    ctx.translate(x, y);
    ctx.strokeStyle = "#c5d99199";
    ctx.lineWidth = 1 / view.scale;
    ctx.setLineDash([3 / view.scale, 3 / view.scale]);
    ctx.beginPath();
    ctx.arc(0, 0, 16 / view.scale, 0, Math.PI * 2);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = "#bdcf9299";
    ctx.font = `${7 / view.scale}px "IBM Plex Mono",monospace`;
    ctx.textAlign = "center";
    ctx.fillText((label || "BREACH POINT").toUpperCase(), 0, 28 / view.scale);
    ctx.restore();
  }
  if (game) {
    const sample = snapshots.sample(now);
    const players = game.players.map((p) => interpolateActor(p, sample, "players"));
    for (const player of players) {
      const me = player.id === state.userId,
        angle = me ? state.aim : player.angle;
      if (player.hp > 0) {
        const end = rayEnd(player.x, player.y, angle, map);
        const gradient = ctx.createLinearGradient(
          player.x,
          player.y,
          end.x,
          end.y,
        );
        gradient.addColorStop(0, me ? "#d6f39ab0" : "#c0d89066");
        gradient.addColorStop(1, me ? "#cbe89022" : "#c0d8900b");
        ctx.strokeStyle = gradient;
        ctx.lineWidth = (me ? 1.1 : 0.8) / view.scale;
        ctx.beginPath();
        ctx.moveTo(player.x, player.y);
        ctx.lineTo(end.x, end.y);
        ctx.stroke();
        ctx.fillStyle = me ? "#d4ed9d" : "#b8ce8a88";
        ctx.beginPath();
        ctx.arc(end.x, end.y, 1.7 / view.scale, 0, Math.PI * 2);
        ctx.fill();
      }
      drawOperator(player, angle, me, false);
    }
    for (const enemy of game.enemies || []) {
      // Membership always comes from the latest visibility-filtered snapshot.
      const p = interpolateActor(enemy, sample, "enemies");
      drawOperator(p, p.angle, false, true);
    }
    for (const [id, shot] of state.shots) {
      const age = now - shot.at;
      if (age > 145) {
        state.shots.delete(id);
        continue;
      }
      ctx.globalAlpha = Math.max(0, 1 - age / 145);
      ctx.strokeStyle = shot.team === "enemy" ? "#efb48d" : "#ecedb4";
      ctx.lineWidth = 2 / view.scale;
      ctx.beginPath();
      ctx.moveTo(shot.x1, shot.y1);
      ctx.lineTo(shot.x2, shot.y2);
      ctx.stroke();
      ctx.fillStyle = "#fff1b1";
      ctx.beginPath();
      ctx.arc(shot.x1, shot.y1, 4 * (1 - age / 145), 0, Math.PI * 2);
      ctx.fill();
      ctx.globalAlpha = 1;
    }
  } else {
    ctx.strokeStyle = "#c4d99044";
    ctx.lineWidth = 1 / view.scale;
    ctx.setLineDash([5, 7]);
    ctx.beginPath();
    ctx.moveTo(180, 610);
    ctx.lineTo(180, 292);
    ctx.lineTo(900, 292);
    ctx.stroke();
    ctx.setLineDash([]);
    for (let i = 0; i < 4; i++) {
      const x = 155 + i * 22,
        y = 599;
      ctx.fillStyle = "#c3d28a";
      ctx.beginPath();
      ctx.arc(x, y, 6, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = "#b5c98655";
      ctx.strokeRect(x - 10, y - 10, 20, 20);
    }
    ctx.fillStyle = "#b5c986";
    ctx.font = `${7 / view.scale}px monospace`;
    ctx.fillText("INSERTION POINT", 140, 635);
  }
  ctx.restore();
  if (game && state.mouse && phase() === "playing") {
    const x = state.mouse.x * view.scale + view.x,
      y = state.mouse.y * view.scale + view.y;
    ctx.strokeStyle = "#d6e8b6aa";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(x, y, 6, 0, Math.PI * 2);
    ctx.moveTo(x - 10, y);
    ctx.lineTo(x - 5, y);
    ctx.moveTo(x + 5, y);
    ctx.lineTo(x + 10, y);
    ctx.moveTo(x, y - 10);
    ctx.lineTo(x, y - 5);
    ctx.moveTo(x, y + 5);
    ctx.lineTo(x, y + 10);
    ctx.stroke();
  }
  requestAnimationFrame(render);
}
function drawOperator(p, angle, me, enemy) {
  const alive = p.hp > 0,
    color = enemy ? "#df8e73" : me ? "#d7eda6" : "#aabd89";
  ctx.save();
  ctx.translate(p.x, p.y);
  if (!alive) {
    ctx.strokeStyle = enemy ? "#a2725755" : "#bed59a66";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(-6, -6);
    ctx.lineTo(6, 6);
    ctx.moveTo(6, -6);
    ctx.lineTo(-6, 6);
    ctx.stroke();
    ctx.restore();
    return;
  }
  if (me) {
    ctx.strokeStyle = "#d9eda77a";
    ctx.lineWidth = 1 / view.scale;
    ctx.beginPath();
    ctx.arc(0, 0, 16, 0, Math.PI * 2);
    ctx.stroke();
  }
  ctx.save();
  ctx.rotate(angle);
  ctx.fillStyle = "#182c23";
  ctx.beginPath();
  ctx.ellipse(-1, 0, 11, 9, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = color;
  ctx.lineWidth = 1.5;
  ctx.stroke();
  ctx.fillStyle = color;
  ctx.fillRect(6, -2.5, 13, 5);
  ctx.beginPath();
  ctx.arc(1, 0, 6, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = "#374634";
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(3, -3);
  ctx.lineTo(3, 3);
  ctx.stroke();
  ctx.restore();
  if (!enemy) {
    ctx.fillStyle = color;
    ctx.textAlign = "center";
    ctx.font = `${8 / view.scale}px "IBM Plex Mono",monospace`;
    ctx.fillText(
      me ? "YOU" : String((p.slot || 0) + 1).padStart(2, "0"),
      0,
      (me ? -20 : -15) / view.scale,
    );
    ctx.fillStyle = "#11281d";
    ctx.fillRect(-11, 17, 22, 2);
    ctx.fillStyle = p.hp > 35 ? "#b8d18b" : "#d4a076";
    ctx.fillRect(-11, 17, (22 * Math.max(0, p.hp)) / 100, 2);
  }
  ctx.restore();
}
renderRoster();
updateUI();
requestAnimationFrame(render);
