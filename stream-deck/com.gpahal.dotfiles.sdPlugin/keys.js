// What the Mac plugin and the Ubuntu daemon (stream-deck/linux, which gets a copy) share: the
// stat keys' update loop and the open-in runs. Each keeps its own transport and devices.

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
    }
  }

  // CPU and network are rates, so the first sample waits a moment
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

  return { keys, start, stop };
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

module.exports = { createStatKeys, createRunner };
