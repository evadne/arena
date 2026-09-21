#!/usr/bin/env node
// Measures the actual Phoenix/WebSocket path, not an unrelated HTTP health check.
import { performance } from 'node:perf_hooks';
import { FrameDecoder } from '../priv/static/assets/frame_decoder.mjs';
const decoder = new FrameDecoder();
const ackDelay = Number(process.env.PROBE_ACK_DELAY_MS || 0);
const base = process.env.ARENA_URL || 'http://localhost:4000';
const duration = Number(process.env.PROBE_SECONDS || 12) * 1000;
const protocol = Number(process.env.ARENA_PROTOCOL || 1);
const endpoint = new URL('/socket/websocket?vsn=2.0.0', base);
endpoint.protocol = endpoint.protocol === 'https:' ? 'wss:' : 'ws:';
const ws = new WebSocket(endpoint);
const topic = `lobby:${process.env.PROBE_CODE || `P${Date.now().toString(36).toUpperCase()}`}`;
const times = [], bytes = [], rtts = [], pending = new Map();
let ref = 0, started, tickFirst, tickLast, lobby;
const send = (event, payload = {}, target = topic) => {
  const id = String(++ref);
  if (event === 'heartbeat') pending.set(id, performance.now());
  ws.send(JSON.stringify([target === topic ? '1' : null, id, target, event, payload]));
};
const failure = setTimeout(() => { console.error('Probe timed out'); ws.close(); process.exitCode = 1; }, duration + 15000);
let heartbeats;
ws.addEventListener('open', () => send('phx_join', {name: 'Network probe', protocol}));
ws.addEventListener('error', () => { console.error('WebSocket connection failed'); clearTimeout(failure); process.exitCode=1; });
ws.addEventListener('message', ({data}) => {
  const [, replyRef, , event, payload] = JSON.parse(data);
  let snapshot = payload;
  if (pending.has(replyRef)) { rtts.push(performance.now() - pending.get(replyRef)); pending.delete(replyRef); }
  if (event === 'phx_reply' && replyRef === '1') {
    if (payload.status !== 'ok') throw new Error(JSON.stringify(payload));
    lobby = payload.response.lobby.code;
    send('start');
    send('heartbeat', {}, 'phoenix');
    heartbeats = setInterval(() => send('heartbeat', {}, 'phoenix'), 500);
  }
  if (event === 'frame') {
    const result = decoder.apply(payload);
    if (result.status === 'resync') { send('frame_resync'); return; }
    if (result.status !== 'applied') return;
    snapshot = result.snapshot;
    if (ackDelay) setTimeout(() => { if(ws.readyState === WebSocket.OPEN) send('frame_ack',{seq:result.seq}); }, ackDelay);
    else send('frame_ack',{seq:result.seq});
  } else if (event !== 'snapshot') return;
  if (protocol === 3 && event !== 'frame') throw new Error('Server does not support protocol 3');
  if (started === undefined) {
    started = performance.now(); tickFirst = snapshot.tick;
    send('order', {order:'aggro'});
    setTimeout(finish, duration);
  }
  times.push(performance.now()); bytes.push(Buffer.byteLength(data)); tickLast = snapshot.tick;
});
function stats(values) {
  const v = [...values].sort((a,b)=>a-b);
  return {min: +v[0]?.toFixed(1), median: +v[Math.floor(v.length*.5)]?.toFixed(1), p95: +v[Math.min(v.length-1,Math.floor(v.length*.95))]?.toFixed(1), max: +v.at(-1)?.toFixed(1)};
}
function finish() {
  clearTimeout(failure); clearInterval(heartbeats);
  const intervals = times.slice(1).map((t,i)=>t-times[i]);
  console.log(JSON.stringify({base,protocol,ack_delay_ms:ackDelay,lobby,seconds:duration/1000,snapshots:times.length,ticks:tickLast-tickFirst,rtt_ms:stats(rtts),arrival_interval_ms:stats(intervals),gaps_over_100ms:intervals.filter(x=>x>100).length,snapshot_bytes:stats(bytes),bytes_per_second:Math.round(bytes.reduce((a,b)=>a+b,0)/(duration/1000))},null,2));
  ws.close();
}
