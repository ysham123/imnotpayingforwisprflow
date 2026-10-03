'use strict';

// Optional development fixture. Electron is downloaded separately into work/
// and is never included in Local Dictation or its release bundle.
const { app, BrowserWindow, Menu, clipboard, session } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const [directory, token] = process.argv.slice(2);
if (!directory || !token || !path.isAbsolute(directory) || !/^[A-Fa-f0-9-]+$/.test(token)) process.exit(2);
const html = path.join(__dirname, 'WebInsertionFixture.html');
const allowedURL = pathToFileURL(html).href;
app.setName('Local Dictation Electron fixture');
app.setPath('userData', path.join(directory, 'profile'));
app.commandLine.appendSwitch('disable-background-networking');

let window;
let activeField = 'input';
let nativeDeferredRequests = 0;
let lastID = -1;
let busy = false;
let timer;

function delayedPaste() {
  nativeDeferredRequests++;
  // Read the native clipboard after 1.6 seconds. This deliberately differs
  // from delayedDOM, which saves DOM clipboardData immediately on paste.
  setTimeout(async () => {
    if (!window || window.isDestroyed() || !window.isFocused() || activeField !== 'delayedRead') return;
    const data = { text: await clipboard.readText() };
    await window.webContents.executeJavaScript(`window.fixture.deferredInsert(${JSON.stringify(data)})`);
  }, 1600);
}

function paste() {
  if (!window || window.isDestroyed() || !window.isFocused()) return;
  if (activeField === 'delayedRead') delayedPaste();
  else window.webContents.paste();
}

async function receiveCommand() {
  if (busy || !window || window.isDestroyed()) return;
  let command;
  try { command = JSON.parse(fs.readFileSync(path.join(directory, 'command.json'), 'utf8')); }
  catch { return; }
  if (command.token !== token || !Number.isInteger(command.id) || command.id === lastID) return;
  lastID = command.id;
  if (command.quit) { app.quit(); return; }
  busy = true;
  try {
    if (command.field) {
      activeField = command.field;
      nativeDeferredRequests = 0;
    }
    if (command.focus) {
      app.focus({ steal: true });
      window.show();
      window.focus();
      window.webContents.focus();
    }
    const result = await window.webContents.executeJavaScript(`window.fixture.command(${JSON.stringify(command)})`);
    const reply = { ...result, id: command.id, token, pid: process.pid, engine: 'Electron', nativeDeferredRequests,
      appActive: window.isFocused(), keyWindow: window.isFocused() };
    const temporary = path.join(directory, 'reply.tmp');
    fs.writeFileSync(temporary, JSON.stringify(reply));
    fs.renameSync(temporary, path.join(directory, 'reply.json'));
  } catch (error) {
    fs.writeFileSync(path.join(directory, 'reply.json'), JSON.stringify({ id: command.id, token, pid: process.pid, engine: 'Electron', error: String(error) }));
  } finally { busy = false; }
}

app.whenReady().then(async () => {
  const isolated = session.fromPartition(`dictation-fixture-${token}`, { cache: false });
  isolated.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  isolated.webRequest.onBeforeRequest((details, callback) => callback({ cancel: details.url !== allowedURL }));
  window = new BrowserWindow({
    width: 790, height: 720, title: 'Local Dictation synthetic Electron fixture',
    webPreferences: {
      session: isolated, nodeIntegration: false, contextIsolation: true, sandbox: true,
      spellcheck: false, devTools: false, backgroundThrottling: false
    }
  });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event, url) => { if (url !== allowedURL) event.preventDefault(); });
  window.webContents.on('before-input-event', (event, input) => {
    if (activeField === 'delayedRead' && input.type === 'keyDown' && input.meta && input.key.toLowerCase() === 'v') {
      event.preventDefault();
      delayedPaste();
    }
  });
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Fixture', submenu: [{ role: 'quit' }] },
    { label: 'Edit', submenu: [{ label: 'Paste', accelerator: 'CommandOrControl+V', click: paste }] }
  ]));
  await window.loadFile(html);
  window.show(); window.focus();
  timer = setInterval(receiveCommand, 20);
}).catch(error => { console.error('Synthetic Electron fixture failed:', String(error)); app.exit(1); });

app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => { if (timer) clearInterval(timer); });
process.on('SIGTERM', () => app.quit());
