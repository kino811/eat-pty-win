#!/usr/bin/env node
'use strict';

const os = require('os');
const pty = require('node-pty');

const resizePrefix = '\x1b]777;resize;';

function parseArgs(argv) {
  let cols = 120;
  let rows = 30;
  let commandStart = -1;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      console.log('Usage: conpty-node-bridge.js [--cols N] [--rows N] [-- command args...]');
      process.exit(0);
    } else if (arg === '--cols' && i + 1 < argv.length) {
      cols = Math.max(1, parseInt(argv[++i], 10) || cols);
    } else if (arg === '--rows' && i + 1 < argv.length) {
      rows = Math.max(1, parseInt(argv[++i], 10) || rows);
    } else if (arg === '--') {
      commandStart = i + 1;
      break;
    } else {
      commandStart = i;
      break;
    }
  }

  const command = commandStart >= 0 ? argv.slice(commandStart) : [];
  if (command.length === 0) {
    command.push(process.env.ComSpec || 'cmd.exe');
  }

  return { cols, rows, file: command[0], args: command.slice(1) };
}

function flushInput(term, pending, final) {
  while (pending.value.length > 0) {
    if (pending.value.startsWith(resizePrefix)) {
      const end = pending.value.indexOf('\x07');
      if (end < 0) {
        if (!final) return;
        term.write(pending.value);
        pending.value = '';
        return;
      }

      const payload = pending.value.slice(resizePrefix.length, end);
      const match = /^(\d+);(\d+)$/.exec(payload);
      if (match) {
        term.resize(Math.max(1, Number(match[1])), Math.max(1, Number(match[2])));
      } else {
        term.write(pending.value.slice(0, end + 1));
      }
      pending.value = pending.value.slice(end + 1);
      continue;
    }

    if (resizePrefix.startsWith(pending.value) && !final) {
      return;
    }

    const nextEscape = pending.value.indexOf('\x1b');
    const count = nextEscape < 0 ? pending.value.length : Math.max(1, nextEscape);
    term.write(pending.value.slice(0, count));
    pending.value = pending.value.slice(count);
  }
}

const options = parseArgs(process.argv.slice(2));
const term = pty.spawn(options.file, options.args, {
  name: 'xterm-256color',
  cols: options.cols,
  rows: options.rows,
  cwd: process.cwd(),
  env: { ...process.env, TERM: 'xterm-256color' },
  useConpty: os.platform() === 'win32',
});

term.onData((data) => {
  process.stdout.write(data);
});

term.onExit(({ exitCode }) => {
  process.exitCode = exitCode ?? 0;
  process.exit();
});

const pending = { value: '' };
process.stdin.setEncoding('utf8');
process.stdin.on('data', (data) => {
  pending.value += data;
  flushInput(term, pending, false);
});
process.stdin.on('end', () => {
  flushInput(term, pending, true);
});
