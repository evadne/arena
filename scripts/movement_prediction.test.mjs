import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { CollisionMap, MovementPrediction, movePlayer } from '../priv/static/assets/movement_prediction.mjs';
const map = { width: 640, height: 640, tile_size: 32, floor_tiles: Array.from({length:18}, (_,x) => Array.from({length:18},(_,y)=>[x+1,y+1])).flat() };
const snapshot = (time=0, x=100, control={x:0,y:0}) => ({ round_id:1, seed:7, elapsed_ms:time, status:'playing', map, control, players:[{id:'me',x,y:100,hp:100}] });

test('client collision matches authoritative Elixir across generated walls, corners and long substeps', () => {
  const output = execFileSync('mix', ['run', '--no-start', 'scripts/movement_fixtures.exs'], {encoding:'utf8', maxBuffer:4*1024*1024});
  const fixtures = JSON.parse(output.trim().split('\n').at(-1));
  const maps = Object.fromEntries(Object.entries(fixtures.maps).map(([seed,map])=>[seed,new CollisionMap(map)]));
  assert.ok(fixtures.cases.length > 500);
  for (const {seed, origin:[x,y], delta:[dx,dy], expected} of fixtures.cases) {
    const actual=maps[seed].move({x,y},dx,dy);
    assert.ok(Math.abs(actual.x-expected[0]) < 1e-8 && Math.abs(actual.y-expected[1]) < 1e-8, JSON.stringify({seed,x,y,dx,dy,actual,expected}));
  }
});
test('normalised diagonal speed, exact tangency and solid out-of-bounds', () => {
  const collision=new CollisionMap(map);
  assert.equal(collision.fits({x:42,y:100}),true);
  assert.equal(collision.fits({x:41.99,y:100}),false);
  assert.equal(collision.fits({x:-1,y:100}),false);
  const p=movePlayer(collision,{x:100,y:100},{x:1,y:1},50);
  assert.ok(Math.abs(Math.hypot(p.x-100,p.y-100)-7)<1e-8);
});
test('movement begins on the next render before any server response, for multiple RTTs', () => {
  for (const rtt of [0,60,120,240]) {
    const p=new MovementPrediction(); p.setRTT(rtt); p.accept(snapshot(), 'me',0);
    p.input({x:1,y:0},0);
    assert.ok(Math.abs(p.sample(16).x-102.24)<1e-8);
    p.input({x:0,y:0},16);
    assert.equal(p.sample(32).x,p.sample(16).x);
  }
});
test('render schedule never feeds partial positions into the next movement tick', () => {
  const results=[];
  for (const hz of [30,60,144]) {
    const p=new MovementPrediction(); p.accept(snapshot(),'me',0); p.input({x:1,y:1},0);
    for(let t=0;t<100;t+=1000/hz) p.sample(t);
    results.push(p.sample(100));
  }
  assert.deepEqual(results[0],results[1]); assert.deepEqual(results[1],results[2]);
});
test('reversals use their actual time, keepalives grant no extra displacement and stalls are bounded', () => {
  const p=new MovementPrediction(); p.accept(snapshot(),'me',0); p.input({x:1,y:0},0);
  for(let t=1;t<50;t++) p.input({x:1,y:0},t);
  assert.ok(Math.abs(p.sample(50).x-107)<1e-8);
  p.input({x:-1,y:0},50);
  assert.ok(Math.abs(p.sample(100).x-100)<1e-8);
  assert.deepEqual(p.sample(500),p.sample(10000));
  assert.equal(p.inputs.length,2);
});
test('reconciliation converges, and death, repeated-seed rounds and suspension reset prediction', () => {
  const p=new MovementPrediction(); p.accept(snapshot(),'me',0); p.input({x:1,y:0},0);
  p.accept(snapshot(50,103,{x:1,y:0}),'me',60);
  assert.ok(Math.abs(p.sample(160).x-p.forecast(160).x)<1e-8);
  p.suspend(); assert.equal(p.sample(200).x,103);
  p.accept({...snapshot(100,110), players:[{id:'me',x:110,y:100,hp:0}]},'me',110);
  assert.equal(p.sample(500).x,110);
  p.accept({...snapshot(0,400),round_id:2},'me',120);
  assert.equal(p.sample(140).x,400); assert.equal(p.inputs.length,0);
});
test('focus return applies neutral input even when the last server control was moving', () => {
  const p=new MovementPrediction(); p.accept(snapshot(0,100,{x:1,y:0}),'me',0);
  p.suspend(); p.input({x:0,y:0},10);
  assert.equal(p.sample(30).x,p.sample(10).x);
});
