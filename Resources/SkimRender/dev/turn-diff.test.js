const test = require('node:test');
const assert = require('node:assert/strict');
const A = require('../agent-events.js');
const snapshot = (threadId, turnId, diff) => ({ v: 1, type: 'turn.diff.snapshot', threadId, turnId, diff });

test('turn diffs replace snapshots, stay isolated by thread/turn, and do not mark a settled turn busy', () => {
  const state = A.createState();
  A.reduce(state, snapshot('a', '1', 'old'));
  A.reduce(state, snapshot('a', '1', 'latest'));
  A.reduce(state, snapshot('b', '1', 'other thread'));
  A.reduce(state, snapshot('a', '2', 'other turn'));
  assert.equal(state.turnDiffs.size, 3);
  assert.equal(state.turnDiffs.get(A.turnKey('a', '1')).diff, 'latest');
  assert.equal(state.turnDiffs.get(A.turnKey('b', '1')).diff, 'other thread');
  assert.equal(state.busy, false);
  A.reduce(state, snapshot('a', '1', ''));
  assert.equal(state.turnDiffs.get(A.turnKey('a', '1')).diff, '');
  assert.equal(state.turnDiffs.get(A.turnKey('a', '2')).diff, 'other turn');
});

test('turn identity handles punctuation without collisions and refuses unidentified diffs', () => {
  assert.notEqual(A.turnKey('a:b', 'c'), A.turnKey('a', 'b:c'));
  const state = A.createState();
  A.reduce(state, snapshot(null, '1', 'unowned'));
  A.reduce(state, snapshot('a', null, 'unowned'));
  assert.equal(state.turnDiffs.size, 0);
});
