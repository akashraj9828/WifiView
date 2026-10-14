// Zero-dependency server: spawns the Swift scanner, fans its JSON lines out over SSE.
// Usage: node server.js [--sim]   (--sim = fake data, no Wi-Fi needed)
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, execFileSync } = require('child_process');

const PORT = process.env.PORT || 3000;
const SIM = process.argv.includes('--sim');
const clients = new Set();

function broadcast(line) {
  for (const res of clients) res.write(`data: ${line}\n\n`);
}

function startScanner() {
  // The scanner runs as a real .app launched via LaunchServices (`open`) so macOS can show its
  // Location prompt. A .app can't pipe stdout to us, so it writes to a FIFO that we read.
  const app = path.join(__dirname, 'WifiviewScan.app');
  const fifo = path.join(os.tmpdir(), `wifiview-${process.pid}.fifo`);
  const errLog = path.join(os.tmpdir(), 'wifiview-scan.err');
  try { fs.unlinkSync(fifo); } catch {}
  execFileSync('mkfifo', [fifo]);
  const cleanup = () => { try { fs.unlinkSync(fifo); } catch {} };
  process.on('exit', cleanup);
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => process.exit(0));

  // RSSI_MS: connected-AP poll interval (default 250). SCAN_GAP_MS: pause between full scans (default 1000).
  const args = ['-n', '-g', '-W', '-a', app, '--stdout', fifo, '--stderr', errLog];
  for (const k of ['RSSI_MS', 'SCAN_GAP_MS']) if (process.env[k]) args.push('--env', `${k}=${process.env[k]}`);
  const p = spawn('open', args, { stdio: 'ignore' });
  p.on('exit', (c) => { console.error(`scanner app exited (${c}); see ${errLog}`); process.exit(1); });

  // When this server dies the FIFO reader closes, the app gets SIGPIPE on its next write and quits.
  let buf = '';
  const rs = fs.createReadStream(fifo, { encoding: 'utf8' });
  rs.on('data', (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (line) broadcast(line);
    }
  });
  rs.on('end', () => { console.error(`scanner stopped; see ${errLog}`); process.exit(1); });
}

function startSim() {
  const chans = [1, 6, 11, 36, 40, 44, 149, 153];
  let k = 0;
  setInterval(() => {
    k++;
    broadcast(JSON.stringify({
      type: 'rssi', t: Date.now() / 1000,
      rssi: Math.round(-55 + 8 * Math.sin(k / 12) + (Math.random() - 0.5) * 4),
      noise: -92, channel: 36, txRate: 433, ssid: 'sim', bssid: 'aa:bb:cc:dd:ee:ff',
      band: 2, width: 3, phy: 6, security: 11, country: 'US', iface: 'en0', auth: 4,
    }));
  }, 250);
  setInterval(() => {
    const nets = chans.map((c, i) => ({
      ssid: `net${i}`, channel: c, band: c > 14 ? 2 : 1, width: c > 14 ? 3 : 1,
      rssi: Math.round(-45 - i * 5 + 6 * Math.sin(Date.now() / 3000 + i) + Math.random() * 3),
    }));
    broadcast(JSON.stringify({ type: 'scan', t: Date.now() / 1000, nets }));
  }, 1500);
}

http.createServer((req, res) => {
  if (req.url === '/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
    });
    res.write('\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  fs.readFile(path.join(__dirname, 'index.html'), (err, data) => {
    if (err) { res.writeHead(500); return res.end('index.html missing'); }
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(data);
  });
}).listen(PORT, '127.0.0.1', () => console.log(`http://127.0.0.1:${PORT}${SIM ? ' (sim)' : ''}`));

SIM ? startSim() : startScanner();
