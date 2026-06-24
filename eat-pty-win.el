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
  (let ((node-bridge (expand-file-name "eat-pty-win/node-bridge/conpty-node-bridge.js"
                                       user-emacs-directory)))
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

(defvar-local eat-pty-win--last-size nil)

(defvar eat-pty-win-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-l") #'eat-line-mode)
    (define-key map (kbd "C-c C-j") #'eat-semi-char-mode)
    (define-key map (kbd "C-c M-d") #'eat-char-mode)
    (define-key map (kbd "C-c C-k") #'eat-kill-process)
    map)
  "Keymap for `eat-pty-win-mode'.")

(defun eat-pty-win--eat-exec-direct (buffer name command switches)
  "Start COMMAND with SWITCHES in BUFFER without Eat's Unix shell wrapper."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (when-let* ((eat-terminal)
                  (proc (eat-term-parameter
                         eat-terminal 'eat--process)))
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
            #'eat--send-input)
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
                        eat-term-shell-integration-directory))
               process-environment))
             (inhibit-eol-conversion t)
             (process
              (make-process
               :name name
               :buffer buffer
               :command (cons command switches)
               :connection-type 'pipe
               :coding 'utf-8
               :filter #'eat--filter
               :sentinel #'eat--sentinel
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
        (add-hook 'window-size-change-functions
                  #'eat-pty-win--window-size-change)
        (run-at-time 0.05 nil
                     (lambda (buffer)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (eat-pty-win--send-resize))))
                     (current-buffer)))
    (remove-hook 'window-size-change-functions
                 #'eat-pty-win--window-size-change)))

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
    (eat-char-mode)
    (eat-pty-win--send-resize)
    buffer))

(provide 'eat-pty-win)

;;; eat-pty-win.el ends here
