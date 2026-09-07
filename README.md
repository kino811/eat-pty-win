# eat-pty-win

Windows PTY terminal integration for Emacs.  Eat handles terminal rendering,
and node-pty owns the Windows ConPTY backend.

## Requirements

- Windows 10/11 with ConPTY support
- Node.js
- Emacs package: `eat`
- npm dependencies installed under `node-bridge`

## Files to back up

```text
eat-pty-win/
  eat-pty-win.el
  README.md
  .gitignore
  node-bridge/
    conpty-node-bridge.js
    package.json
    package-lock.json
```

Do not back up `node-bridge/node_modules/`.  Restore it with `npm install`.

## Install

1. Copy this directory to:

   ```text
   ~/.emacs.d/eat-pty-win
   ```

2. Install the Node.js dependency:

   ```powershell
   cd ~/.emacs.d/eat-pty-win/node-bridge
   npm install
   ```

3. Ensure `eat` is installed in Emacs.

4. Add this Emacs configuration:

   ```elisp
   (use-package eat-pty-win
     :if (eq system-type 'windows-nt)
     :ensure nil
     :load-path "~/.emacs.d/eat-pty-win"
     :commands (eat-pty-win))

   (global-set-key
    (kbd "C-c o s p")
    (if (eq system-type 'windows-nt)
        #'eat-pty-win
      #'vterm))
   ```

   The non-Windows branch assumes that `vterm` is already installed and
   configured in your Emacs setup.

## Usage

```text
M-x eat-pty-win
```

Prefix behavior:

```text
C-u M-x eat-pty-win      open in a right side window
C-u C-u M-x eat-pty-win  prompt for the shell command
```

Mode keys:

```text
C-c C-l    eat-line-mode
C-c C-j    eat-semi-char-mode
C-c M-d    eat-char-mode
C-c C-c    send Ctrl+C to the terminal process
C-j/S-RET  send Shift+Enter for Copilot CLI multiline input
C-c C-k    eat-kill-process
C-g        interrupt stalled Eat rendering
```

The package supports incremental Emacs `korean-hangul` input in semi-char and
char modes.  Hangul composition is sent directly to ConPTY instead of inserting
text into the terminal buffer.

## TUI output handling

`eat-pty-win` applies bounded output flow control so continuously redrawing
applications do not overwhelm Emacs.  It also works around an Eat 0.9.4 loop
that can occur when a character wider than one column starts in the final
terminal column.  This is relevant on Windows because the GUI character-width
table can classify box-drawing and block characters used by applications such
as Copilot CLI as two columns.  `eat-pty-win` uses terminal-compatible
single-column widths for ambiguous drawing characters and general punctuation
without changing the width of Korean text.

The bridge coalesces up to 64 KiB of output per acknowledgement.  This keeps a
full-screen TUI redraw intact when changing between one and two windows instead
of exposing a partially rendered frame between smaller chunks.

### Resize synchronization

Emacs can report several transient dimensions while windows are split, merged,
or resized.  Full-screen TUIs such as Copilot CLI can redraw at the same time,
so applying each transient size to Eat and ConPTY can mix output for one grid
size with another grid.

`eat-pty-win` records the latest requested size and waits until terminal output
has been idle for `eat-pty-win-resize-delay` seconds (0.25 by default).  It then
resizes Eat and ConPTY together to that final size.  This prevents Copilot CLI
session restoration from leaving its cursor or input area at a stale position
when the Emacs window layout changes.

This is an output-idle synchronization policy rather than a full resize
transaction.  If a future TUI still corrupts its display during resize, evolve
the bridge protocol to pause output, drain and acknowledge in-flight output,
resize Eat and ConPTY with a generation identifier, acknowledge the applied
size, and then resume output.  Do not work around that case by adding more
independent resize hooks or timers.

Unicode output is preserved by default, including Korean text and TUI drawing
characters.  If a separate rendering issue requires ASCII-safe drawing
characters, enable the optional bridge sanitizer:

```elisp
(setq eat-pty-win-sanitize-ui-glyphs 'auto)
```

If an unknown Eat parser loop occurs, press `C-g`.  Rendering for that terminal
is suspended, the bridge remains paused, and Emacs returns to the command loop.
Use `C-c C-k` to terminate the affected terminal.  Rendering is not resumed
automatically because the terminal state may have been only partially updated.

For diagnosing a stall, configure a local file before opening the terminal:

```elisp
(setq eat-pty-win-diagnostic-file
      (expand-file-name ".diagnostics/eat-pty-win-stalled-output.log"
                        user-emacs-directory))
```

The bridge writes the last unacknowledged output chunk after three seconds.
This file can contain terminal text and is therefore disabled by default.

## Security notes

- `node_modules/`, log files, compiled `.elc` files, and `.env` files are
  ignored by `.gitignore`.
- The bridge passes the Emacs process environment to the spawned shell, like a
  normal terminal.  Do not start untrusted shells or commands with sensitive
  environment variables.
- The Node bridge package is marked `"private": true` to prevent accidental npm
  publication.
- Before publishing, you can check the Node dependency with:

  ```powershell
  cd ~/.emacs.d/eat-pty-win/node-bridge
  npm audit --omit=dev
  ```
