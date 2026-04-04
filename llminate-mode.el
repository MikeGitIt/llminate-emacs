;;; llminate-mode.el --- Unified minor mode for llminate -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; A single global minor mode that ties together the llminate bridge,
;; chat UI, layout, session management, completion, and editor context.
;; All keybindings live under the C-c q prefix.

;;; Code:

(require 'cl-lib)
(require 'llminate-bridge)
(require 'llminate-chat)
(require 'llminate-layout)
(require 'llminate-session)

;; Optional — loaded only if available
(require 'llminate-completion nil t)

;;;; Customization

(defgroup llminate nil
  "llminate AI coding assistant for Emacs."
  :group 'tools
  :prefix "llminate-")

;;;; Modeline

(defvar llminate-mode--modeline-string " llm[off]"
  "Current modeline indicator string.")

(defun llminate-mode--update-modeline ()
  "Update the modeline string based on bridge state."
  (let ((state (llminate-bridge-state)))
    (setq llminate-mode--modeline-string
          (cond
           ((eq state 'stopped)           " llm[off]")
           ((eq state 'starting)          " llm[start]")
           ((eq state 'idle)              " llm[idle]")
           ((eq state 'streaming)         " llm[streaming]")
           ((eq state 'tool-executing)    " llm[tool]")
           ((eq state 'awaiting-approval) " llm[awaiting]")
           ((eq state 'emacs-eval)        " llm[emacs]")
           (t                             " llm[?]")))
    (force-mode-line-update t)))

;; Hook into bridge events to keep the modeline current
(defun llminate-mode--on-start ()
  "Modeline update for Start."
  (llminate-mode--update-modeline))

(defun llminate-mode--on-ready ()
  "Modeline update for Ready."
  (llminate-mode--update-modeline))

(defun llminate-mode--on-message (_role _content)
  "Modeline update for Message."
  (llminate-mode--update-modeline))

(defun llminate-mode--on-tool-use (name _input)
  "Modeline update for ToolUse — show tool name."
  (setq llminate-mode--modeline-string
        (format " llm[tool:%s]"
                (if (> (length name) 12)
                    (substring name 0 12)
                  name)))
  (force-mode-line-update t))

(defun llminate-mode--on-emacs-eval (command _args _rid)
  "Modeline update for EmacsEval — show command name."
  (setq llminate-mode--modeline-string
        (format " llm[emacs:%s]"
                (if (> (length command) 12)
                    (substring command 0 12)
                  command)))
  (force-mode-line-update t))

(defun llminate-mode--on-end (_reason)
  "Modeline update for End."
  (llminate-mode--update-modeline))

(defun llminate-mode--on-error (_msg)
  "Modeline update for Error."
  (llminate-mode--update-modeline))

(defun llminate-mode--on-approval (_event)
  "Modeline update for ToolApproval."
  (llminate-mode--update-modeline))

(defun llminate-mode--register-modeline-hooks ()
  "Register hooks that keep the modeline indicator up to date."
  (add-hook 'llminate-bridge-start-hook         #'llminate-mode--on-start)
  (add-hook 'llminate-bridge-ready-hook         #'llminate-mode--on-ready)
  (add-hook 'llminate-bridge-message-hook       #'llminate-mode--on-message)
  (add-hook 'llminate-bridge-tool-use-hook      #'llminate-mode--on-tool-use)
  (add-hook 'llminate-bridge-emacs-eval-hook    #'llminate-mode--on-emacs-eval)
  (add-hook 'llminate-bridge-end-hook           #'llminate-mode--on-end)
  (add-hook 'llminate-bridge-error-hook         #'llminate-mode--on-error)
  (add-hook 'llminate-bridge-tool-approval-hook #'llminate-mode--on-approval))

(defun llminate-mode--unregister-modeline-hooks ()
  "Remove modeline hooks."
  (remove-hook 'llminate-bridge-start-hook         #'llminate-mode--on-start)
  (remove-hook 'llminate-bridge-ready-hook         #'llminate-mode--on-ready)
  (remove-hook 'llminate-bridge-message-hook       #'llminate-mode--on-message)
  (remove-hook 'llminate-bridge-tool-use-hook      #'llminate-mode--on-tool-use)
  (remove-hook 'llminate-bridge-emacs-eval-hook    #'llminate-mode--on-emacs-eval)
  (remove-hook 'llminate-bridge-end-hook           #'llminate-mode--on-end)
  (remove-hook 'llminate-bridge-error-hook         #'llminate-mode--on-error)
  (remove-hook 'llminate-bridge-tool-approval-hook #'llminate-mode--on-approval))

;;;; Interactive commands wired to keybindings

(defun llminate-explain-region (beg end)
  "Send the region between BEG and END to llminate for explanation."
  (interactive "r")
  (let ((text (buffer-substring-no-properties beg end))
        (lang (or (when (boundp 'llminate-completion--mode-language-alist)
                    (alist-get major-mode llminate-completion--mode-language-alist))
                  (symbol-name major-mode))))
    (llminate-bridge-ensure-running)
    (llminate-chat-show)
    (let ((prompt (format "Explain this %s code:\n\n```%s\n%s\n```" lang lang text)))
      ;; Insert into prompt buffer and send
      (with-current-buffer (llminate-chat--prompt-buffer)
        (erase-buffer)
        (insert prompt))
      (llminate-chat-send))))

(defun llminate-fix-region (beg end)
  "Send the region between BEG and END to llminate for fixing/refactoring."
  (interactive "r")
  (let ((text (buffer-substring-no-properties beg end))
        (lang (or (when (boundp 'llminate-completion--mode-language-alist)
                    (alist-get major-mode llminate-completion--mode-language-alist))
                  (symbol-name major-mode))))
    (llminate-bridge-ensure-running)
    (llminate-chat-show)
    (let ((prompt (format "Fix or improve this %s code:\n\n```%s\n%s\n```" lang lang text)))
      (with-current-buffer (llminate-chat--prompt-buffer)
        (erase-buffer)
        (insert prompt))
      (llminate-chat-send))))

(defun llminate-send-diagnostics ()
  "Send current buffer diagnostics (flymake/eglot) to llminate."
  (interactive)
  (let ((diags (llminate-mode--collect-diagnostics))
        (file (or (buffer-file-name) (buffer-name))))
    (if (null diags)
        (message "[llminate] No diagnostics in current buffer")
      (llminate-bridge-ensure-running)
      (llminate-chat-show)
      (let ((prompt (format "Here are the current diagnostics for %s:\n\n%s\n\nPlease help fix these issues."
                            file
                            (mapconcat #'identity diags "\n"))))
        (with-current-buffer (llminate-chat--prompt-buffer)
          (erase-buffer)
          (insert prompt))
        (llminate-chat-send)))))

(defun llminate-mode--collect-diagnostics ()
  "Collect flymake diagnostics for the current buffer as a list of strings."
  (when (and (fboundp 'flymake-diagnostics)
             (bound-and-true-p flymake-mode))
    (let ((diags (flymake-diagnostics)))
      (mapcar (lambda (d)
                (format "  Line %d: [%s] %s"
                        (line-number-at-pos (flymake-diagnostic-beg d))
                        (flymake-diagnostic-type d)
                        (flymake-diagnostic-text d)))
              diags))))

(defun llminate-command-palette ()
  "Show a completing-read palette of all llminate commands."
  (interactive)
  (let* ((commands '(("Start bridge"          . llminate-bridge-start)
                     ("Stop bridge"           . llminate-bridge-stop)
                     ("Restart bridge"        . llminate-bridge-restart)
                     ("Toggle chat"           . llminate-chat-toggle)
                     ("Send prompt"           . llminate-chat-send)
                     ("Toggle layout"         . llminate-layout-toggle)
                     ("Resume session"        . llminate-session-resume)
                     ("List sessions"         . llminate-session-list)
                     ("Save session"          . llminate-session-save)
                     ("Explain region"        . llminate-explain-region)
                     ("Fix region"            . llminate-fix-region)
                     ("Send diagnostics"      . llminate-send-diagnostics)
                     ("Emacs commands list"   . llminate-emacs-commands-list)
                     ("Switch render backend" . llminate-chat-set-render-backend)
                     ("Re-render all responses" . llminate-chat-rerender-all)
                     ("Start completion server" . llminate-completion-start-server)
                     ("Stop completion server"  . llminate-completion-stop-server)))
         (choice (completing-read "llminate: " (mapcar #'car commands) nil t)))
    (when-let* ((cmd (cdr (assoc choice commands))))
      (call-interactively cmd))))

;;;; Keymap

(defvar llminate-mode-map
  (let ((map (make-sparse-keymap))
        (prefix (make-sparse-keymap)))
    (define-key prefix (kbd "q") #'llminate-chat-toggle)
    (define-key prefix (kbd "s") #'llminate-chat-send)
    (define-key prefix (kbd "l") #'llminate-layout-toggle)
    (define-key prefix (kbd "r") #'llminate-session-resume)
    (define-key prefix (kbd "c") #'llminate-command-palette)
    (define-key prefix (kbd "e") #'llminate-explain-region)
    (define-key prefix (kbd "f") #'llminate-fix-region)
    (define-key prefix (kbd "d") #'llminate-send-diagnostics)
    (define-key prefix (kbd ".") #'completion-at-point)
    (define-key prefix (kbd "w") #'llminate-emacs-commands-list)
    (define-key prefix (kbd "m") #'llminate-chat-set-render-backend)
    (define-key map (kbd "C-c q") prefix)
    map)
  "Keymap for `llminate-mode'.  All bindings under C-c q.")

;;;; Minor mode definition

;;;###autoload
(define-minor-mode llminate-mode
  "Global minor mode for the llminate AI coding assistant.

Keybindings (C-c q prefix):
  C-c q q  Toggle chat panel
  C-c q s  Send prompt
  C-c q l  Toggle IDE layout
  C-c q r  Resume session
  C-c q c  Command palette
  C-c q e  Explain region
  C-c q f  Fix / improve region
  C-c q d  Send diagnostics to llminate
  C-c q .  Trigger completion-at-point
  C-c q w  List allowed Emacs commands
  C-c q m  Switch markdown render backend

Modeline indicator shows bridge state:
  llm[idle]  llm[streaming]  llm[tool:Bash]  llm[emacs:magit]  llm[awaiting]"
  :global t
  :lighter llminate-mode--modeline-string
  :keymap llminate-mode-map
  :group 'llminate
  (if llminate-mode
      (progn
        (llminate-mode--register-modeline-hooks)
        (llminate-mode--update-modeline)
        ;; Add CAPF in prog-mode buffers if llminate-completion is loaded
        (when (fboundp 'llminate-completion--setup)
          (add-hook 'prog-mode-hook #'llminate-completion--setup))
        (message "[llminate] Mode enabled — C-c q c for command palette"))
    (llminate-mode--unregister-modeline-hooks)
    (when (fboundp 'llminate-completion--setup)
      (remove-hook 'prog-mode-hook #'llminate-completion--setup))
    (when (llminate-bridge-running-p)
      (llminate-bridge-stop))
    (when (llminate-layout-active-p)
      (llminate-layout-toggle))
    (setq llminate-mode--modeline-string " llm[off]")
    (force-mode-line-update t)
    (message "[llminate] Mode disabled")))

(provide 'llminate-mode)

;;; llminate-mode.el ends here
