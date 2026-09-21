export const ACTIONS = Object.freeze({
  up: "Move up", left: "Move left", down: "Move down", right: "Move right",
  reload: "Reload", hold: "Hold positions", form_up: "Form up",
  aggro: "Aggressive clearing", auto: "Autonomous clearing",
});
export const DEFAULT_BINDINGS = Object.freeze({
  up: "KeyW", left: "KeyA", down: "KeyS", right: "KeyD", reload: "KeyR",
  hold: "Digit1", form_up: "Digit2", aggro: "Digit3", auto: "Digit4",
});
export const STORAGE_KEY = "breach-keybindings";
export function supportedKey(code) {
  return /^(Key[A-Z]|Digit[0-9]|Arrow(Up|Down|Left|Right)|Space|BracketLeft|BracketRight|Semicolon|Quote|Comma|Period|Slash|Backslash|Minus|Equal)$/.test(code);
}
export function bindingError(bindings) {
  const used = new Set();
  for (const action of Object.keys(ACTIONS)) {
    const code = bindings?.[action];
    if (!supportedKey(code)) return `Choose a letter, number, arrow, space or punctuation key for ${ACTIONS[action].toLowerCase()}.`;
    if (used.has(code)) return `${keyLabel(code)} is assigned twice. Choose a different key before saving.`;
    used.add(code);
  }
  return null;
}
export function loadBindings(saved, legacyScheme) {
  try {
    const bindings = JSON.parse(saved);
    if (!bindingError(bindings)) return Object.fromEntries(Object.keys(ACTIONS).map(a => [a, bindings[a]]));
  } catch { /* Invalid or unavailable storage falls back to usable controls. */ }
  return { ...DEFAULT_BINDINGS, ...(legacyScheme === "edsf"
    ? {up: "KeyE", left: "KeyS", down: "KeyD", right: "KeyF"} : {}) };
}
export function keyLabel(code) {
  return ({ArrowUp: "↑", ArrowDown: "↓", ArrowLeft: "←", ArrowRight: "→",
    Space: "Space", BracketLeft: "[", BracketRight: "]", Semicolon: ";",
    Quote: "'", Comma: ",", Period: ".", Slash: "/", Backslash: "\\",
    Minus: "−", Equal: "="})[code] || code?.replace(/^(Key|Digit)/, "") || "—";
}
export function movementFor(keys, bindings) {
  return {x: Number(keys.has(bindings.right)) - Number(keys.has(bindings.left)),
    y: Number(keys.has(bindings.down)) - Number(keys.has(bindings.up))};
}
