;;; eat-pty-win.el --- ConPTY terminal for Windows via Eat -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1") (eat "0.9.4"))

;; This file is intentionally small: Eat handles terminal emulation, while
;; node-pty owns the Windows pseudo console.

;;; Code:

(require 'cl-lib)
(require 'eat)

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

(defcustom eat-pty-win-output-chunk-size 4096
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

(defcustom eat-pty-win-sanitize-ui-glyphs 'auto
  "Control whether bridge replaces risky TUI drawing glyphs with ASCII.

The default `auto' enables this only after AI CLI output is detected, preserving
normal TUI rendering such as nvim.  The sanitizer preserves normal non-ASCII
text such as Korean, but replaces box drawing and spinner symbols that have
triggered Eat stalls on Windows."
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

(defvar eat-pty-win-mode-map
  (let ((map (make-sparse-keymap)))
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

(defun eat-pty-win--emergency-keymap (base-map)
  "Return BASE-MAP plus eat-pty-win emergency bindings."
  (let ((map (copy-keymap base-map)))
    (define-key map [?\C-c] (make-sparse-keymap))
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
            (eat--auto-line-mode-pending-toggles nil))
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
              (eat-term-process-output eat-terminal output))
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
                             '(front-sticky t rear-nonsticky t))))))
        (eat--line-mode-do-toggles)
        (funcall eat--synchronize-scroll-function sync-windows)
        (eat-pty-win--schedule-output-ack (current-buffer) process)
        (run-hooks 'eat-update-hook)))))

(defun eat-pty-win--drain-output (buffer process)
  "Drain one queued output chunk for BUFFER from PROCESS."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq eat-pty-win--output-timer nil)
      (when (and (process-live-p process)
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
      (when (> (length eat-pty-win--pending-output) 0)
        (setq eat-pty-win--output-timer
              (run-at-time eat-pty-win-output-throttle-delay nil
                           #'eat-pty-win--drain-output
                           buffer process))))))

(defun eat-pty-win--schedule-output-drain (buffer process)
  "Schedule bounded output draining for BUFFER and PROCESS."
  (with-current-buffer buffer
    (unless eat-pty-win--output-timer
      (setq eat-pty-win--output-timer
            (run-at-time eat-pty-win-output-throttle-delay nil
                         #'eat-pty-win--drain-output
                         buffer process)))))

(defun eat-pty-win--filter (process output)
  "Queue PROCESS OUTPUT and render it in bounded chunks."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (unless (eat-pty-win--record-filter-call process)
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
                          (_ "1"))))
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
        (display-line-numbers-mode -1)
        (eat-pty-win--install-emergency-keys)
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
