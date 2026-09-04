;;; eat-pty-win.el --- ConPTY terminal for Windows via Eat -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1") (eat "0.9.4"))

;; This file is intentionally small: Eat handles terminal emulation, while
;; node-pty owns the Windows pseudo console.

;;; Code:

(require 'cl-lib)
(require 'eat)
(require 'subr-x)

(declare-function centered-cursor-mode "centered-cursor-mode")
(declare-function hangul-alphabetp "hangul")
(declare-function hangul-delete-backward-char "hangul")
(declare-function hangul2-input-method-internal "hangul")
(declare-function quail-setup-overlays "quail")

(defvar eat-pty-win-mode)
(defvar eat-pty-win--processing-output nil)

(defun eat-pty-win--handle-output-interruptibly (handle output)
  "Call HANDLE for OUTPUT while allowing `C-g' to interrupt Eat parsing."
  (if eat-pty-win--processing-output
      (let ((inhibit-quit nil))
        (funcall handle output))
    (funcall handle output)))

(defun eat-pty-win--write-wide-chars-safely (write str &optional beg end)
  "Call WRITE for STR without stalling on a wide character at the right edge."
  (if (not eat-pty-win--processing-output)
      (funcall write str beg end)
    (let* ((start (or beg 0))
           (end (or end (length str)))
           (segment-beg start)
           (index start))
      (while (< index end)
        (let ((width (char-width (aref str index))))
          (if (= width 1)
              (cl-incf index)
            (when (< segment-beg index)
              (funcall write str segment-beg index))
            (when (> width 1)
              (let* ((disp (eat--t-term-display eat--t-term))
                     (cursor (eat--t-disp-cursor disp))
                     (remaining
                      (- (eat--t-disp-width disp)
                         (1- (eat--t-cur-x cursor)))))
                (when (and (> remaining 0)
                           (< remaining width))
                  (funcall write (make-string remaining ?\s)))))
            (funcall write str index (1+ index))
            (cl-incf index)
            (setq segment-beg index))))
      (when (< segment-beg end)
        (funcall write str segment-beg end)))))

(advice-remove 'eat--t-handle-output
               #'eat-pty-win--handle-output-interruptibly)
(advice-add 'eat--t-handle-output :around
            #'eat-pty-win--handle-output-interruptibly)
(advice-remove 'eat--t-write #'eat-pty-win--write-wide-chars-safely)
(advice-add 'eat--t-write :around #'eat-pty-win--write-wide-chars-safely)

(defgroup eat-pty-win nil
  "Windows ConPTY terminal integration."
  :group 'terminals)

(defcustom eat-pty-win-bridge-executable
  (or (executable-find "node.exe")
      (executable-find "node"))
  "Path to node.exe used to run the node-pty bridge."
  :type 'file)

(defcustom eat-pty-win-bridge-args
  (let ((node-bridge (expand-file-name "node-bridge/conpty-node-bridge.js"
                                       (file-name-directory
                                        (or load-file-name buffer-file-name)))))
    (when (and (executable-find "node.exe")
               (file-exists-p node-bridge))
      (list node-bridge)))
  "Arguments passed to `eat-pty-win-bridge-executable' before terminal options."
  :type '(repeat string))

(defcustom eat-pty-win-shell
  (or (executable-find "pwsh.exe")
      (executable-find "powershell.exe")
      (executable-find "cmd.exe"))
  "Shell executable started inside ConPTY."
  :type '(choice file string))

(defcustom eat-pty-win-shell-args nil
  "Arguments passed to `eat-pty-win-shell'."
  :type '(repeat string))

(defun eat-pty-win--bridge-executable ()
  "Return the effective bridge executable."
  (or eat-pty-win-bridge-executable
      (executable-find "node.exe")
      (executable-find "node")))

(defcustom eat-pty-win-powershell-edit-mode nil
  "Optional PSReadLine edit mode used for PowerShell shells.

The default nil keeps the user's PowerShell profile setting."
  :type '(choice (const :tag "Keep profile setting" nil)
                 (string :tag "PSReadLine edit mode")))

(defcustom eat-pty-win-output-throttle-delay 0.005
  "Seconds to wait between bounded terminal output drain passes.

This keeps Emacs responsive when full-screen TUIs redraw continuously."
  :type 'number)

(defcustom eat-pty-win-output-chunk-size 16384
  "Maximum bytes of terminal output rendered in one drain pass."
  :type 'integer)

(defcustom eat-pty-win-output-drain-time-budget 0.02
  "Maximum seconds spent rendering terminal output in one timer pass."
  :type 'number)

(defcustom eat-pty-win-output-ack-delay 0.0
  "Seconds to wait before ACKing a rendered output chunk to the bridge.

The delay lets Emacs return to the command loop and perform GUI redisplay before
the bridge is allowed to send the next chunk."
  :type 'number)

(defcustom eat-pty-win-output-ack-timeout 3.0
  "Seconds the bridge waits for an output ACK before remaining paused."
  :type 'number)

(defcustom eat-pty-win-diagnostic-file nil
  "Optional file where the bridge records a chunk that did not receive an ACK.

The file can contain terminal output, so leave this nil unless diagnosing a
rendering stall."
  :type '(choice (const :tag "Disabled" nil)
                 (file :tag "Diagnostic file")))

(defcustom eat-pty-win-output-filter-rate-limit 120
  "Maximum process filter calls per second before pausing bridge output."
  :type 'integer)

(defcustom eat-pty-win-output-pause-duration 0.1
  "Seconds to pause bridge output after detecting continuous redraw overload."
  :type 'number)

(defcustom eat-pty-win-output-max-pending-bytes (* 64 1024)
  "Maximum queued terminal output bytes before old output is dropped."
  :type 'integer)

(defcustom eat-pty-win-strip-unsafe-output-sequences t
  "Non-nil means bridge strips DCS/Sixel/OSC/APC/PM string controls before Eat."
  :type 'boolean)

(defcustom eat-pty-win-sanitize-ui-glyphs nil
  "Control whether bridge replaces risky TUI drawing glyphs with ASCII.

The default nil preserves all Unicode output.  Set this to `auto' to enable
sanitizing only after AI CLI output is detected, or t to enable it for all
output.  The sanitizer preserves normal non-ASCII text such as Korean, but
replaces box drawing and spinner symbols."
  :type '(choice (const :tag "Auto-detect AI CLI output" auto)
                 (const :tag "Always enabled" t)
                 (const :tag "Disabled" nil)))

(defvar-local eat-pty-win--last-size nil)
(defvar-local eat-pty-win--pending-output "")
(defvar-local eat-pty-win--output-timer nil)
(defvar-local eat-pty-win--output-dropped nil)
(defvar-local eat-pty-win--saved-overriding-map-alist nil)
(defvar-local eat-pty-win--emergency-keys-installed nil)
(defvar-local eat-pty-win--filter-window-start nil)
(defvar-local eat-pty-win--filter-window-count 0)
(defvar-local eat-pty-win--bridge-paused nil)
(defvar-local eat-pty-win--bridge-resume-timer nil)
(defvar-local eat-pty-win--ack-timer nil)
(defvar-local eat-pty-win--rendering-suspended nil)
(defvar-local eat-pty-win--rendering-suspend-reason nil)
(defvar-local eat-pty-win--hangul-buffer nil)
(defvar-local eat-pty-win--hangul-displayed "")
(defvar-local eat-pty-win--original-input-method-function nil)

(defvar eat-pty-win-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-g") #'keyboard-quit)
    (define-key map (kbd "C-c C-c") #'eat-pty-win-send-ctrl-c)
    (define-key map (kbd "C-j") #'eat-pty-win-send-shift-return)
    (define-key map (kbd "<S-return>") #'eat-pty-win-send-shift-return)
    (define-key map (kbd "C-c C-l") #'eat-line-mode)
    (define-key map (kbd "C-c C-j") #'eat-semi-char-mode)
    (define-key map (kbd "C-c M-d") #'eat-char-mode)
    (define-key map (kbd "C-c C-k") #'eat-pty-win-kill-process)
    map)
  "Keymap for `eat-pty-win-mode'.")

(defun eat-pty-win--cancel-output-timer ()
  "Cancel the pending output drain timer in the current buffer."
  (when eat-pty-win--output-timer
    (cancel-timer eat-pty-win--output-timer)
    (setq eat-pty-win--output-timer nil)))

(defun eat-pty-win--clear-output-queue ()
  "Clear queued terminal output in the current buffer."
  (eat-pty-win--cancel-output-timer)
  (setq eat-pty-win--pending-output "")
  (setq eat-pty-win--output-dropped nil))

(defun eat-pty-win--send-input (_ input)
  "Send INPUT to subprocess."
  (when-let* ((eat-terminal)
              (proc (eat-term-parameter eat-terminal 'eat--process)))
    (process-send-string proc input)))

(defun eat-pty-win--cancel-bridge-resume-timer ()
  "Cancel bridge resume timer in the current buffer."
  (when eat-pty-win--bridge-resume-timer
    (cancel-timer eat-pty-win--bridge-resume-timer)
    (setq eat-pty-win--bridge-resume-timer nil)))

(defun eat-pty-win--cancel-ack-timer ()
  "Cancel pending output ACK timer in the current buffer."
  (when eat-pty-win--ack-timer
    (cancel-timer eat-pty-win--ack-timer)
    (setq eat-pty-win--ack-timer nil)))

(defun eat-pty-win--send-flow-command (process command)
  "Send bridge flow-control COMMAND to PROCESS."
  (when (process-live-p process)
    (process-send-string process (format "\e]777;flow;%s\a" command))))

(defun eat-pty-win--ack-output (process)
  "Tell bridge that one output chunk has been rendered."
  (eat-pty-win--send-flow-command process "ack"))

(defun eat-pty-win--schedule-output-ack (buffer process)
  "Schedule delayed ACK for PROCESS in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (eat-pty-win--cancel-ack-timer)
      (setq eat-pty-win--ack-timer
            (run-at-time eat-pty-win-output-ack-delay nil
                         (lambda (ack-buffer ack-process)
                           (when (buffer-live-p ack-buffer)
                             (with-current-buffer ack-buffer
                               (setq eat-pty-win--ack-timer nil)
                               (eat-pty-win--ack-output ack-process))))
                         buffer process)))))

(defun eat-pty-win--resume-bridge (buffer process)
  "Resume bridge output for BUFFER and PROCESS."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq eat-pty-win--bridge-resume-timer nil)
      (when eat-pty-win--bridge-paused
        (setq eat-pty-win--bridge-paused nil)
        (eat-pty-win--send-flow-command process "resume")))))

(defun eat-pty-win--pause-bridge (process)
  "Temporarily pause bridge output from PROCESS."
  (unless eat-pty-win--bridge-paused
    (setq eat-pty-win--bridge-paused t)
    (eat-pty-win--clear-output-queue)
    (eat-pty-win--send-flow-command process "pause")
    (eat-pty-win--cancel-bridge-resume-timer)
    (setq eat-pty-win--bridge-resume-timer
          (run-at-time eat-pty-win-output-pause-duration nil
                       #'eat-pty-win--resume-bridge
                       (current-buffer) process))))

(defun eat-pty-win--record-filter-call (process)
  "Return non-nil when PROCESS output should be paused for overload."
  (let ((now (float-time)))
    (if (or (null eat-pty-win--filter-window-start)
            (>= (- now eat-pty-win--filter-window-start) 1.0))
        (setq eat-pty-win--filter-window-start now
              eat-pty-win--filter-window-count 1)
      (cl-incf eat-pty-win--filter-window-count))
    (when (and (not eat-pty-win--bridge-paused)
               (> eat-pty-win--filter-window-count
                  eat-pty-win-output-filter-rate-limit))
      (eat-pty-win--pause-bridge process)
      t)))

(defun eat-pty-win-kill-process ()
  "Kill the current eat-pty-win process without draining queued output first."
  (interactive)
  (eat-pty-win--clear-output-queue)
  (eat-pty-win--cancel-bridge-resume-timer)
  (eat-pty-win--cancel-ack-timer)
  (eat-kill-process))

(defun eat-pty-win-send-ctrl-c ()
  "Send a literal Ctrl+C character to the terminal process."
  (interactive)
  (eat-pty-win--reset-hangul)
  (eat-pty-win--send-text "\C-c"))

(defun eat-pty-win-send-shift-return ()
  "Send Shift+Enter using Copilot CLI's multiline input sequence."
  (interactive)
  (eat-pty-win--reset-hangul)
  (eat-pty-win--send-text "\e\r"))

(defun eat-pty-win--send-text (text)
  "Send TEXT directly to the terminal process."
  (unless (string-empty-p text)
    (when-let* ((eat-terminal)
                (process (eat-term-parameter eat-terminal 'eat--process)))
      (process-send-string process text))))

(defun eat-pty-win--hangul-buffer ()
  "Return the persistent Hangul composition buffer."
  (unless (buffer-live-p eat-pty-win--hangul-buffer)
    (setq-local eat-pty-win--hangul-buffer
                (generate-new-buffer " *eat-pty-win-hangul*"))
    (with-current-buffer eat-pty-win--hangul-buffer
      (require 'hangul)
      (setq-local hangul-queue (make-vector 6 0))
      (quail-setup-overlays nil)))
  eat-pty-win--hangul-buffer)

(defun eat-pty-win--update-hangul (text)
  "Replace the Hangul composition displayed in the terminal with TEXT."
  (let* ((old eat-pty-win--hangul-displayed)
         (limit (min (length old) (length text)))
         (prefix 0))
    (while (and (< prefix limit)
                (= (aref old prefix) (aref text prefix)))
      (cl-incf prefix))
    (eat-pty-win--send-text
     (concat (make-string (- (length old) prefix) ?\177)
             (substring text prefix)))
    (setq eat-pty-win--hangul-displayed text)))

(defun eat-pty-win--reset-hangul ()
  "Commit and reset the internal Hangul composition state."
  (when (buffer-live-p eat-pty-win--hangul-buffer)
    (with-current-buffer eat-pty-win--hangul-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq-local hangul-queue (make-vector 6 0))
        (quail-setup-overlays nil))))
  (setq eat-pty-win--hangul-displayed ""))

(defun eat-pty-win--input-method (key)
  "Incrementally compose Korean Hangul input for the terminal."
  (if (and (equal current-input-method "korean-hangul")
           (hangul-alphabetp key))
      (let ((text
             (with-current-buffer (eat-pty-win--hangul-buffer)
               (let ((input-method-function nil))
                 (hangul2-input-method-internal key))
               (buffer-string))))
        (eat-pty-win--update-hangul text)
        nil)
    (eat-pty-win--reset-hangul)
    (list key)))

(defun eat-pty-win--wrap-input-method ()
  "Install terminal-safe handling for the active Korean input method."
  (when (and (equal current-input-method "korean-hangul")
             input-method-function
             (not (eq input-method-function #'eat-pty-win--input-method)))
    (setq eat-pty-win--original-input-method-function input-method-function)
    (setq-local input-method-function #'eat-pty-win--input-method)))

(defun eat-pty-win--input-method-activated ()
  "Configure an input method activated in an eat-pty-win buffer."
  (when eat-pty-win-mode
    (eat-pty-win--wrap-input-method)))

(defun eat-pty-win--send-backspace ()
  "Delete one Hangul Jaso or send a normal terminal Backspace."
  (interactive)
  (if (and (equal current-input-method "korean-hangul")
           (not (string-empty-p eat-pty-win--hangul-displayed)))
      (let ((text
             (with-current-buffer (eat-pty-win--hangul-buffer)
               (hangul-delete-backward-char)
               (buffer-string))))
        (eat-pty-win--update-hangul text))
    (eat-self-input 1 ?\177)))

(defun eat-pty-win--setup-character-widths ()
  "Use terminal-compatible widths for ambiguous TUI drawing characters."
  (setq-local char-width-table (copy-sequence char-width-table))
  (dolist (range '((#x2190 . #x21ff)
                   (#x2500 . #x259f)
                   (#x25a0 . #x25ff)))
    (set-char-table-range char-width-table range 1))
  (dolist (character '(#x00b7 #x2026 #x276f))
    (set-char-table-range char-width-table character 1)))

(defun eat-pty-win--cleanup-buffer ()
  "Clean up helper state owned by the current terminal buffer."
  (when (buffer-live-p eat-pty-win--hangul-buffer)
    (kill-buffer eat-pty-win--hangul-buffer))
  (setq eat-pty-win--hangul-buffer nil))

(defun eat-pty-win--suspend-rendering (process reason)
  "Suspend rendering from PROCESS after REASON."
  (setq eat-pty-win--rendering-suspended t)
  (setq eat-pty-win--rendering-suspend-reason reason)
  (setq eat-pty-win--bridge-paused t)
  (eat-pty-win--cancel-bridge-resume-timer)
  (eat-pty-win--cancel-ack-timer)
  (eat-pty-win--clear-output-queue)
  (eat-pty-win--send-flow-command process "pause")
  (message "eat-pty-win rendering suspended: %s; use C-c C-k to stop the terminal"
           reason))

(defun eat-pty-win--process-output-interruptibly (process output)
  "Render OUTPUT from PROCESS, suspending the terminal when `C-g' interrupts."
  (condition-case nil
      (progn
        (let ((eat-pty-win--processing-output t))
          (eat-term-process-output eat-terminal output))
        t)
    (quit
     (eat-pty-win--suspend-rendering process "interrupted with C-g")
     nil)))

(defun eat-pty-win--emergency-keymap (base-map)
  "Return BASE-MAP plus eat-pty-win emergency bindings."
  (let ((map (copy-keymap base-map)))
    (define-key map [?\C-g] #'keyboard-quit)
    (define-key map (kbd "DEL") #'eat-pty-win--send-backspace)
    (define-key map (kbd "<backspace>") #'eat-pty-win--send-backspace)
    (define-key map (kbd "C-j") #'eat-pty-win-send-shift-return)
    (define-key map (kbd "<S-return>") #'eat-pty-win-send-shift-return)
    (define-key map [?\C-c] (make-sparse-keymap))
    (define-key map [?\C-c ?\C-c] #'eat-pty-win-send-ctrl-c)
    (define-key map [?\C-c ?\C-k] #'eat-pty-win-kill-process)
    (define-key map [?\C-c ?\C-e] #'eat-emacs-mode)
    (define-key map [?\C-c ?\C-j] #'eat-semi-char-mode)
    (define-key map [?\C-c ?\C-l] #'eat-line-mode)
    (define-key map [?\C-c ?\M-d] #'eat-char-mode)
    map))

(defun eat-pty-win--install-emergency-keys ()
  "Install buffer-local emergency bindings that win over Eat char maps."
  (unless eat-pty-win--emergency-keys-installed
    (setq eat-pty-win--saved-overriding-map-alist
          minor-mode-overriding-map-alist)
    (setq eat-pty-win--emergency-keys-installed t))
  (setq-local
   minor-mode-overriding-map-alist
   (append
    `((eat--char-mode . ,(eat-pty-win--emergency-keymap eat-char-mode-map))
      (eat--semi-char-mode . ,(eat-pty-win--emergency-keymap
                               eat-semi-char-mode-map)))
    eat-pty-win--saved-overriding-map-alist)))

(defun eat-pty-win--uninstall-emergency-keys ()
  "Restore buffer-local emergency key overrides."
  (when eat-pty-win--emergency-keys-installed
    (setq-local minor-mode-overriding-map-alist
                eat-pty-win--saved-overriding-map-alist)
    (setq eat-pty-win--saved-overriding-map-alist nil)
    (setq eat-pty-win--emergency-keys-installed nil)))

(defun eat-pty-win--process-output-batch (process outputs)
  "Render bounded OUTPUTS from PROCESS with one redisplay."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((sync-windows (eat--synchronize-scroll-windows))
            (eat--auto-line-mode-pending-toggles nil)
            (render-ok t))
        (save-restriction
          (widen)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (buffer-undo-list t))
            (when eat--process-output-queue-timer
              (cancel-timer eat--process-output-queue-timer)
              (setq eat--process-output-queue-timer nil))
            (when eat--shell-prompt-annotation-correction-timer
              (cancel-timer eat--shell-prompt-annotation-correction-timer)
              (setq eat--shell-prompt-annotation-correction-timer nil))
            (setq eat--output-queue-first-chunk-time nil)
            (dolist (output outputs)
              (when render-ok
                (setq render-ok
                      (eat-pty-win--process-output-interruptibly
                       process output))))
            (when render-ok
              (eat-term-redisplay eat-terminal)
              (when (and eat-term-scrollback-size
                         (< eat-term-scrollback-size
                            (- (point) (point-min))))
                (delete-region
                 (point-min)
                 (max (point-min)
                      (- (eat-term-display-beginning eat-terminal)
                         eat-term-scrollback-size))))
              (unless (> (length eat-pty-win--pending-output) 0)
                (setq eat--shell-prompt-annotation-correction-timer
                      (run-with-timer
                       eat-shell-prompt-annotation-correction-delay
                       nil #'eat--correct-shell-prompt-mark-overlays
                       (current-buffer))))
              (add-text-properties
               (eat-term-beginning eat-terminal)
               (eat-term-end eat-terminal)
               `(read-only t field eat-terminal
                           ,@(when eat--line-mode
                               '(front-sticky t rear-nonsticky t)))))))
        (when render-ok
          (eat--line-mode-do-toggles)
          (funcall eat--synchronize-scroll-function sync-windows)
          (eat-pty-win--schedule-output-ack (current-buffer) process)
          (run-hooks 'eat-update-hook))))))

(defun eat-pty-win--drain-output (buffer process)
  "Drain one queued output chunk for BUFFER from PROCESS."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq eat-pty-win--output-timer nil)
      (when (and (process-live-p process)
                 (not eat-pty-win--rendering-suspended)
                 (> (length eat-pty-win--pending-output) 0)
                 (not (input-pending-p)))
        (let ((deadline (+ (float-time)
                           eat-pty-win-output-drain-time-budget))
              outputs)
          (while (and (> (length eat-pty-win--pending-output) 0)
                      (not (input-pending-p))
                      (< (float-time) deadline))
            (let* ((size (min eat-pty-win-output-chunk-size
                              (length eat-pty-win--pending-output)))
                   (output (substring eat-pty-win--pending-output 0 size)))
              (setq eat-pty-win--pending-output
                    (substring eat-pty-win--pending-output size))
              (push output outputs)))
          (when outputs
            (eat-pty-win--process-output-batch process (nreverse outputs)))))
      (when (and (not eat-pty-win--rendering-suspended)
                 (> (length eat-pty-win--pending-output) 0))
        (setq eat-pty-win--output-timer
              (run-at-time eat-pty-win-output-throttle-delay nil
                           #'eat-pty-win--drain-output
                           buffer process))))))

(defun eat-pty-win--schedule-output-drain (buffer process)
  "Schedule bounded output draining for BUFFER and PROCESS."
  (with-current-buffer buffer
    (unless (or eat-pty-win--rendering-suspended
                eat-pty-win--output-timer)
      (setq eat-pty-win--output-timer
            (run-at-time eat-pty-win-output-throttle-delay nil
                         #'eat-pty-win--drain-output
                         buffer process)))))

(defun eat-pty-win--filter (process output)
  "Queue PROCESS OUTPUT and render it in bounded chunks."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (unless (or eat-pty-win--rendering-suspended
                  (eat-pty-win--record-filter-call process))
        (when (> (length output) eat-pty-win-output-max-pending-bytes)
          (setq output
                (substring output
                           (- (length output)
                              eat-pty-win-output-max-pending-bytes))))
        (setq eat-pty-win--pending-output
              (concat eat-pty-win--pending-output output))
        (when (> (length eat-pty-win--pending-output)
                 eat-pty-win-output-max-pending-bytes)
          (setq eat-pty-win--pending-output
                (substring
                 eat-pty-win--pending-output
                 (- (length eat-pty-win--pending-output)
                    eat-pty-win-output-max-pending-bytes)))
          (unless eat-pty-win--output-dropped
            (setq eat-pty-win--output-dropped t)
            (message "eat-pty-win dropped old terminal output to keep Emacs responsive")))
        (eat-pty-win--schedule-output-drain (current-buffer) process)))))

(defun eat-pty-win--sentinel (process message)
  "Sentinel for PROCESS with bounded-output cleanup before MESSAGE handling."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (eat-pty-win--cancel-bridge-resume-timer)
      (eat-pty-win--cancel-ack-timer)
      (eat-pty-win--clear-output-queue)))
  (eat--sentinel process message))

(defun eat-pty-win--eat-exec-direct (buffer name command switches)
  "Start COMMAND with SWITCHES in BUFFER without Eat's Unix shell wrapper."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (when-let* ((eat-terminal)
                  (proc (eat-term-parameter
                         eat-terminal 'eat--process)))
        (eat-pty-win--clear-output-queue)
        (delete-process proc))
      (goto-char (point-max))
      (unless (or (= (point-min) (point-max))
                  (= (char-before (point-max)) ?\n))
        (insert ?\n))
      (unless (= (point-min) (point-max))
        (insert "\n\n"))
      (setq eat-terminal (eat-term-make buffer (point)))
      (eat-semi-char-mode)
      (when-let* ((window (get-buffer-window nil t)))
        (with-selected-window window
          (eat-term-resize eat-terminal (window-body-width)
                           (window-body-height))))
      (setf (eat-term-parameter eat-terminal 'input-function)
            #'eat-pty-win--send-input)
      (setf (eat-term-parameter eat-terminal 'set-cursor-function)
            #'eat--set-cursor)
      (setf (eat-term-parameter eat-terminal 'grab-mouse-function)
            #'eat--grab-mouse)
      (setf (eat-term-parameter
             eat-terminal 'manipulate-selection-function)
            #'eat--manipulate-kill-ring)
      (setf (eat-term-parameter eat-terminal 'ring-bell-function)
            #'eat--bell)
      (setf (eat-term-parameter eat-terminal 'set-cwd-function)
            #'eat--set-cwd)
      (setf (eat-term-parameter eat-terminal 'ui-command-function)
            #'eat--handle-uic)
      (eat--set-term-sixel-params)
      (let* ((process-environment
              (nconc
               (list
                (concat "TERM=" (eat-term-name))
                (concat "TERMINFO=" eat-term-terminfo-directory)
                (concat "INSIDE_EMACS=" eat-term-inside-emacs)
                (concat "EAT_SHELL_INTEGRATION_DIR="
                        eat-term-shell-integration-directory)
                (concat "EAT_PTY_WIN_STRIP_UNSAFE="
                        (if eat-pty-win-strip-unsafe-output-sequences
                            "1"
                          "0"))
                (concat "EAT_PTY_WIN_SANITIZE_UI_GLYPHS="
                        (pcase eat-pty-win-sanitize-ui-glyphs
                          ('auto "auto")
                          ('nil "0")
                          (_ "1")))
                (format "EAT_PTY_WIN_ACK_TIMEOUT_MS=%d"
                        (round (* 1000 eat-pty-win-output-ack-timeout)))
                (format "EAT_PTY_WIN_OUTPUT_CHUNK_SIZE=%d"
                        eat-pty-win-output-chunk-size)
                (concat "EAT_PTY_WIN_DIAGNOSTIC_FILE="
                        (if eat-pty-win-diagnostic-file
                            (expand-file-name eat-pty-win-diagnostic-file)
                          "")))
               process-environment))
             (inhibit-eol-conversion t)
             (process
              (make-process
               :name name
               :buffer buffer
               :command (cons command switches)
               :connection-type 'pipe
               :coding 'utf-8
               :filter #'eat-pty-win--filter
               :sentinel #'eat-pty-win--sentinel
               :file-handler t)))
        (process-put process 'adjust-window-size-function
                     #'eat--adjust-process-window-size)
        (set-process-query-on-exit-flag
         process eat-query-before-killing-running-terminal)
        (goto-char (point-max))
        (set-marker (process-mark process) (point))
        (setf (eat-term-parameter eat-terminal 'eat--process)
              process)
        (setf (eat-term-parameter eat-terminal 'eat--input-process)
              process)
        (setf (eat-term-parameter eat-terminal 'eat--output-process)
              process))
      (eat-term-redisplay eat-terminal))
    (run-hook-with-args 'eat-exec-hook (eat-term-parameter
                                        eat-terminal 'eat--process))
    buffer))

(defun eat-pty-win--buffer-size ()
  "Return current terminal size as (COLUMNS . ROWS)."
  (let* ((window (or (get-buffer-window (current-buffer) t)
                     (selected-window)))
         (columns (max 20 (window-body-width window)))
         (rows (max 5 (window-body-height window))))
    (cons columns rows)))

(defun eat-pty-win--powershell-p (program)
  "Return non-nil when PROGRAM appears to be pwsh or powershell."
  (let ((name (downcase (file-name-nondirectory program))))
    (member name '("pwsh.exe" "pwsh" "powershell.exe" "powershell"))))

(defun eat-pty-win--default-shell-args ()
  "Return default arguments for `eat-pty-win-shell'."
  (append
   eat-pty-win-shell-args
   (when (and eat-pty-win-powershell-edit-mode
              eat-pty-win-shell
              (eat-pty-win--powershell-p eat-pty-win-shell))
     (list "-NoLogo" "-NoExit" "-Command"
           (format "if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) { Set-PSReadLineOption -EditMode %s }"
                   eat-pty-win-powershell-edit-mode)))))

(defun eat-pty-win--send-resize (&optional process)
  "Tell bridge PROCESS about the current window size."
  (let* ((proc (or process (get-buffer-process (current-buffer))))
         (size (eat-pty-win--buffer-size)))
    (when (and proc
               (process-live-p proc)
               (not (equal size eat-pty-win--last-size)))
      (setq eat-pty-win--last-size size)
      (process-send-string
       proc
       (format "\e]777;resize;%d;%d\a" (car size) (cdr size))))))

(defun eat-pty-win--window-size-change (frame)
  "Propagate window size changes for visible eat-pty-win buffers."
  (dolist (window (window-list frame 'no-minibuf))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'eat-mode)
        (when (bound-and-true-p eat-pty-win-mode)
          (eat-pty-win--send-resize))))))

(define-minor-mode eat-pty-win-mode
  "Minor mode for Eat buffers backed by Windows ConPTY."
  :lighter " epw"
  :keymap eat-pty-win-mode-map
  (if eat-pty-win-mode
      (progn
        (setq eat-pty-win--rendering-suspended nil)
        (setq eat-pty-win--rendering-suspend-reason nil)
        (eat-pty-win--setup-character-widths)
        (when (bound-and-true-p centered-cursor-mode)
          (centered-cursor-mode -1))
        (display-line-numbers-mode -1)
        (eat-pty-win--install-emergency-keys)
        (define-key eat-pty-win-mode-map (kbd "DEL")
                    #'eat-pty-win--send-backspace)
        (define-key eat-pty-win-mode-map (kbd "<backspace>")
                    #'eat-pty-win--send-backspace)
        (add-hook 'input-method-activate-hook
                  #'eat-pty-win--input-method-activated nil t)
        (add-hook 'kill-buffer-hook #'eat-pty-win--cleanup-buffer nil t)
        (eat-pty-win--wrap-input-method)
        (add-hook 'window-size-change-functions
                  #'eat-pty-win--window-size-change)
        (run-at-time 0.05 nil
                     (lambda (buffer)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (eat-pty-win--send-resize))))
                     (current-buffer)))
    (remove-hook 'window-size-change-functions
                 #'eat-pty-win--window-size-change)
    (eat-pty-win--cancel-bridge-resume-timer)
    (eat-pty-win--cancel-ack-timer)
    (eat-pty-win--clear-output-queue)
    (remove-hook 'input-method-activate-hook
                 #'eat-pty-win--input-method-activated t)
    (remove-hook 'kill-buffer-hook #'eat-pty-win--cleanup-buffer t)
    (eat-pty-win--cleanup-buffer)
    (eat-pty-win--uninstall-emergency-keys)))

(defun eat-pty-win--display-buffer (buffer side-window)
  "Display BUFFER in the selected window or a right side window.

When SIDE-WINDOW is non-nil, reuse an existing right side window if possible."
  (if side-window
      (let ((window (display-buffer
                     buffer
                     '((display-buffer-reuse-window
                        display-buffer-in-side-window)
                       (side . right)
                       (slot . 0)
                       (window-width . 0.5)))))
        (select-window window))
    (switch-to-buffer buffer)))

;;;###autoload
(defun eat-pty-win (&optional arg)
  "Start a Windows ConPTY terminal.

With C-u, show the terminal in a right side window.
With C-u C-u, prompt for the shell command in the current window."
  (interactive "P")
  (unless (eq system-type 'windows-nt)
    (user-error "eat-pty-win requires Windows"))
  (let ((bridge-executable (eat-pty-win--bridge-executable)))
    (unless (file-executable-p bridge-executable)
    (user-error "Bridge executable is not executable: %s"
                bridge-executable)))
  (unless eat-pty-win-shell
    (user-error "No Windows shell executable found"))
  (let* ((side-window (equal arg '(4)))
         (prompt-shell (and arg (not side-window)))
         (size (eat-pty-win--buffer-size))
         (shell-args (if prompt-shell
                         (split-string-and-unquote
                          (read-shell-command "ConPTY shell: "
                                              (mapconcat #'identity
                                                         (cons eat-pty-win-shell
                                                               (eat-pty-win--default-shell-args))
                                                         " ")))
                       (cons eat-pty-win-shell
                             (eat-pty-win--default-shell-args))))
         (buffer (generate-new-buffer "*eat-pty-win*"))
         (switches (append eat-pty-win-bridge-args
                           (list "--cols" (number-to-string (car size))
                                 "--rows" (number-to-string (cdr size))
                                 "--")
                           shell-args)))
    (eat-pty-win--display-buffer buffer side-window)
    (eat-mode)
    (eat-pty-win-mode 1)
    (eat-pty-win--eat-exec-direct buffer "eat-pty-win"
                                (eat-pty-win--bridge-executable) switches)
    (eat-semi-char-mode)
    (eat-pty-win--send-resize)
    buffer))

(provide 'eat-pty-win)

;;; eat-pty-win.el ends here
