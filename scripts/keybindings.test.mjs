import test from 'node:test';
import assert from 'node:assert/strict';
import {DEFAULT_BINDINGS, loadBindings, bindingError, movementFor, supportedKey} from '../priv/static/assets/keybindings.mjs';

test('saved custom bindings survive serialisation and supersede the previous preset', () => {
  const bindings = {...DEFAULT_BINDINGS, up:'ArrowUp', down:'ArrowDown', left:'ArrowLeft', right:'ArrowRight', reload:'Space'};
  assert.deepEqual(loadBindings(JSON.stringify(bindings), 'edsf'), bindings);
  assert.deepEqual(movementFor(new Set(['ArrowUp','ArrowRight']),bindings),{x:1,y:-1});
  assert.deepEqual(movementFor(new Set(['KeyW']),bindings),{x:0,y:0});
  assert.deepEqual(movementFor(new Set(['ArrowLeft','ArrowRight']),bindings),{x:0,y:0});
});
test('missing or damaged preferences preserve EDSF migration or fall back safely', () => {
  assert.deepEqual(loadBindings('{broken',null),DEFAULT_BINDINGS);
  assert.equal(loadBindings(null,'edsf').left,'KeyS');
  assert.equal(loadBindings(null,'edsf').down,'KeyD');
  assert.deepEqual(loadBindings('null',null),DEFAULT_BINDINGS);
  assert.deepEqual(loadBindings('{}',null),DEFAULT_BINDINGS);
});
test('conflicts and browser navigation keys cannot create unusable bindings', () => {
  assert.match(bindingError({...DEFAULT_BINDINGS,reload:'KeyW'}),/assigned twice/);
  for(const code of ['Tab','Escape','Enter','MetaLeft','F5','']) assert.equal(supportedKey(code),false);
  assert.equal(bindingError(DEFAULT_BINDINGS),null);
  assert.deepEqual(loadBindings(JSON.stringify({...DEFAULT_BINDINGS,reload:'KeyW'}),null),DEFAULT_BINDINGS);
});
