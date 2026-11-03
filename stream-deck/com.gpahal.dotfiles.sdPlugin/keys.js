// What the Mac plugin and the Ubuntu daemon (stream-deck/linux, which gets a copy) share: the
// stat keys' update loop, the open-in runs, and the Mic key's tap and hold. Each keeps its own transport and devices.

// A second New Tab press while the first runs would open a second tab and paste twice
const ONE_AT_A_TIME = new Set(["chrome-tab"]);

// keys maps each stat key's id (a context, or a key index) to its kind. draw(id, svg) shows one;
// ready() says whether there's anywhere to draw.
function createStatKeys({ stats, sampler, log, draw, ready = () => true, intervalMs = 2000, firstUpdateMs = 500 }) {
  const keys = new Map();
  // So each render error is logged once
  const failing = new Set();
  let timer = null;
  let firstUpdate = null;
  let busy = false;
  let again = false;

  // A placeholder on error, so one bad stat leaves the other keys updating
  function render(kind, sample) {
    try {
      const svg = stats.render(kind, sample);
      failing.delete(kind);
      return svg;
    } catch (error) {
      if (!failing.has(kind)) log(`ERROR couldn't draw the ${kind} key: ${error.message}`);
      failing.add(kind);
      return stats.placeholder(kind);
    }
  }

  async function update() {
    if (busy || !ready() || keys.size === 0) return;
    busy = true;
    try {
      const sample = await sampler.sample([...new Set(keys.values())]);
      await Promise.all([...keys].map(([id, kind]) => draw(id, render(kind, sample))));
    } catch (error) {
      log(`ERROR couldn't update the stat keys: ${error.message}`);
    } finally {
      busy = false;
      if (again) {
        again = false;
        update();
      }
    }
  }

  // Now rather than at the next tick, as after a press changes what a key shows
  function refresh() {
    if (busy) again = true;
    else update();
  }

  // CPU, network, and Linux's top are rates, so the first sample waits a moment
  function start() {
    if (timer) return;
    sampler.reset();
    timer = setInterval(update, intervalMs);
    firstUpdate = setTimeout(update, firstUpdateMs);
  }

  function stop() {
    clearInterval(timer);
    clearTimeout(firstUpdate);
    timer = null;
    sampler.stop();
  }

  return { keys, start, stop, refresh };
}

// runOpenIn(target, done) runs bin/open-in, and done(error, output) gets its log lines. A key
// whose run fails gets onError.
function createRunner({ runOpenIn, log }) {
  const running = new Set();
  return (target, onError) => {
    if (running.has(target)) return;
    if (ONE_AT_A_TIME.has(target)) running.add(target);
    runOpenIn(target, (error, output) => {
      running.delete(target);
      for (const line of output.split("\n").filter(Boolean)) log(line);
      if (error) onError();
    });
  };
}

// A key that does one thing when tapped and another when held: onHold runs once the key has been
// down holdMs, without waiting for its release, and onTap on a release before then
function createHold({ onTap, onHold, holdMs = 500 }) {
  const timers = new Map();
  return {
    down(id) {
      clearTimeout(timers.get(id));
      timers.set(
        id,
        setTimeout(() => {
          timers.delete(id);
          onHold(id);
        }, holdMs),
      );
    },
    up(id) {
      if (!timers.has(id)) return;
      clearTimeout(timers.get(id));
      timers.delete(id);
      onTap(id);
    },
  };
}

module.exports = { createStatKeys, createRunner, createHold };
