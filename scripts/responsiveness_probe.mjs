#!/usr/bin/env node
// Real Channels traffic with delayed input AND delayed frame delivery. Run locally.
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';
import { FrameDecoder } from '../priv/static/assets/frame_decoder.mjs';
import { SnapshotBuffer, interpolateActor } from '../priv/static/assets/snapshot_buffer.mjs';
import { CollisionMap, MovementPrediction } from '../priv/static/assets/movement_prediction.mjs';
const base=process.env.ARENA_URL || 'http://127.0.0.1:4107';
const endpoint=new URL('/socket/websocket?vsn=2.0.0',base); endpoint.protocol=endpoint.protocol==='https:'?'wss:':'ws:';
const jitter=Number(process.env.PROBE_JITTER_MS || 0);
for (const rtt of [0,60,120,240]) {
  const ws=new WebSocket(endpoint), decoder=new FrameDecoder(), legacy=new SnapshotBuffer(50), predictor=new MovementPrediction();
  predictor.setRTT(rtt);
  const topic=`lobby:R${Date.now().toString(36).toUpperCase()}`;
  const pending=new Map(), timers=new Set(); let ref=0, userId, game, active=true, received=0;
  const due={input:0,frame:0}; let jitterCounter=0;
  const defer=(fn,lane)=>{
    const now=performance.now();
    const delay=rtt/2+(jitter ? (++jitterCounter*17)%Math.ceil(jitter+1) : 0);
    due[lane]=Math.max(now+delay,due[lane]);
    const timer=setTimeout(()=>{timers.delete(timer);if(active)fn();},due[lane]-now);timers.add(timer);
  };
  const send=(event,payload={})=>{
    const id=String(++ref); defer(()=>ws.send(JSON.stringify(['1',id,topic,event,payload])), 'input'); return id;
  };
  const request=(event,payload={})=>new Promise((resolve,reject)=>{
    const id=send(event,payload); const timer=setTimeout(()=>reject(new Error(`${event} timeout`)),5000);
    pending.set(id,(response)=>{clearTimeout(timer);assert.equal(response.status,'ok');resolve(response.response);});
  });
  ws.addEventListener('message',({data})=>defer(()=>{
    const [,id,,event,payload]=JSON.parse(data);
    if(event==='phx_reply') pending.get(id)?.(payload);
    if(event!=='frame')return;
    const result=decoder.apply(payload); assert.equal(result.status,'applied');
    game=result.snapshot; received++;
    const now=performance.now(); legacy.push(game,now); predictor.accept(game,userId,now);
    send('frame_ack',{seq:result.seq});
  }, 'frame'));
  await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
  const joined=await request('phx_join',{name:'Responsiveness probe',protocol:3});userId=joined.user_id;
  await request('start');
  for(let i=0;!game&&i<100;i++)await sleep(20);
  assert.ok(game,'Initial snapshot');
  await sleep(250);
  const me=game.players.find(p=>p.id===userId), collision=new CollisionMap(game.map);
  const direction=[{x:1,y:0},{x:0,y:1},{x:-1,y:0},{x:0,y:-1}].find(d=>collision.safeSegment(me,{x:me.x+d.x*70,y:me.y+d.y*70}));
  assert.ok(direction,'A clear movement lane at spawn');
  let held=direction; const started=performance.now();
  predictor.input(held,started);
  const input=()=>send('input',{...held,aim:0,shoot:false,reload:false,round_id:game.round_id});
  input();const inputs=setInterval(input,1000/30);
  let visualMs,oldVisualMs,authorityMs;
  const records=[];
  const renderer=setInterval(()=>{
    const now=performance.now(), actor=game.players.find(p=>p.id===userId);
    const predicted=predictor.sample(now), old=interpolateActor(actor,legacy.sample(now),'players');
    const delta=(p)=>(p.x-me.x)*direction.x+(p.y-me.y)*direction.y;
    if(visualMs===undefined&&delta(predicted)>1)visualMs=now-started;
    if(oldVisualMs===undefined&&delta(old)>1)oldVisualMs=now-started;
    if(authorityMs===undefined&&delta(actor)>1)authorityMs=now-started;
    assert.ok(collision.fits(predicted),'Predicted position stays outside walls');
    records.push({at:now-started,x:predicted.x,y:predicted.y});
  },1000/60);
  await sleep(400);held={x:0,y:0};predictor.input(held,performance.now());input();
  await sleep(500);clearInterval(inputs);clearInterval(renderer);
  assert.ok(visualMs<40,`Immediate visual response: ${visualMs}`);
  assert.ok(Number.isFinite(authorityMs)&&Number.isFinite(oldVisualMs));
  console.log(JSON.stringify({rtt_added_ms:rtt,jitter_per_leg_ms:jitter,first_movement_ms:{predicted:+visualMs.toFixed(1),previous_interpolation:+oldVisualMs.toFixed(1),authoritative:+authorityMs.toFixed(1)},max_correction_px:+predictor.maxCorrection.toFixed(2),frames:received}));
  active=false;for(const timer of timers)clearTimeout(timer);ws.close();await sleep(30);
}
