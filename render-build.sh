#!/usr/bin/env bash
set -euo pipefail

echo "🛠️  Generating Relationship-y source tree..."

mkdir -p server web docker data

# ---------- package.json ----------
cat > package.json <<'JSON'
{
  "name": "relationship-y",
  "version": "1.0.0",
  "private": true,
  "description": "A tiny end-to-end encrypted couples Q&A web app.",
  "license": "MIT",
  "scripts": {
    "dev": "concurrently \"node server/index.js\" \"vite --config web/vite.config.js\"",
    "build:web": "vite build --config web/vite.config.js",
    "start": "node server/index.js"
  },
  "dependencies": {
    "better-sqlite3": "^9.4.0",
    "cors": "^2.8.5",
    "express": "^4.19.2",
    "nanoid": "3.3.7",
    "ws": "^8.16.0"
  },
  "devDependencies": {
    "concurrently": "^8.2.2",
    "vite": "^5.2.0"
  }
}
JSON

# ---------- server/db.js ----------
cat > server/db.js <<'JS'
const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

const dataDir = path.join(__dirname, '..', 'data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

const db = new Database(path.join(dataDir, 'data.sqlite'));
db.pragma('journal_mode = WAL');

db.exec(`
CREATE TABLE IF NOT EXISTS rooms (
  id TEXT PRIMARY KEY,
  created_at INTEGER
);

CREATE TABLE IF NOT EXISTS questions (
  id TEXT PRIMARY KEY,
  room_id TEXT,
  text TEXT,
  created_at INTEGER
);

CREATE TABLE IF NOT EXISTS answers (
  id TEXT PRIMARY KEY,
  question_id TEXT,
  user_id TEXT,
  ciphertext BLOB,
  iv BLOB,
  salt BLOB,
  created_at INTEGER
);
`);

module.exports = db;
JS

# ---------- server/index.js ----------
cat > server/index.js <<'JS'
const express = require('express');
const cors = require('cors');
const path = require('path');
const fs = require('fs');
const { nanoid } = require('nanoid');
const db = require('./db');
const http = require('http');
const WebSocket = require('ws');

const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));

// Very simple in-memory presence map for WS fanout
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });
const roomSockets = new Map(); // roomId -> Set(ws)

wss.on('connection', (ws) => {
  let roomId = null;
  ws.on('message', msg => {
    try {
      const data = JSON.parse(msg);
      if (data.type === 'join') {
        roomId = data.roomId;
        if (!roomSockets.has(roomId)) roomSockets.set(roomId, new Set());
        roomSockets.get(roomId).add(ws);
        ws.send(JSON.stringify({ type: 'joined', roomId }));
      }
    } catch(e) {}
  });
  ws.on('close', () => {
    if (roomId && roomSockets.has(roomId)) {
      roomSockets.get(roomId).delete(ws);
    }
  });
});

function broadcastRoom(roomId, payload) {
  const set = roomSockets.get(roomId);
  if (!set) return;
  for (const ws of set) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(payload));
    }
  }
}

// DB helpers
const stmtCreateRoom = db.prepare(`INSERT INTO rooms (id, created_at) VALUES (?, ?)`);
const stmtCreateQ = db.prepare(`INSERT INTO questions (id, room_id, text, created_at) VALUES (?, ?, ?, ?)`);
const stmtGetQ = db.prepare(`SELECT * FROM questions WHERE room_id = ? ORDER BY created_at DESC LIMIT 1`);
const stmtGetAnswers = db.prepare(`SELECT * FROM answers WHERE question_id = ?`);
const stmtInsertAnswer = db.prepare(`
  INSERT INTO answers (id, question_id, user_id, ciphertext, iv, salt, created_at)
  VALUES (?, ?, ?, ?, ?, ?, ?)
`);

// API
app.post('/api/room', (_req, res) => {
  const id = nanoid(8).toUpperCase();
  stmtCreateRoom.run(id, Date.now());
  const seedQs = [
    "What’s one small thing your partner did recently that made you smile?",
    "What’s a tiny ritual you want to start together?",
    "Describe your ideal cozy evening, in 3 ingredients.",
    "What song feels like 'us' this week—and why?"
  ];
  const text = seedQs[Math.floor(Math.random()*seedQs.length)];
  const qid = nanoid();
  stmtCreateQ.run(qid, id, text, Date.now());
  res.json({ roomId: id });
});

app.get('/api/room/:roomId/question', (req, res) => {
  const roomId = req.params.roomId;
  const q = stmtGetQ.get(roomId);
  if (!q) return res.status(404).json({ error: 'No question' });
  res.json({ questionId: q.id, text: q.text });
});

app.post('/api/room/:roomId/question', (req, res) => {
  const { text } = req.body;
  if (!text || text.length > 2000) return res.status(400).json({ error: 'Invalid question' });
  const roomId = req.params.roomId;
  const qid = nanoid();
  stmtCreateQ.run(qid, roomId, text, Date.now());
  broadcastRoom(roomId, { type: 'newQuestion', questionId: qid });
  res.json({ questionId: qid });
});

app.post('/api/answer', (req, res) => {
  const { questionId, userId, ciphertext, iv, salt } = req.body;
  if (!questionId || !userId || !ciphertext || !iv || !salt) return res.status(400).json({ error: 'Missing fields' });
  const id = nanoid();
  stmtInsertAnswer.run(id, questionId, userId, Buffer.from(ciphertext, 'base64'), Buffer.from(iv, 'base64'), Buffer.from(salt, 'base64'), Date.now());

  // Only signal "ready" once there are answers from two *distinct* users
  const distinct = db.prepare('SELECT COUNT(DISTINCT user_id) AS c FROM answers WHERE question_id = ?')
                     .get(questionId).c;
  if (distinct >= 2) {
    const qRow = db.prepare('SELECT room_id FROM questions WHERE id = ?').get(questionId);
    broadcastRoom(qRow.room_id, { type: 'readyToReveal', questionId });
  }
  res.json({ ok: true });
});

app.get('/api/answers/:questionId', (req, res) => {
  const questionId = req.params.questionId;
  // Collapse to latest answer per user_id
  const all = stmtGetAnswers.all(questionId).sort((a,b) => a.created_at - b.created_at);
  const byUser = new Map();
  for (const r of all) byUser.set(r.user_id, r);
  const rows = [...byUser.values()].map(r => ({
    userId: r.user_id,
    ciphertext: r.ciphertext.toString('base64'),
    iv: r.iv.toString('base64'),
    salt: r.salt.toString('base64')
  }));
  res.json({ answers: rows });
});

app.get('/api/health', (_req, res) => res.json({ ok: true }));

// Serve static frontend from web/dist in production
const distPath = path.join(__dirname, '..', 'web', 'dist');
if (fs.existsSync(distPath)) {
  app.use(express.static(distPath));
  app.get('*', (_req, res) => res.sendFile(path.join(distPath, 'index.html')));
}

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Relationship-y running on http://localhost:${PORT}`));
JS

# ---------- web/index.html ----------
cat > web/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1.0" />
  <title>Relationship-y ❤️</title>
  <link rel="stylesheet" href="./styles.css" />
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; connect-src 'self' ws: wss: http: https:; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; base-uri 'none'; form-action 'self';">
</head>
<body>
  <div class="sky">
    <div class="stars"></div>
    <div class="clouds"></div>
    <header>
      <h1>Relationship-y <span class="heart">❤️</span></h1>
      <p class="tag">A cozy space for two</p>
    </header>

    <main>
      <section class="card">
        <div class="brand-row">
          <div class="badge badge-spacepup" title="space pup">🛸🐶</div>
          <div class="badge badge-beagle" title="beagle in clouds">☁️🐾</div>
        </div>

        <div class="room-controls">
          <button id="createRoom">Create Room</button>
          <div class="or">or</div>
          <input id="roomId" placeholder="Enter ROOM CODE" maxlength="12" autocomplete="off">
          <button id="joinRoom">Join</button>
        </div>

        <div id="roomArea" class="hidden">
          <div class="secret-row">
            <input id="passphrase" placeholder="Shared passphrase (keep private)" autocomplete="off">
            <input id="userId" placeholder="Your nickname" autocomplete="off">
          </div>

          <div class="question">
            <div id="qText">—</div>
          </div>

          <textarea id="answer" placeholder="Type your answer…"></textarea>
          <div class="actions">
            <button id="submit">Submit (locks your view)</button>
            <button id="newQ" class="ghost">New Question</button>
          </div>

          <div id="status" class="status"></div>

          <div id="reveal" class="reveal hidden">
            <h3>Both of you answered! 💌</h3>
            <div class="answers">
              <div>
                <h4>You</h4>
                <pre id="yourAns"></pre>
              </div>
              <div>
                <h4>Partner</h4>
                <pre id="partnerAns"></pre>
              </div>
            </div>
          </div>
        </div>
      </section>
    </main>

    <footer>
      <small>End-to-end encrypted. Keep your passphrase safe.</small>
    </footer>
  </div>

  <script type="module" src="./main.js"></script>
</body>
</html>
HTML

# ---------- web/styles.css ----------
cat > web/styles.css <<'CSS'
:root{
  --blue:#2b6ef0;
  --ink:#111;
  --cream:#fffdf7;
  --pink:#ff6ea1;
  --cloud:#eef4ff;
  --mint:#c9f3ef;
  --card:#ffffffcc;
  --shadow: 0 12px 30px rgba(0,0,0,.12);
}
*{ box-sizing: border-box; }
body,html{ margin:0; height:100%; font-family: ui-rounded, system-ui, -apple-system, Segoe UI, Roboto, sans-serif; color:var(--ink); }
.sky{ min-height:100%; background: radial-gradient(1200px 800px at 50% -100px, var(--blue) 0%, #0e1a3a 60%, #060c1e 100%); position:relative; }
.stars, .clouds{ position:absolute; inset:0; pointer-events:none }
.stars{ background-image: radial-gradient(#fff 1px, transparent 1px), radial-gradient(#fff6 1px, transparent 1px); background-size: 40px 40px, 80px 80px; opacity:.25; }
.clouds{ background: radial-gradient(circle at 20% 30%, var(--cloud) 0 10%, transparent 11%), radial-gradient(circle at 80% 35%, var(--cloud) 0 8%, transparent 9%), radial-gradient(circle at 60% 10%, #fff 0 6%, transparent 7%); opacity:.45; mix-blend-mode: screen; }
header{ text-align:center; padding:40px 20px; color:#fff; }
h1{ margin:0; font-size:42px; letter-spacing:.5px }
.tag{ margin:6px 0 0; opacity:.8 }
main{ display:flex; justify-content:center; padding:20px }
.card{ width:min(760px, 94vw); background:var(--card); border-radius:20px; box-shadow: var(--shadow); backdrop-filter: blur(8px); padding:22px; }
.brand-row{ display:flex; gap:8px; justify-content:flex-end; }
.badge{ font-size:20px; padding:6px 10px; border-radius:999px; background:#fff; box-shadow: var(--shadow); }
.badge-spacepup{ border:2px dashed var(--blue); }
.badge-beagle{ border:2px dashed #222; }
.room-controls{ display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-top:6px; }
.or{ opacity:.6 }
input, textarea{ width:100%; padding:12px 14px; border:2px solid #0000; background:#fff; border-radius:14px; box-shadow: var(--shadow); outline:none; }
input:focus, textarea:focus{ border-color: var(--blue); }
textarea{ min-height:120px; resize:vertical; }
.secret-row{ display:grid; grid-template-columns: 1fr 1fr; gap:10px; margin:12px 0; }
.question{ margin:14px 0; background: linear-gradient(135deg, var(--mint), #fef0f4); border-radius:16px; padding:14px; }
#qText{ font-weight:600; }
.actions{ display:flex; gap:10px; align-items:center; margin-top:10px; }
button{ padding:12px 16px; border-radius:12px; border:none; background:var(--blue); color:#fff; font-weight:600; cursor:pointer; box-shadow: var(--shadow); }
button.ghost{ background:#fff; color:var(--blue); border:2px solid var(--blue); }
button:disabled{ opacity:.5; cursor:not-allowed }
.status{ margin-top:8px; font-size:14px; opacity:.8 }
.reveal{ margin-top:18px; background:#fff; border-radius:16px; padding:12px; }
.answers{ display:grid; grid-template-columns: 1fr 1fr; gap:12px }
pre{ white-space: pre-wrap; word-wrap: break-word; background:var(--cloud); padding:10px; border-radius:12px; }
footer{ text-align:center; color:#fff; opacity:.75; padding:20px; }
.hidden{ display:none; }
CSS

# ---------- web/main.js ----------
cat > web/main.js <<'JS'
function api(path) {
  const base = location.hostname === 'localhost' ? 'http://localhost:3000' : '';
  return base + path;
}

let state = { roomId: null, ws: null, questionId: null, submitted: false };

// --- Stable hidden ID stored in localStorage ---
const ME_KEY = 'meId';
function getMeId() {
  let id = localStorage.getItem(ME_KEY);
  if (!id) {
    id = 'u-' + (crypto.randomUUID?.() || Math.random().toString(36).slice(2));
    localStorage.setItem(ME_KEY, id);
  }
  return id;
}

async function deriveKey(passphrase, saltB64){
  const enc = new TextEncoder();
  const salt = saltB64 ? Uint8Array.from(atob(saltB64), c => c.charCodeAt(0)) : crypto.getRandomValues(new Uint8Array(16));
  const keyMaterial = await crypto.subtle.importKey('raw', enc.encode(passphrase), 'PBKDF2', false, ['deriveKey']);
  const key = await crypto.subtle.deriveKey(
    { name:'PBKDF2', salt, iterations: 100000, hash: 'SHA-256' },
    keyMaterial, { name:'AES-GCM', length:256 }, false, ['encrypt','decrypt']
  );
  return { key, salt };
}
function b64(bytes){ return btoa(String.fromCharCode(...new Uint8Array(bytes))); }
async function encryptText(text, passphrase){
  const { key, salt } = await deriveKey(passphrase);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const enc = new TextEncoder();
  const ct = await crypto.subtle.encrypt({ name:'AES-GCM', iv }, key, enc.encode(text));
  return { ciphertext: b64(ct), iv: b64(iv), salt: b64(salt) };
}
async function decryptText(ciphertextB64, ivB64, saltB64, passphrase){
  const { key } = await deriveKey(passphrase, saltB64);
  const iv = Uint8Array.from(atob(ivB64), c => c.charCodeAt(0));
  const data = Uint8Array.from(atob(ciphertextB64), c => c.charCodeAt(0));
  const dec = await crypto.subtle.decrypt({ name:'AES-GCM', iv }, key, data);
  return new TextDecoder().decode(dec);
}

const el = s => document.querySelector(s);

async function createRoom(){
  const r = await fetch(api('/api/room'), { method:'POST' }).then(r=>r.json());
  el('#roomId').value = r.roomId; joinRoom();
}
function joinRoom(){
  const roomId = el('#roomId').value.trim().toUpperCase();
  if(!roomId) return alert('Enter room code');
  state.roomId = roomId;
  el('#roomArea').classList.remove('hidden');
  connectWS(); loadQuestion();
}
function connectWS(){
  if (state.ws) try { state.ws.close(); } catch(e){}
  const wsUrl = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host;
  state.ws = new WebSocket(wsUrl);
  state.ws.addEventListener('open', () => state.ws.send(JSON.stringify({ type:'join', roomId: state.roomId })));
  state.ws.addEventListener('message', ev => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'newQuestion') {
      state.submitted = false; el('#answer').value = ''; el('#reveal').classList.add('hidden');
      state.questionId = msg.questionId; fetchQuestionText();
    }
    if (msg.type === 'readyToReveal' && msg.questionId === state.questionId) revealAnswers();
  });
}
async function fetchQuestionText(){
  const q = await fetch(api(`/api/room/${state.roomId}/question`)).then(r=>r.json());
  state.questionId = q.questionId; el('#qText').textContent = q.text;
}
async function loadQuestion(){ await fetchQuestionText(); }
async function submitAnswer(){
  const passphrase = el('#passphrase').value.trim();
  if(!passphrase) return alert('Add a shared passphrase first');
  const text = el('#answer').value.trim(); if(!text) return alert('Write an answer');
  el('#submit').disabled = true;
  el('#passphrase').disabled = true; // lock after submit to avoid mismatch
  const { ciphertext, iv, salt } = await encryptText(text, passphrase);
  await fetch(api('/api/answer'), {
    method:'POST', headers: { 'Content-Type':'application/json' },
    body: JSON.stringify({ questionId: state.questionId, userId: getMeId(), ciphertext, iv, salt })
  });
  state.submitted = true; el('#status').textContent = 'Answer locked. Waiting for your partner…';
}
async function revealAnswers(){
  const passphrase = el('#passphrase').value.trim();
  const myId = getMeId();
  const { answers } = await fetch(api(`/api/answers/${state.questionId}`)).then(r=>r.json());
  if(answers.length < 2) return;
  let myText = '', partnerText = '';
  let failedDecrypts = 0;
  for (const a of answers) {
    try { 
      const plain = await decryptText(a.ciphertext, a.iv, a.salt, passphrase);
      if (a.userId === myId) myText = plain; else partnerText = plain;
    } catch(e){ failedDecrypts++; }
  }
  if (failedDecrypts > 0) {
    el('#status').textContent = 'Passphrases don’t match. Make sure you both used the exact same passphrase.';
  } else {
    el('#status').textContent = '';
  }
  el('#yourAns').textContent = myText || '(not found)';
  el('#partnerAns').textContent = partnerText || '(not found)';
  el('#reveal').classList.remove('hidden'); el('#status').textContent = '';
}
async function newQuestion(){
  const t = prompt('Type a new question for this room:'); if (!t) return;
  await fetch(api(`/api/room/${state.roomId}/question`), { method:'POST', headers:{ 'Content-Type':'application/json' }, body: JSON.stringify({ text: t }) });
}
document.addEventListener('DOMContentLoaded', () => {
  el('#createRoom').addEventListener('click', createRoom);
  el('#joinRoom').addEventListener('click', joinRoom);
  el('#submit').addEventListener('click', submitAnswer);
  el('#newQ').addEventListener('click', newQuestion);
});
JS

# ---------- web/vite.config.js ----------
cat > web/vite.config.js <<'JS'
import { defineConfig } from 'vite';
export default defineConfig({ root: 'web', build: { outDir: 'dist', emptyOutDir: true }, server: { port: 5173 } });
JS

# ---------- README ----------
cat > README.md <<'MD'
Relationship-y ❤️ — End-to-end encrypted couples Q&A web app.

Local run (optional):
  npm i
  npm run dev
Frontend: http://localhost:5173
API/WS:  http://localhost:3000
MD

# ---------- .gitignore ----------
cat > .gitignore <<'GIT'
node_modules
web/dist
data
*.log
.DS_Store
.env
GIT

echo "✅ Relationship-y source tree generated."
