import test from 'node:test';
import assert from 'node:assert/strict';
import { WeaponFeedback } from '../priv/static/assets/weapon_feedback.mjs';
const game = (changes={})=>({round_id:1,status:'playing',players:[{id:'me',hp:100,ammo:20,reload_ms:0,last_effect_id:0,...changes}]});
test('trigger sounds immediately, cadence is bounded and echoes are suppressed only for the shooter',()=>{
  const w=new WeaponFeedback(); w.accept(game(),'me',0);
  assert.equal(w.fire(0,true),1); assert.equal(w.fire(16,true),null);
  assert.equal(w.fire(200,true),2);
  assert.ok(w.echoed({local:true,effect_id:1})); assert.ok(!w.echoed({local:false,effect_id:1}));
  w.accept(game({ammo:19,last_effect_id:1}),'me',220); assert.equal(w.pending.size,1);
});
test('pending shots reserve ammo, reload/death/stalls stop cosmetics and new rounds clear them',()=>{
  const w=new WeaponFeedback(); w.accept(game({ammo:1}),'me',0);
  assert.equal(w.fire(0,true),1); assert.equal(w.fire(200,true),null);
  w.accept(game({reload_ms:1000,ammo:0,last_effect_id:1}),'me',220);
  assert.equal(w.fire(400,true),null);
  w.accept(game({hp:0}),'me',500); assert.equal(w.fire(500,true),null);
  w.accept({...game(),round_id:2},'me',600); assert.equal(w.pending.size,0);
  assert.ok(!w.echoed({local:true,effect_id:1})); assert.equal(w.fire(900,true),null);
});
test('reconnect resumes effect ids and explicit reload blocks immediate fire',()=>{
  const w=new WeaponFeedback(); w.accept(game({last_effect_id:23}),'me',0);
  assert.equal(w.fire(0,true,true),null); assert.equal(w.fire(0,false),null);
  assert.equal(w.fire(0,true),24);
});
test('immediate tracer stops at the nearest visible live target or solid wall',async()=>{
  const {tracerEnd}=await import('../priv/static/assets/weapon_feedback.mjs');
  const origin={x:0,y:0},wall={x:300,y:0};
  assert.deepEqual(tracerEnd(origin,0,wall,[{x:100,y:0,hp:100},{x:200,y:0,hp:100}]),{x:89,y:0});
  assert.deepEqual(tracerEnd(origin,0,wall,[{x:400,y:0,hp:100},{x:100,y:0,hp:0}]),wall);
});
