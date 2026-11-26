import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MOVE_POINTS, STEPS, Tour } from '../Web/tour.js';

test('six steps with the live view, five without it: zooming needs a picture', () => {
  const tour = new Tour();
  tour.start(true);
  assert.equal(tour.total, 6);
  tour.start(false);
  assert.equal(tour.total, 5);
  assert.ok(!tour.steps.some((s) => s.key === 'zoom'));
  assert.equal(STEPS.length, 6);
});

test('each step is done by its own gesture, and only by it', () => {
  let changes = 0;
  const tour = new Tour(() => changes++);
  tour.start(true);
  tour.saw('left');
  assert.equal(tour.step.key, 'move', 'a click does not count for moving');
  tour.saw('move', MOVE_POINTS / 2);
  assert.equal(tour.step.key, 'move', 'a nudge is not yet a move');
  tour.saw('move', MOVE_POINTS / 2);
  assert.equal(tour.step.key, 'click');
  for (const gesture of ['left', 'scroll', 'right', 'drag']) tour.saw(gesture);
  assert.equal(tour.step.key, 'zoom');
  tour.saw('scroll');
  assert.equal(tour.step.key, 'zoom');
  tour.saw('pinch');
  assert.equal(tour.on, false, 'the last gesture ends the tour');
  assert.equal(changes, 7);
});

test('skipped, the tour ends; started again, it begins at the first step', () => {
  const tour = new Tour();
  tour.start(false);
  tour.saw('move', 100);
  tour.stop();
  assert.equal(tour.on, false);
  tour.saw('left');
  assert.equal(tour.step, null);
  tour.start(false);
  assert.equal(tour.step.key, 'move');
});
