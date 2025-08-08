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
    "nanoid": "^5.0.7",
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
... [same as before] ...
JS

# ---------- server/index.js ----------
cat > server/index.js <<'JS'
... [same as before] ...
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
    ...
HTML

# ---------- web/styles.css ----------
cat > web/styles.css <<'CSS'
... [same as before] ...
CSS

# ---------- web/main.js ----------
cat > web/main.js <<'JS'
... [same as before] ...
JS

# ---------- web/vite.config.js ----------
cat > web/vite.config.js <<'JS'
import { defineConfig } from 'vite';

export default defineConfig({
  root: 'web',
  build: { outDir: 'dist', emptyOutDir: true },
  server: { port: 5173 }
});
JS

# ---------- README ----------
cat > README.md <<'MD'
Relationship-y ❤️

End-to-end encrypted couples Q&A web app.

Run locally (optional):
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
