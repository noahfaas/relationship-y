#!/usr/bin/env bash
set -euo pipefail

echo "🛠️  Generating Relationship-y (no badges + random cute critters) ..."

mkdir -p server web docker data

# ---------- package.json ----------
cat > package.json <<'JSON'
{
  "name": "relationship-y",
  "version": "1.2.2",
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

CREATE INDEX IF NOT EXISTS answers_qid_idx ON answers(question_id);
CREATE INDEX IF NOT EXISTS answers_qid_user_idx ON answers(question_id, user_id);
CREATE INDEX IF NOT EXISTS questions_room_idx ON questions(room_id, created_at);
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

// ---- question bank ----
const QUESTION_BANK = [
  "What’s one small thing your partner did recently that made you smile?",
  "What’s a tiny ritual you want to start together?",
  "Describe your ideal cozy evening, in 3 ingredients.",
  "What song feels like 'us' this week—and why?",
  "Where would you go on a spontaneous day trip together?",
  "What’s a comfort show or movie you’d rewatch with me?",
  "What’s a childhood snack you’d introduce me to?",
  "How do you feel most cared for on a hard day?",
  "What’s a micro-date we can fit into 20 minutes?",
  "What’s something about me you appreciate but don’t say enough?",
  "Which memory of us do you want to relive for an hour?",
  "What’s a new thing you want to learn together?",
  "What does ‘home’ feel like to you?",
  "What do you want our mornings to look like in a year?",
  "What’s your current love language of the week?",
  "What boundary helped you lately?",
  "What tiny habit would make our place cozier?",
  "Which future trip are you daydreaming about?",
  "What do you want more of this month?",
  "What’s a question you wish I’d ask you more?",
  "What’s a tradition you want us to start this season?",
  "What’s one way I can support you this week?",
  "What’s a little adventure we could do this weekend?",
  "What makes you feel adored?",
  "What’s your favorite slow morning together?",
  "What are we really good at together?",
  "Which small thing would make our evenings nicer?",
  "What would you write in a tiny love note today?"
];

// ---- WS (we also poll) ----
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
    if (roomId && roomSockets.has(roomId)) roomSockets.get(roomId).delete(ws);
  });
});

function broadcastRoom(roomId, payload) {
  const set = roomSockets.get(roomId);
  if (!set) return;
  for (const ws of set) {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(payload));
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
  const text = QUESTION_BANK[Math.floor(Math.random()*QUESTION_BANK.length)];
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
  res.json({ questionId: qid, text });
});

app.post('/api/room/:roomId/random', (req, res) => {
  const roomId = req.params.roomId;
  const used = db.prepare('SELECT text FROM questions WHERE room_id = ?').all(roomId).map(r => r.text);
  const candidates = QUESTION_BANK.filter(t => !used.includes(t));
  const arr = candidates.length ? candidates : QUESTION_BANK;
  const text = arr[Math.floor(Math.random()*arr.length)];
  const qid = nanoid();
  stmtCreateQ.run(qid, roomId, text, Date.now());
  broadcastRoom(roomId, { type: 'newQuestion', questionId: qid });
  res.json({ questionId: qid, text });
});

app.post('/api/answer', (req, res) => {
  const { questionId, userId, ciphertext, iv, salt } = req.body;
  if (!questionId || !userId || !ciphertext || !iv || !salt) return res.status(400).json({ error: 'Missing fields' });
  const id = nanoid();
  stmtInsertAnswer.run(id, questionId, userId, Buffer.from(ciphertext, 'base64'), Buffer.from(iv, 'base64'), Buffer.from(salt, 'base64'), Date.now());

  const distinct = db.prepare('SELECT COUNT(DISTINCT user_id) AS c FROM answers WHERE question_id = ?').get(questionId).c;
  if (distinct >= 2) {
    const qRow = db.prepare('SELECT room_id FROM questions WHERE id = ?').get(questionId);
    broadcastRoom(qRow.room_id, { type: 'readyToReveal', questionId });
  }
  res.json({ ok: true });
});

app.get('/api/answers/:questionId', (req, res) => {
  const questionId = req.params.questionId;
  const all = stmtGetAnswers.all(questionId).sort((a,b) => a.created_at - b.created_at);
  const byUser = new Map();
  for (const r of all) byUser.set(r.user_id, r);
  const rows = [...byUser.values()].map(r => ({
    userId: r.user_id,
    ciphertext: r.ciphertext.toString('base64'),
    iv: r.iv.toString('base64'),
    salt: r.salt.toString('base64')
  }));
  res.json({ answers: rows, distinctUsers: rows.length });
});

app.get('/api/room/:roomId/questions/unanswered', (req, res) => {
  const { roomId } = req.params;
  const { userId } = req.query;
  if (!userId) return res.status(400).json({ error: 'userId required' });

  const rows = db.prepare(`
    SELECT q.id, q.text, q.created_at
    FROM questions q
    WHERE q.room_id = ?
      AND EXISTS (SELECT 1 FROM answers a WHERE a.question_id = q.id AND a.user_id != ?)
      AND NOT EXISTS (SELECT 1 FROM answers b WHERE b.question_id = q.id AND b.user_id = ?)
    ORDER BY q.created_at DESC
  `).all(roomId, userId, userId);

  res.json({ items: rows });
});

app.get('/api/room/:roomId/questions/history', (req, res) => {
  const { roomId } = req.params;
  const rows = db.prepare(`
    SELECT q.id, q.text, q.created_at
    FROM questions q
    WHERE q.room_id = ?
      AND (SELECT COUNT(DISTINCT a.user_id) FROM answers a WHERE a.question_id = q.id) >= 2
    ORDER BY q.created_at DESC
  `).all(roomId);
  res.json({ items: rows });
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
  <title>Relationship-y 💙💛</title>
  <link rel="stylesheet" href="./styles.css" />
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; connect-src 'self' ws: wss: http: https:; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; base-uri 'none'; form-action 'self';">
</head>
<body>
  <div class="sky">
    <div class="stars"></div>
    <div class="hearts"></div>
    <div id="critters" class="critters"></div>
    <header>
      <h1>Relationship-y <span class="heart">💙💛</span></h1>
      <p class="tag">Baby and Baby-y's home for connection.</p>
    </header>

    <main>
      <section class="card">
        <!-- badges removed -->
        <div class="room-controls">
          <button id="createRoom">Create Room</button>
          <div class="or">or</div>
          <input id="roomId" placeholder="Enter ROOM CODE" maxlength="12" autocomplete="off">
          <button id="joinRoom">Join</button>
        </div>

        <div id="roomArea" class="hidden">
          <div class="secret-row">
            <input id="passphrase" placeholder="Shared passphrase (keep private)" autocomplete="off">
            <div class="identity">
              <button id="heartBlue" class="heart-btn heart-blue" aria-pressed="false" title="Be Baby (blue)">💙</button>
              <button id="heartYellow" class="heart-btn heart-yellow" aria-pressed="false" title="Be Baby-y (yellow)">💛</button>
              <span id="identityHint" class="hint">Pick your heart</span>
            </div>
          </div>

          <nav class="tabs">
            <button class="tab active" data-tab="ask">Ask</button>
            <button class="tab" data-tab="inbox">Inbox</button>
            <button class="tab" data-tab="history">History</button>
          </nav>

          <section id="tab-ask">
            <div class="question">
              <div id="qText">—</div>
            </div>

            <textarea id="answer" placeholder="Type your answer…" autocomplete="off"></textarea>
            <div class="actions">
              <button id="submit">Submit</button>
              <button id="randomQ" class="ghost">Random Question</button>
              <button id="newQ" class="ghost">Custom Question</button>
            </div>

            <div id="status" class="status"></div>

            <div id="reveal" class="reveal hidden">
              <h3>Both of you answered! 💌</h3>
              <div class="answers">
                <div>
                  <h4 id="youLabel">Baby 💙</h4>
                  <pre id="yourAns"></pre>
                </div>
                <div>
                  <h4 id="partnerLabel">Baby-y 💛</h4>
                  <pre id="partnerAns"></pre>
                </div>
              </div>
            </div>
          </section>

          <section id="tab-inbox" class="hidden">
            <h3>Your turn ✍️ (partner answered)</h3>
            <ul id="inboxList" class="list"></ul>
          </section>

          <section id="tab-history" class="hidden">
            <h3>Both of you answered ✅</h3>
            <ul id="historyList" class="list"></ul>
          </section>
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
  --ink:#1a1025;
  --rose:#ff6ea1;
  --mauve:#7861ff;
  --mauve-2:#b9a8ff;
  --cloud:#f2e9ff;
  --card:#ffffffd8;
  --shadow: 0 16px 40px rgba(0,0,0,.18);
  --blue:#2b6ef0;
  --blue-ink:#1d3ea1;
}
*{ box-sizing:border-box; }
body,html{ margin:0; height:100%; font-family: ui-rounded, system-ui, -apple-system, Segoe UI, Roboto, sans-serif; color:var(--ink); background:#0d0620; }
.sky{ min-height:100%; position:relative; overflow:hidden;
  background: radial-gradient(1200px 800px at 50% -40%, var(--mauve-2) 0%, #32235c 55%, #0d0620 100%);
}
.stars, .hearts, .critters{ position:absolute; inset:0; pointer-events:none }
.stars{
  background-image:
    radial-gradient(#fff 1px, transparent 1px),
    radial-gradient(#fff6 1px, transparent 1px);
  background-size: 36px 36px, 72px 72px; opacity:.25;
}
.hearts{
  background-image:
    radial-gradient(closest-side, rgba(255,110,161,.22), rgba(255,110,161,0) 80%),
    radial-gradient(closest-side, rgba(185,168,255,.18), rgba(185,168,255,0) 80%);
  background-size: 280px 280px, 360px 360px;
  background-position: 20% 30%, 80% 20%;
  mix-blend-mode: screen;
}
.critters{ overflow:hidden; }
.critter{ position:absolute; opacity:.9; animation: floaty 8s ease-in-out infinite; filter: drop-shadow(0 6px 10px rgba(0,0,0,.25)); }
@keyframes floaty{
  0%,100%{ transform: translateY(0px) }
  50%{ transform: translateY(-10px) }
}
header{ text-align:center; padding:44px 20px; color:#fff; }
h1{ margin:0; font-size:44px; letter-spacing:.6px }
.tag{ margin:8px 0 0; opacity:.9; font-weight:600 }
main{ display:flex; justify-content:center; padding:22px }
.card{ width:min(900px, 94vw); background:var(--card); border-radius:22px; box-shadow: var(--shadow); backdrop-filter: blur(10px); padding:22px; }
.room-controls{ display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-top:6px; }
.or{ color:#fff; background:var(--mauve); padding:4px 8px; border-radius:999px; font-weight:700 }
input, textarea{ width:100%; padding:12px 14px; border:2px solid #0000; background:#fff; border-radius:14px; box-shadow: var(--shadow); outline:none; }
input:focus, textarea:focus{ border-color: var(--mauve); }
textarea{ min-height:120px; resize:vertical; }
.secret-row{ display:grid; grid-template-columns: 1fr auto; gap:10px; margin:12px 0; align-items: center; }
.identity{ display:flex; align-items:center; gap:10px; }
.heart-btn{ font-size:22px; padding:8px 12px; border-radius:999px; border:2px solid transparent; background:#fff; cursor:pointer; box-shadow: var(--shadow); }
.heart-blue[aria-pressed="true"]{ border-color: var(--blue-ink); background:#e7efff; }
.heart-yellow[aria-pressed="true"]{ border-color: #b69000; background:#fff6cf; }
.hint{ font-size:13px; opacity:.7 }
.tabs{ display:flex; gap:10px; margin:8px 0 12px; }
.tab{ padding:8px 12px; border-radius:10px; border:2px solid #0000; background:#fff; box-shadow: var(--shadow); cursor:pointer; color:var(--ink); font-weight:700; }
.tab.active{ border-color: var(--mauve); color: var(--mauve); }
.question{ margin:14px 0; background: linear-gradient(135deg, var(--cloud), #ffe7f1); border-radius:16px; padding:14px; }
#qText{ font-weight:700; font-size:18px }
.actions{ display:flex; gap:10px; align-items:center; margin-top:10px; flex-wrap: wrap; }
button{ padding:12px 16px; border-radius:12px; border:none; background:var(--mauve); color:#fff; font-weight:700; cursor:pointer; box-shadow: var(--shadow); }
button.ghost{ background:#fff; color:var(--mauve); border:2px solid var(--mauve); }
button:disabled{ opacity:.6; cursor:not-allowed }
.status{ margin-top:8px; font-size:14px; opacity:.85 }
.reveal{ margin-top:18px; background:#fff; border-radius:16px; padding:12px; }
.answers{ display:grid; grid-template-columns: 1fr 1fr; gap:12px }
pre{ white-space: pre-wrap; word-wrap: break-word; background:var(--cloud); padding:10px; border-radius:12px; }
.list{ list-style:none; padding:0; margin:10px 0; display:grid; gap:8px; }
.list li{ background:#fff; border-radius:12px; padding:10px; box-shadow: var(--shadow); display:flex; justify-content:space-between; gap:10px; align-items:center; }
.list li small{ opacity:.7 }
footer{ text-align:center; color:#fff; opacity:.85; padding:22px; }
.hidden{ display:none; }
CSS

# ---------- web/main.js ----------
cat > web/main.js <<'JS'
function api(path) {
  const base = location.hostname === 'localhost' ? 'http://localhost:3000' : '';
  return base + path;
}

let state = { roomId: null, ws: null, questionId: null, submitted: false, pollTimer: null };

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

// Heart identity (UI labels only)
const HEART_KEY = 'heart';
function setHeart(color) { localStorage.setItem(HEART_KEY, color); updateHeartUI(); }
function getHeart() { return localStorage.getItem(HEART_KEY) || ''; }
function updateHeartUI() {
  const h = getHeart();
  document.getElementById('heartBlue')?.setAttribute('aria-pressed', String(h === 'blue'));
  document.getElementById('heartYellow')?.setAttribute('aria-pressed', String(h === 'yellow'));
  const you = document.getElementById('youLabel');
  const partner = document.getElementById('partnerLabel');
  if (you && partner) {
    if (h === 'yellow') { you.textContent = 'Baby-y 💛'; partner.textContent = 'Baby 💙'; }
    else { you.textContent = 'Baby 💙'; partner.textContent = 'Baby-y 💛'; }
  }
  const hint = document.getElementById('identityHint');
  if (hint) hint.textContent = h ? 'Identity set' : 'Pick your heart';
}

// ---- Random cute critters (original SVGs, not IP) ----
function pick(a){ return a[Math.floor(Math.random()*a.length)]; }
function rand(min,max){ return Math.random()*(max-min)+min; }
function renderCritters(){
  const host = document.getElementById('critters');
  if (!host) return;

  // Blue alien (3 poses)
  const aliens = [
`<svg width="120" height="110" viewBox="0 0 120 110" class="critter" xmlns="http://www.w3.org/2000/svg">
  <ellipse cx="60" cy="55" rx="34" ry="30" fill="#64a8ff"/>
  <ellipse cx="30" cy="50" rx="18" ry="12" fill="#64a8ff"/>
  <ellipse cx="90" cy="50" rx="18" ry="12" fill="#64a8ff"/>
  <circle cx="48" cy="55" r="8" fill="#0d1b3a"/><circle cx="72" cy="55" r="8" fill="#0d1b3a"/>
  <circle cx="49" cy="53" r="2" fill="#bfe1ff"/><circle cx="73" cy="53" r="2" fill="#bfe1ff"/>
  <path d="M46 75 Q60 85 74 75" stroke="#0d1b3a" stroke-width="4" fill="none" stroke-linecap="round"/>
</svg>`,
`<svg width="120" height="110" viewBox="0 0 120 110" class="critter" xmlns="http://www.w3.org/2000/svg">
  <ellipse cx="60" cy="55" rx="34" ry="30" fill="#5aa1ff"/>
  <ellipse cx="25" cy="45" rx="12" ry="16" fill="#5aa1ff"/>
  <ellipse cx="95" cy="45" rx="12" ry="16" fill="#5aa1ff"/>
  <circle cx="50" cy="58" r="7" fill="#0d1b3a"/><circle cx="70" cy="58" r="7" fill="#0d1b3a"/>
  <path d="M48 70 Q60 63 72 70" stroke="#0d1b3a" stroke-width="4" fill="none" stroke-linecap="round"/>
</svg>`,
`<svg width="120" height="110" viewBox="0 0 120 110" class="critter" xmlns="http://www.w3.org/2000/svg">
  <ellipse cx="60" cy="55" rx="32" ry="28" fill="#6cb2ff"/>
  <ellipse cx="32" cy="60" rx="10" ry="14" fill="#6cb2ff"/>
  <ellipse cx="88" cy="60" rx="10" ry="14" fill="#6cb2ff"/>
  <circle cx="52" cy="55" r="6" fill="#0d1b3a"/><circle cx="68" cy="55" r="6" fill="#0d1b3a"/>
  <path d="M50 72 Q60 80 70 72" stroke="#0d1b3a" stroke-width="3.5" fill="none" stroke-linecap="round"/>
</svg>`
  ];

  // Black & white dog (3 poses)
  const dogs = [
`<svg width="130" height="110" viewBox="0 0 130 110" class="critter" xmlns="http://www.w3.org/2000/svg">
  <ellipse cx="70" cy="60" rx="38" ry="28" fill="#fff"/>
  <ellipse cx="90" cy="40" rx="12" ry="18" fill="#111"/>
  <ellipse cx="50" cy="40" rx="12" ry="18" fill="#111"/>
  <circle cx="60" cy="60" r="6" fill="#111"/><circle cx="80" cy="60" r="6" fill="#111"/>
  <circle cx="70" cy="70" r="5" fill="#111"/>
</svg>`,
`<svg width="130" height="110" viewBox="0 0 130 110" class="critter" xmlns="http://www.w3.org/2000/svg">
  <ellipse cx="65" cy="62" rx="36" ry="26" fill="#fff"/>
  <ellipse cx="85" cy="45" rx="10" ry="14" fill="#111"/>
  <ellipse cx="45" cy="45" rx="10" ry="14" fill="#111"/>
  <circle cx="58" cy="60" r="6" fill="#111"/><circle cx="74" cy="60" r="6" fill="#111"/>
  <rect x="63" y="68" width="4" height="8" rx="2" fill="#ff6ea1"/>
</svg>`,
`<svg width="130" height="110" viewBox="0 0 130 110" class="critter" xmlns="http://www.w3.org/2000/svg">
  <ellipse cx="68" cy="60" rx="34" ry="24" fill="#fff"/>
  <ellipse cx="88" cy="48" rx="11" ry="15" fill="#111"/>
  <ellipse cx="48" cy="48" rx="11" ry="15" fill="#111"/>
  <circle cx="60" cy="58" r="5.5" fill="#111"/><circle cx="76" cy="58" r="5.5" fill="#111"/>
  <path d="M60 72 Q68 76 76 72" stroke="#111" stroke-width="3" fill="none" stroke-linecap="round"/>
</svg>`
  ];

  const alien = document.createElement('div');
  alien.innerHTML = pick(aliens);
  const dog = document.createElement('div');
  dog.innerHTML = pick(dogs);

  const a = alien.firstChild;
  const d = dog.firstChild;

  // Random positions
  Object.assign(a.style, {
    left: `${rand(5,25)}%`,
    top: `${rand(8,28)}%`,
    transform: `scale(${rand(0.9,1.15)}) rotate(${rand(-6,6)}deg)`
  });
  Object.assign(d.style, {
    right: `${rand(5,18)}%`,
    bottom: `${rand(8,20)}%`,
    transform: `scale(${rand(0.9,1.1)}) rotate(${rand(-4,4)}deg)`
  });

  host.appendChild(a);
  host.appendChild(d);
}

// ---- crypto helpers ----
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

// ---- UI helpers ----
const el = s => document.querySelector(s);
function showTab(name){
  for (const t of document.querySelectorAll('.tab')) t.classList.toggle('active', t.dataset.tab === name);
  document.getElementById('tab-ask').classList.toggle('hidden', name !== 'ask');
  document.getElementById('tab-inbox').classList.toggle('hidden', name !== 'inbox');
  document.getElementById('tab-history').classList.toggle('hidden', name !== 'history');
  if (name === 'inbox') loadInbox();
  if (name === 'history') loadHistory();
}

function resetRevealUI(){
  state.submitted = false;
  const ta = el('#answer'); if (ta) { ta.value = ''; ta.disabled = false; }
  el('#submit').disabled = false;
  el('#passphrase').disabled = false;
  el('#reveal').classList.add('hidden');
  el('#status').textContent = '';
  if (state.pollTimer) { clearInterval(state.pollTimer); state.pollTimer = null; }
}

function applyNewQuestion(payload){
  if (!payload) return;
  state.questionId = payload.questionId;
  el('#qText').textContent = payload.text;
  resetRevealUI();
  startPolling();
}

// ---- room flow ----
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
      fetchQuestionText().then(() => resetRevealUI());
    }
    if (msg.type === 'readyToReveal' && msg.questionId === state.questionId) revealAnswers();
  });
}

async function fetchQuestionText(){
  const q = await fetch(api(`/api/room/${state.roomId}/question`)).then(r=>r.json());
  state.questionId = q.questionId; el('#qText').textContent = q.text;
  await checkMySubmission();
}
async function loadQuestion(){ await fetchQuestionText(); startPolling(); }

// Polling fallback
function startPolling(){
  if (state.pollTimer) clearInterval(state.pollTimer);
  state.pollTimer = setInterval(async () => {
    if (!state.questionId) return;
    const res = await fetch(api(`/api/answers/${state.questionId}`)).then(r=>r.json()).catch(()=>null);
    if (!res) return;
    if (res.distinctUsers >= 2) { clearInterval(state.pollTimer); state.pollTimer = null; revealAnswers(); }
  }, 1500);
}

// Detect if I have already answered this question
async function checkMySubmission(){
  const myId = getMeId();
  const passphrase = el('#passphrase').value.trim();
  const ans = await fetch(api(`/api/answers/${state.questionId}`)).then(r=>r.json());
  const mine = (ans.answers || []).find(a => a.userId === myId);
  const distinct = ans.distinctUsers || (ans.answers || []).length;

  if (mine) {
    el('#submit').disabled = true;
    el('#passphrase').disabled = true;
    const ta = el('#answer'); if (ta) { ta.disabled = true; ta.value=''; }
    el('#status').textContent = 'Answer locked. Waiting for your partner…';
  } else {
    el('#submit').disabled = false;
    const ta = el('#answer'); if (ta) ta.disabled = false;
    el('#status').textContent = '';
  }
  if (distinct >= 2 && passphrase) await revealAnswers();
}

// ---- ask actions ----
async function submitAnswer(){
  const passphrase = el('#passphrase').value.trim();
  if(!passphrase) return alert('Add a shared passphrase first');
  if(!getHeart()) return alert('Pick your heart (💙 or 💛) before submitting');
  const text = el('#answer').value.trim(); if(!text) return alert('Write an answer');

  el('#submit').disabled = true;
  el('#passphrase').disabled = true;
  const ta = el('#answer'); if (ta) { ta.disabled = true; ta.value = ''; }

  const { ciphertext, iv, salt } = await encryptText(text, passphrase);
  await fetch(api('/api/answer'), {
    method:'POST', headers: { 'Content-Type':'application/json' },
    body: JSON.stringify({ questionId: state.questionId, userId: getMeId(), ciphertext, iv, salt })
  });
  state.submitted = true; el('#status').textContent = 'Answer locked. Waiting for your partner…';
  startPolling();
}

async function revealAnswers(){
  const passphrase = el('#passphrase').value.trim();
  const myId = getMeId();
  const { answers } = await fetch(api(`/api/answers/${state.questionId}`)).then(r=>r.json());
  if((answers?.length || 0) < 2) return;

  let myText = '', partnerText = '';
  let failedDecrypts = 0;
  for (const a of answers) {
    try { 
      const plain = await decryptText(a.ciphertext, a.iv, a.salt, passphrase);
      if (a.userId === myId) myText = plain; else partnerText = plain;
    } catch(e){ failedDecrypts++; }
  }
  if (failedDecrypts > 0) el('#status').textContent = 'Passphrases don’t match. Make sure you both used the exact same passphrase.';
  else el('#status').textContent = '';
  el('#yourAns').textContent = myText || '(not found)';
  el('#partnerAns').textContent = partnerText || '(not found)';
  el('#reveal').classList.remove('hidden'); 
}

async function newQuestion(){
  const t = prompt('Type a new question for this room:'); if (!t) return;
  const r = await fetch(api(`/api/room/${state.roomId}/question`), {
    method:'POST', headers:{ 'Content-Type':'application/json' }, body: JSON.stringify({ text: t })
  }).then(r=>r.json());
  applyNewQuestion(r);
}
async function randomQuestion(){
  const r = await fetch(api(`/api/room/${state.roomId}/random`), { method:'POST' }).then(r=>r.json());
  applyNewQuestion(r);
}

// ---- inbox & history ----
function fmtDate(ts){ const d=new Date(ts); return d.toLocaleString(); }

async function loadInbox(){
  const res = await fetch(api(`/api/room/${state.roomId}/questions/unanswered?userId=${encodeURIComponent(getMeId())}`)).then(r=>r.json());
  const ul = document.getElementById('inboxList'); ul.innerHTML = '';
  if (!res.items.length) { ul.innerHTML = '<li><em>No pending questions — nice!</em></li>'; return; }
  for (const it of res.items) {
    const li = document.createElement('li');
    li.innerHTML = `<span>${it.text}</span><small>${fmtDate(it.created_at)}</small>`;
    const btn = document.createElement('button');
    btn.textContent = 'Answer';
    btn.className = 'ghost';
    btn.onclick = async () => applyNewQuestion({ questionId: it.id, text: it.text });
    li.appendChild(btn);
    ul.appendChild(li);
  }
}

async function loadHistory(){
  const res = await fetch(api(`/api/room/${state.roomId}/questions/history`)).then(r=>r.json());
  const ul = document.getElementById('historyList'); ul.innerHTML = '';
  if (!res.items.length) { ul.innerHTML = '<li><em>No shared answers yet.</em></li>'; return; }
  for (const it of res.items) {
    const li = document.createElement('li');
    li.innerHTML = `<span>${it.text}</span><small>${fmtDate(it.created_at)}</small>`;
    const btn = document.createElement('button');
    btn.textContent = 'View';
    btn.className = 'ghost';
    btn.onclick = async () => { applyNewQuestion({ questionId: it.id, text: it.text }); await revealAnswers(); };
    li.appendChild(btn);
    ul.appendChild(li);
  }
}

// ---- boot ----
document.addEventListener('DOMContentLoaded', () => {
  renderCritters();

  document.querySelector('#answer').value = '';
  document.getElementById('createRoom').addEventListener('click', createRoom);
  document.getElementById('joinRoom').addEventListener('click', joinRoom);
  document.getElementById('submit').addEventListener('click', submitAnswer);
  document.getElementById('newQ').addEventListener('click', newQuestion);
  document.getElementById('randomQ').addEventListener('click', randomQuestion);

  document.getElementById('heartBlue')?.addEventListener('click', () => setHeart('blue'));
  document.getElementById('heartYellow')?.addEventListener('click', () => setHeart('yellow'));
  updateHeartUI();

  for (const t of document.querySelectorAll('.tab')) t.addEventListener('click', () => showTab(t.dataset.tab));
});
JS

# ---------- web/vite.config.js ----------
cat > web/vite.config.js <<'JS'
import { defineConfig } from 'vite';
export default defineConfig({ root: 'web', build: { outDir: 'dist', emptyOutDir: true }, server: { port: 5173 } });
JS

# ---------- README ----------
cat > README.md <<'MD'
Relationship-y 💙💛 — End-to-end encrypted couples Q&A web app.

This build:
- Removes the old “space pup / cloud paws” badges.
- Adds original, **non-IP** SVG critters (blue alien + black/white dog) that
  appear in random poses and positions on each load.
- Keeps all features: hearts identity, random/custom Q, inbox, history, WS+polling, persistence.

Local run:
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

echo "✅ Relationship-y (no badges + random critters) generated."
