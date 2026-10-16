// Runs bin/open-in for each key press of the plugin's actions, shows on the key whether it
// worked, and passes what it printed to Stream Deck's log, which Stream Deck writes to
// ~/Library/Logs/ElgatoStreamDeck/com.gpahal.dotfiles0.log. Stream Deck starts this with -port, -pluginUUID, and -registerEvent, and Node 24's
// built-in WebSocket talks to it, so the plugin needs no packages.
const { execFile } = require("node:child_process");
const path = require("node:path");

const arg = (name) => process.argv[process.argv.indexOf(name) + 1];
const openIn = path.join(__dirname, "bin", "open-in");
const socket = new WebSocket(`ws://127.0.0.1:${arg("-port")}`);
const send = (message) => socket.send(JSON.stringify(message));

socket.onopen = () => send({ event: arg("-registerEvent"), uuid: arg("-pluginUUID") });
socket.onclose = () => process.exit(0);
socket.onmessage = ({ data }) => {
  const { event, action, context } = JSON.parse(data);
  if (event !== "keyDown") return;
  // com.gpahal.dotfiles.finder runs open-in finder
  const target = action.slice(action.lastIndexOf(".") + 1);
  execFile("/bin/bash", [openIn, target], (error, stdout, stderr) => {
    for (const line of `${stdout}${stderr}`.split("\n").filter(Boolean)) {
      send({ event: "logMessage", payload: { message: line } });
    }
    send({ event: error ? "showAlert" : "showOk", context });
  });
};
