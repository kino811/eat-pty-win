#!/usr/bin/env node
'use strict';

const os = require('os');
const fs = require('fs');
const path = require('path');
const pty = require('node-pty');

const resizePrefix = '\x1b]777;resize;';
const flowPrefix = '\x1b]777;flow;';
const outputFlushIntervalMs = 5;
const outputChunkSize = Math.max(
  4096,
  Number(process.env.EAT_PTY_WIN_OUTPUT_CHUNK_SIZE) || 65536
);
const outputHighWatermark = 64 * 1024;
const outputLowWatermark = 16 * 1024;
const outputMaxBuffer = 256 * 1024;
const stripUnsafeSequences = process.env.EAT_PTY_WIN_STRIP_UNSAFE !== '0';
const sanitizeUiGlyphsMode = process.env.EAT_PTY_WIN_SANITIZE_UI_GLYPHS || 'auto';
const outputAckTimeoutMs = Math.max(
  100,
  Number(process.env.EAT_PTY_WIN_ACK_TIMEOUT_MS) || 3000
);
const diagnosticFile = process.env.EAT_PTY_WIN_DIAGNOSTIC_FILE || '';
let sanitizeUiGlyphsUntil = 0;

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
    if (pending.value.startsWith(flowPrefix)) {
      const end = pending.value.indexOf('\x07');
      if (end < 0) {
        if (!final) return;
        term.write(pending.value);
        pending.value = '';
        return;
      }

      const command = pending.value.slice(flowPrefix.length, end);
      if (command === 'pause') {
        pausePty();
      } else if (command === 'resume') {
        forceResumePty();
      } else if (command === 'ack') {
        acknowledgeOutput();
      } else {
        term.write(pending.value.slice(0, end + 1));
      }
      pending.value = pending.value.slice(end + 1);
      continue;
    }

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

    if ((resizePrefix.startsWith(pending.value)
         || flowPrefix.startsWith(pending.value))
        && !final) {
      return;
    }

    const nextEscape = pending.value.indexOf('\x1b', 1);
    const count = nextEscape < 0 ? pending.value.length : nextEscape;
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

function stripUnsafeOutputSequences(data) {
  if (!stripUnsafeSequences) {
    return data;
  }

  return data
    // DCS/Sixel and other device-control payloads can be very expensive in Eat.
    .replace(/\x1bP[\s\S]*?(?:\x1b\\|\x9c)/g, '')
    // OSC payloads include hyperlinks/title sequences; keep them out of Eat.
    .replace(/\x1b\][\s\S]*?(?:\x07|\x1b\\|\x9c)/g, '')
    // APC and PM string controls.
    .replace(/\x1b_[\s\S]*?(?:\x1b\\|\x9c)/g, '')
    .replace(/\x1b\^[\s\S]*?(?:\x1b\\|\x9c)/g, '');
}

function looksLikeAiCliOutput(data) {
  return /\b(?:Copilot|Codex|OpenAI|ChatGPT|Claude|Gemini)\b|\/agentBrowse|\/model\b|\/approval\b|AI\s+CLI/i.test(data);
}

function shouldSanitizeUiGlyphs(data) {
  if (sanitizeUiGlyphsMode === '1') {
    return true;
  }
  if (sanitizeUiGlyphsMode === '0') {
    return false;
  }

  if (looksLikeAiCliOutput(data)) {
    sanitizeUiGlyphsUntil = Date.now() + 10 * 60 * 1000;
    return true;
  }

  return Date.now() < sanitizeUiGlyphsUntil;
}

function sanitizeRiskyUiGlyphs(data) {
  if (!shouldSanitizeUiGlyphs(data)) {
    return data;
  }

  return data
    .replace(/…/g, '...')
    .replace(/[·•●○◉◎◆■□▪▫▴▾◂▸❯]/g, '*')
    .replace(/[↑↓←→↕↔]/g, '*')
    .replace(/[─━═]/g, '-')
    .replace(/[│┃║]/g, '|')
    .replace(/[┌┐└┘╭╮╰╯├┤┬┴┼╞╡╤╧╪╔╗╚╝╠╣╦╩╬]/g, '+')
    .replace(/[\u2500-\u257F]/g, '+')
    .replace(/[\u2580-\u259F]/g, ' ');
}

let outputBuffer = '';
let outputTimer = null;
let stdoutBlocked = false;
let ptyPaused = false;
let waitingForAck = false;
let outputAckTimer = null;
let lastOutputChunk = '';

function clearOutputAckTimer() {
  if (outputAckTimer !== null) {
    clearTimeout(outputAckTimer);
    outputAckTimer = null;
  }
}

function recordUnacknowledgedChunk() {
  outputAckTimer = null;
  if (!waitingForAck) {
    return;
  }

  if (diagnosticFile !== '') {
    fs.mkdirSync(path.dirname(diagnosticFile), { recursive: true });
    fs.writeFileSync(
      diagnosticFile,
      `timestamp=${new Date().toISOString()}\n${lastOutputChunk}`,
      'utf8'
    );
  }

  // The timed-out chunk was already sent to Emacs.  Do not replay terminal
  // controls; release flow control so a missing ACK cannot deadlock the PTY.
  waitingForAck = false;
  resumePtyIfSafe();
  scheduleOutputFlush();
}

function scheduleOutputAckTimeout(chunk) {
  clearOutputAckTimer();
  lastOutputChunk = chunk;
  outputAckTimer = setTimeout(recordUnacknowledgedChunk, outputAckTimeoutMs);
}

function pausePty() {
  if (!ptyPaused) {
    term.pause();
    ptyPaused = true;
  }
}

function resumePtyIfSafe() {
  if (ptyPaused && !stdoutBlocked && !waitingForAck && outputBuffer.length <= outputLowWatermark) {
    term.resume();
    ptyPaused = false;
  }
}

function forceResumePty() {
  clearOutputAckTimer();
  waitingForAck = false;
  if (ptyPaused && !stdoutBlocked) {
    term.resume();
    ptyPaused = false;
  }
  scheduleOutputFlush();
}

function acknowledgeOutput() {
  clearOutputAckTimer();
  waitingForAck = false;
  resumePtyIfSafe();
  scheduleOutputFlush();
}

function scheduleOutputFlush() {
  if (outputTimer === null && !stdoutBlocked && !waitingForAck) {
    outputTimer = setTimeout(flushOutput, outputFlushIntervalMs);
  }
}

function flushOutput() {
  outputTimer = null;

  if (stdoutBlocked || waitingForAck) {
    return;
  }

  if (outputBuffer.length === 0) {
    resumePtyIfSafe();
    return;
  }

  const chunk = outputBuffer.slice(0, outputChunkSize);
  outputBuffer = outputBuffer.slice(outputChunkSize);

  if (!process.stdout.write(chunk)) {
    stdoutBlocked = true;
    pausePty();
    return;
  }

  waitingForAck = true;
  scheduleOutputAckTimeout(chunk);
  pausePty();
  resumePtyIfSafe();

  if (outputBuffer.length > 0) {
    scheduleOutputFlush();
  }
}

term.onData((data) => {
  outputBuffer += sanitizeRiskyUiGlyphs(stripUnsafeOutputSequences(data));

  if (outputBuffer.length > outputMaxBuffer) {
    outputBuffer = outputBuffer.slice(outputBuffer.length - outputMaxBuffer);
  }

  if (outputBuffer.length >= outputHighWatermark) {
    pausePty();
  }

  scheduleOutputFlush();
});

process.stdout.on('drain', () => {
  stdoutBlocked = false;
  resumePtyIfSafe();
  scheduleOutputFlush();
});

term.onExit(({ exitCode }) => {
  clearOutputAckTimer();
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
