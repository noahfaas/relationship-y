function api(path) {
  const base = location.hostname === 'localhost' ? 'http://localhost:3000' : '';
  return base + path;
}

let state = { roomId: null, ws: null, questionId: null, submitted: false };

// Stable hidden ID
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

  const { ciphertext, iv, salt } = await encryptText(text, passphrase);
  await fetch(api('/api/answer'), {
    method:'POST', headers: { 'Content-Type':'application/json' },
    body: JSON.stringify({ questionId: state.questionId, userId: getMeId(), ciphertext, iv, salt })
  });

  state.submitted = true; 
  el('#status').textContent = 'Answer locked. Waiting for your partner…';
}

async function revealAnswers(){
  const passphrase = el('#passphrase').value.trim();
  const myId = getMeId();
  const { answers } = await fetch(api(`/api/answers/${state.questionId}`)).then(r=>r.json());
  if(answers.length < 2) return;
  let myText = '', partnerText = '';
  for (const a of answers) {
    try { 
      const plain = await decryptText(a.ciphertext, a.iv, a.salt, passphrase);
      if (a.userId === myId) myText = plain; else partnerText = plain;
    } catch(e){}
  }
  if(!myText && !partnerText){ 
    el('#status').textContent = 'Could not decrypt. Did you both type the same passphrase?'; 
    return; 
  }
  el('#yourAns').textContent = myText || '(not found)';
  el('#partnerAns').textContent = partnerText || '(not found)';
  el('#reveal').classList.remove('hidden'); el('#status').textContent = '';
}

async function newQuestion(){
  const t = prompt('Type a new question for this room:'); 
  if (!t) return;
  await fetch(api(`/api/room/${state.roomId}/question`), { 
    method:'POST', headers:{ 'Content-Type':'application/json' }, 
    body: JSON.stringify({ text: t }) 
  });
}

document.addEventListener('DOMContentLoaded', () => {
  el('#createRoom').addEventListener('click', createRoom);
  el('#joinRoom').addEventListener('click', joinRoom);
  el('#submit').addEventListener('click', submitAnswer);
  el('#newQ').addEventListener('click', newQuestion);
});
