#!/usr/bin/env node
const http = require('http');
const fs = require('fs');
const { exec } = require('child_process');

const API_PORT = 3021;
const LOG_FILE = '/var/log/marcscript-api.log';
const CONFIG_FILE = '/etc/marcscript-vpn-config.json';

function log(msg) {
    const ts = new Date().toISOString();
    const line = `[${ts}] ${msg}\n`;
    console.log(line.trim());
    fs.appendFileSync(LOG_FILE, line, { flag: 'a' });
}

function readJson(file) {
    try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function getBackupDir() {
    const dirs = fs.readdirSync('/root').filter(d => d.startsWith('ssh-vpn-backup-'));
    if (dirs.length === 0) return null;
    dirs.sort().reverse();
    return '/root/' + dirs[0];
}

const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST');
    const url = req.url;
    log(`${req.method} ${url}`);

    if (url === '/status' && req.method === 'GET') {
        const data = readJson(CONFIG_FILE);
        if (data) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(data, null, 2));
        } else {
            res.writeHead(500);
            res.end('Cannot read config');
        }
        return;
    }
    if (url === '/reset' && req.method === 'POST') {
        const backupDir = getBackupDir();
        if (!backupDir) {
            res.writeHead(500);
            res.end('No backup found');
            return;
        }
        exec(`bash ${backupDir}/rollback.sh`, (error, stdout, stderr) => {
            if (error) res.end(`Rollback failed: ${error.message}`);
            else res.end('Rollback completed');
        });
        return;
    }
    if (url === '/ping') {
        res.writeHead(200);
        res.end('pong');
        return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(`<h1>MarcScript API</h1>
        <ul><li>GET /status</li><li>POST /reset</li><li>GET /ping</li></ul>`);
});

server.listen(API_PORT, '127.0.0.1', () => log(`API on port ${API_PORT}`));

process.on('SIGTERM', () => { server.close(() => process.exit(0)); });
process.on('SIGINT',  () => { server.close(() => process.exit(0)); });
