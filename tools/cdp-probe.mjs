// Phase 1 probe: launch an ISOLATED Claude instance (throwaway --user-data-dir) with a debugging
// switch, record what happens, then kill only the process group we started.
// usage: node probe.mjs pipe|port <userDataDir> [seconds]
import { spawn } from 'node:child_process';
import http from 'node:http';

const [mode, userDataDir, secsArg] = process.argv.slice(2);
const secs = Number(secsArg || 20);
const BIN = '/Applications/Claude.app/Contents/MacOS/Claude';
const port = 40000 + Math.floor(Math.random() * 20000);
const args = [`--user-data-dir=${userDataDir}`];
if (mode === 'pipe') args.push('--remote-debugging-pipe');
else args.push(`--remote-debugging-port=${port}`, '--remote-address=127.0.0.1');

const t0 = Date.now();
const log = (...a) => console.log(`[+${((Date.now() - t0) / 1000).toFixed(1)}s]`, ...a);
log('spawn', BIN, args.join(' '));
const child = spawn(BIN, args, { detached: true, stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe'] });
child.stdout.on('data', d => process.stdout.write(`  [stdout] ${d}`));
child.stderr.on('data', d => process.stdout.write(`  [stderr] ${d}`));
let exited = null;
child.on('exit', (code, sig) => { exited = { code, sig }; log('child exited', code, sig); });

const getJson = (path) => new Promise((res) => {
	http.get({ host: '127.0.0.1', port, path, timeout: 1500 }, r => {
		let b = ''; r.on('data', c => b += c); r.on('end', () => res({ status: r.statusCode, body: b }));
	}).on('error', e => res({ error: e.code || e.message })).on('timeout', function () { this.destroy(); });
});

// Pipe transport: we write to child's fd3, read NUL-delimited JSON from child's fd4.
let pipeReplies = [];
if (mode === 'pipe') {
	let buf = '';
	child.stdio[4].on('data', d => {
		buf += d.toString();
		let i; while ((i = buf.indexOf('\0')) >= 0) { pipeReplies.push(buf.slice(0, i)); buf = buf.slice(i + 1); }
	});
	child.stdio[4].on('error', e => log('fd4 error', e.code));
	child.stdio[3].on('error', e => log('fd3 error', e.code));
}

const sleep = ms => new Promise(r => setTimeout(r, ms));
let result = { mode, port: mode === 'port' ? port : null };
for (let s = 0; s < secs && !exited; s += 2) {
	await sleep(2000);
	if (mode === 'port') {
		const r = await getJson('/json/version');
		log('GET /json/version ->', r.error ? r.error : `${r.status} ${r.body.slice(0, 300)}`);
		if (!r.error) { result.version = r.body; result.list = (await getJson('/json/list')).body; break; }
	} else {
		try { child.stdio[3].write(JSON.stringify({ id: s + 1, method: 'Target.getTargets' }) + '\0'); } catch (e) { log('write failed', e.message); }
		await sleep(500);
		if (pipeReplies.length) { log('pipe reply:', pipeReplies.at(-1).slice(0, 600)); result.pipe = pipeReplies; break; }
		log('no pipe reply yet');
	}
}
log('RESULT', JSON.stringify({ ...result, exited }).slice(0, 4000));
if (!exited) { try { process.kill(-child.pid, 'SIGTERM'); } catch { } await sleep(1500); try { process.kill(-child.pid, 'SIGKILL'); } catch { } log('killed our process group', child.pid); }
process.exit(0);
