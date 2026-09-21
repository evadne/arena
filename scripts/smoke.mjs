#!/usr/bin/env node
// End-to-end Phoenix Channels checks; Node >= 22, no npm dependencies.
import assert from 'node:assert/strict';
import { FrameDecoder } from '../priv/static/assets/frame_decoder.mjs';
import { setTimeout as delay } from 'node:timers/promises';

const base = process.env.ARENA_URL || 'http://localhost:4000';
const url = new URL('/socket/websocket?vsn=2.0.0', base);
url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
const nonce = Date.now().toString(36).toUpperCase();
const clients = [];
const timeout = 5000;

class Client {
  constructor(name, code) {
    this.name = name;
    this.topic = `lobby:${code}`;
    this.ref = 0;
    this.joinRef = null;
    this.pending = new Map();
    this.messages = [];
    this.decoder = new FrameDecoder();
    this.socket = new WebSocket(url);
    this.socket.addEventListener('message', ({ data }) => {
      const [joinRef, ref, topic, event, payload] = JSON.parse(data);
      this.messages.push({ joinRef, ref, topic, event, payload });
      if (event === 'lobby') {
        this.lobby = payload;
        if (payload.status === 'waiting') this.decoder.reset();
      }
      if (event === 'frame') {
        const result = this.decoder.apply(payload);
        if (result.status === 'applied') {
          this.game = result.snapshot;
          this.send('frame_ack', {seq: result.seq});
        } else if (result.status === 'resync') this.send('frame_resync', {});
      }
      if (event === 'snapshot') this.game = payload.map ? payload : { ...payload, map: this.game?.map };
      if (event === 'phx_reply' && this.pending.has(ref)) {
        const { resolve, timer } = this.pending.get(ref);
        clearTimeout(timer);
        this.pending.delete(ref);
        resolve(payload);
      }
    });
    clients.push(this);
  }
  async connect() {
    if (this.socket.readyState !== WebSocket.OPEN) await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.name}: socket timeout`)), timeout);
      this.socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
      this.socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error(`Cannot connect to ${url}. Start mix phx.server first.`)); }, { once: true });
    });
    const reply = await this.push('phx_join', { name: this.name, protocol: 3 });
    if (reply.status === 'ok') {
      this.id = reply.response.user_id;
      this.lobby = reply.response.lobby;
      this.game = reply.response.game;
    }
    return reply;
  }
  push(event, payload = {}) {
    const ref = String(++this.ref);
    if (event === 'phx_join') this.joinRef = ref;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(ref); reject(new Error(`${this.name}: timed out awaiting ${event}`)); }, timeout);
      this.pending.set(ref, { resolve, timer });
      this.socket.send(JSON.stringify([this.joinRef, ref, this.topic, event, payload]));
    });
  }
  send(event, payload) { this.socket.send(JSON.stringify([this.joinRef, null, this.topic, event, payload])); }
  close() { this.socket.close(); }
}

async function until(predicate, description, limit = timeout) {
  const started = Date.now();
  while (!predicate()) {
    if (Date.now() - started > limit) throw new Error(`Timed out: ${description}`);
    await delay(25);
  }
}
function ok(reply, message) { assert.equal(reply.status, 'ok', `${message}: ${JSON.stringify(reply)}`); }
function denied(reply, message) { assert.equal(reply.status, 'error', `${message}: ${JSON.stringify(reply)}`); }
function check(message) { console.log(`✓ ${message}`); }
const cardinalDirections = [
  { x: 1, y: 0, aim: 0 }, { x: -1, y: 0, aim: Math.PI },
  { x: 0, y: 1, aim: Math.PI / 2 }, { x: 0, y: -1, aim: -Math.PI / 2 },
];
// Public wall rectangles determine traversable directions for any generated entry.
function wallDistance(origin, direction, walls) {
  const distances = walls.flatMap(wall => {
    if (direction.x !== 0 && origin.y >= wall.y && origin.y <= wall.y + wall.h) {
      const edge = direction.x > 0 ? wall.x : wall.x + wall.w;
      const distance = (edge - origin.x) * direction.x;
      return distance >= 0 ? [distance] : [];
    }
    if (direction.y !== 0 && origin.x >= wall.x && origin.x <= wall.x + wall.w) {
      const edge = direction.y > 0 ? wall.y : wall.y + wall.h;
      const distance = (edge - origin.y) * direction.y;
      return distance >= 0 ? [distance] : [];
    }
    return [];
  });
  return Math.min(...distances);
}
async function input(client, overrides = {}) {
  client.send('input', { x: 0, y: 0, aim: Math.PI, shoot: false, reload: false, ...overrides });
}

try {
  const first = new Client('Alpha', `S${nonce}`);
  ok(await first.connect(), 'first join');
  assert.equal(first.lobby.leader_id, first.id);
  const second = new Client('Bravo', `S${nonce}`);
  ok(await second.connect(), 'second join');
  const isolated = new Client('Elsewhere', `I${nonce}`);
  ok(await isolated.connect(), 'isolated join');
  await until(() => first.lobby.members.length === 2, 'shared membership');
  assert.equal(isolated.lobby.members.length, 1);
  assert.notEqual(first.id, second.id);
  check('independent sockets share their lobby; another code stays isolated');

  const chatText = `smoke-${nonce} <b>plain text</b>`;
  ok(await first.push('chat', { text: chatText }), 'chat send');
  await until(() => second.messages.some(m => m.event === 'chat' && m.payload.text === chatText), 'chat delivery');
  await delay(120);
  assert(!isolated.messages.some(m => m.event === 'chat' && m.payload.text === chatText));
  check('text chat broadcasts to peers and stays inside its lobby');

  denied(await second.push('start', { user_id: first.id }), 'nonleader cannot spoof leader identity');
  denied(await second.push('transfer', { user_id: second.id }), 'nonleader transfer denied');
  denied(await second.push('formation', { formation: 'line' }), 'nonleader formation denied');
  denied(await first.push('transfer', { user_id: isolated.id }), 'transfer outside lobby denied');
  ok(await first.push('transfer', { user_id: second.id }), 'leader transfer');
  await until(() => first.lobby.leader_id === second.id, 'leadership update');
  denied(await first.push('start'), 'old leader start denied');
  ok(await second.push('formation', { formation: 'wedge' }), 'formation');
  await until(() => first.lobby.formation === 'wedge', 'formation broadcast');
  check('only the current leader controls launch, transfer and formation');

  const third = new Client('Charlie', `S${nonce}`);
  const fourth = new Client('Delta', `S${nonce}`);
  ok(await third.connect(), 'third join');
  ok(await fourth.connect(), 'fourth join');
  const fifth = new Client('Overflow', `S${nonce}`);
  denied(await fifth.connect(), 'fifth member rejected');
  fifth.close();
  const oldSlot = first.lobby.members.find(member => member.id === first.id).slot;
  denied(await first.push('slot', { slot: 99 }), 'invalid slot denied');
  denied(await first.push('slot', { slot: second.lobby.members.find(member => member.id === second.id).slot }), 'occupied slot denied');
  assert(Number.isInteger(oldSlot));
  third.close();
  fourth.close();
  await until(() => first.lobby.members.length === 2, 'departures free slots');
  check('four-person lobby capacity and slot validation');

  ok(await second.push('start'), 'leader launch');
  await until(() => first.game?.status === 'playing', 'mission snapshot');
  assert(first.messages.some(m => m.event === 'frame'), 'protocol 3 acknowledged frames are active');
  const initial = structuredClone(first.game);
  assert.equal(initial.players.length, 4);
  assert.equal(initial.players.filter(player => player.bot).length, 2);
  assert(Number.isInteger(initial.enemies_total) && initial.enemies_total >= 12 && initial.enemies_total <= 20, 'mission creates 12–20 hostiles');
  assert.equal(initial.enemies_remaining, initial.enemies_total);
  assert.equal(initial.spectator, false);
  assert(initial.map.rooms.length >= 8 && initial.map.rooms.length <= 12, 'premises have 8–12 rooms');
  assert(Number.isFinite(initial.map.spawn.x) && Number.isFinite(initial.map.spawn.y), 'map supplies squad spawn');
  assert(initial.map.entry?.label && Number.isFinite(initial.map.entry.x) && Number.isFinite(initial.map.entry.y), 'premises have a labeled entry');
  assert(initial.map.exterior_tiles?.length > 0, 'entry has exterior staging space');
  assert(initial.enemies.length <= initial.enemies_total, 'public enemies are filtered by LOS');
  assert(initial.players.every(player => player.ammo === 20));
  await until(() => second.game?.seed === initial.seed, 'identical shared mission seed');
  assert.equal(second.game.enemies_total, initial.enemies_total);
  assert.equal(isolated.lobby.status, 'waiting');
  assert.equal(isolated.game, null);
  check('launch creates four operators (two bots), 12–20 hostiles and one shared map');
  denied(await first.push('chat', { text: 'This must not be sent during combat.' }), 'combat chat denied');
  check('chat is disabled during active missions');

  for (const order of ['hold', 'form_up', 'aggro', 'auto', 'hold']) {
    ok(await first.push('order', { order }), `nonleader issues ${order}`);
    await until(() => first.game.order === order && second.game.order === order, 'shared squad order');
  }
  denied(await first.push('order', { order: 'teleport' }), 'invalid order denied');
  check('living nonleaders can issue all four squad orders and peers receive the change');

  const player = () => first.game.players.find(p => p.id === first.id);
  const before = { x: player().x, y: player().y };
  const moveDirection = [...cardinalDirections].sort((a, b) => wallDistance(before, b, initial.map.walls) - wallDistance(before, a, initial.map.walls))[0];
  assert(wallDistance(before, moveDirection, initial.map.walls) > 16, 'spawn permits movement');
  for (let i = 0; i < 8; i++) { await input(first, moveDirection); await delay(35); }
  await input(first);
  await until(() => Math.hypot(player().x - before.x, player().y - before.y) > 2, 'authoritative movement');
  const fireDirection = [...cardinalDirections].sort((a, b) => wallDistance(player(), a, initial.map.walls) - wallDistance(player(), b, initial.map.walls))[0];
  await input(first, { aim: fireDirection.aim, shoot: true });
  await until(() => player().ammo < 20, 'hitscan consumes ammunition');
  assert(first.game.events.some(event => event.type === 'shot'), 'server emits spatial shot audio event');
  const shot = first.game.shots.find(shot => shot.team === 'friendly' && Math.hypot(shot.x1 - player().x, shot.y1 - player().y) < 0.1);
  assert(shot, 'shot trace received');
  const expectedWallDistance = wallDistance({ x: shot.x1, y: shot.y1 }, fireDirection, initial.map.walls);
  const shotDistance = Math.hypot(shot.x2 - shot.x1, shot.y2 - shot.y1);
  assert(Math.abs(shotDistance - expectedWallDistance) < 0.1, 'hitscan stops at the nearest generated wall');
  await input(first);
  await input(first, { reload: true });
  await until(() => player().reload_ms > 0, 'reload begins');
  assert(first.game.events.some(event => event.type === 'reload'), 'server emits reload audio event');
  await input(first);
  await until(() => player().ammo === 20 && player().reload_ms === 0, 'reload completes', 6000);
  check('movement, shooting and infinite-reserve 20-round reload reach the server');

  denied(await first.push('reset'), 'nonleader reset denied');
  const departedId = first.id;
  first.close();
  await until(() => second.lobby.members.length === 1, 'operator disconnect');
  await until(() => second.game.players.filter(p => p.bot).length === 3, 'disconnected operator replaced by AI');
  assert.equal(second.game.players.length, 4);
  assert(!second.game.players.some(p => p.id === departedId && !p.bot));
  check('disconnection retains four operators through AI replacement');

  denied(await isolated.push('reset', { user_id: second.id }), 'unstarted separate lobby reset should be rejected');
  denied(await second.push('reset'), 'active mission reset is phase-gated');
  ok(await isolated.push('start'), 'solo launch');
  await until(() => isolated.game?.status === 'playing' && isolated.game.players.filter(p => p.bot).length === 3, 'one human plus three bots');
  assert(isolated.game.enemies_total >= 12 && isolated.game.enemies_total <= 20);
  assert.equal(isolated.game.enemies_remaining, isolated.game.enemies_total);
  check('reset permissions and phase gating; solo launch with three AI teammates');

  const successor = new Client('Successor', `I${nonce}`);
  ok(await successor.connect(), 'late join during mission');
  await until(() => successor.game.players.filter(p => !p.bot).length === 2, 'late join takes over a bot');
  assert.equal(successor.game.players.length, 4);
  isolated.close();
  await until(() => successor.lobby.leader_id === successor.id, 'automatic leader succession');
  check('late join takes over AI and a departed leader is replaced');

  second.close();
  await delay(150);
  const recreated = new Client('Fresh session', `S${nonce}`);
  ok(await recreated.connect(), 'rejoin abandoned code');
  assert.equal(recreated.lobby.status, 'waiting');
  assert.equal(recreated.lobby.members.length, 1);
  assert.equal(recreated.lobby.leader_id, recreated.id);
  assert.equal(recreated.game, null);
  assert.deepEqual(recreated.lobby.chat, []);
  check('last human departure immediately discards lobby and game state');
  console.log('\nAll live Phoenix Channels smoke checks passed.');
} catch (error) {
  console.error(`\nFAIL: ${error.stack}`);
  process.exitCode = 1;
} finally {
  for (const client of clients) client.close();
}
