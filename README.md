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
C-c C-k    eat-kill-process
```

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
