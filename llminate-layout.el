;;; llminate-layout.el --- IDE window layout for llminate -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Multi-panel IDE layout combining treemacs, main editor, chat log,
;; activity log, and prompt input.  Save/restore via window-configuration
;; register (pattern from ai-layout.el).

;;; Code:

(require 'cl-lib)
(require 'llminate-bridge)
(require 'llminate-chat)

;;;; Customization

(defgroup llminate-layout nil
  "IDE window layout for the llminate coding assistant."
  :group 'llminate
  :prefix "llminate-layout-")

(defcustom llminate-layout-chat-width 0.35
  "Width of the chat side-window as a fraction of the frame."
  :type 'number
  :group 'llminate-layout)

(defcustom llminate-layout-activity-height 8
  "Height (in lines) of the activity log window."
  :type 'integer
  :group 'llminate-layout)

(defcustom llminate-layout-prompt-height 5
  "Height (in lines) of the prompt input window."
  :type 'integer
  :group 'llminate-layout)

;;;; Internal state

(defvar llminate-layout--active-p nil
  "Whether the llminate IDE layout is currently active.")

(defvar llminate-layout--saved-register ?L
  "Register character used to save/restore the window configuration.")

;;;; Activity buffer

(defvar llminate-layout--activity-max-entries 500
  "Maximum number of entries before the oldest are pruned.")

(defun llminate-layout--activity-buffer ()
  "Get or create the *llminate Activity* buffer."
  (let ((buf (get-buffer-create "*llminate Activity*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'llminate-activity-mode)
        (llminate-activity-mode)))
    buf))

(define-derived-mode llminate-activity-mode special-mode "llminate Activity"
  "Read-only buffer displaying llminate tool executions and events.
\\{llminate-activity-mode-map}"
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t))

(defun llminate-layout-log-activity (category text)
  "Append a timestamped entry to the activity buffer.
CATEGORY is a short label (e.g. \"Tool\", \"Emacs\", \"Approval\").
TEXT is the entry body."
  (let ((buf (llminate-layout--activity-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (at-end (eobp))
            (ts (format-time-string "%H:%M:%S"))
            (win (get-buffer-window buf)))
        (save-excursion
          (goto-char (point-max))
          (insert (propertize (format "[%s] " ts)
                              'face 'shadow)
                  (propertize (format "%-10s" category)
                              'face 'bold)
                  " "
                  (if (> (length text) 200)
                      (concat (substring text 0 197) "...")
                    text)
                  "\n"))
        ;; Auto-scroll
        (when (and win at-end)
          (with-selected-window win
            (goto-char (point-max))
            (recenter -1)))
        ;; Prune old entries
        (when (> (count-lines (point-min) (point-max))
                 llminate-layout--activity-max-entries)
          (save-excursion
            (goto-char (point-min))
            (forward-line 50)
            (delete-region (point-min) (point))))))))

;;;; Activity hook handlers

(defun llminate-layout--on-tool-use (name input)
  "Log a ToolUse event.  NAME is the tool, INPUT is its arguments."
  (let ((args-str (if input
                      (let ((json-encoding-pretty-print nil))
                        (json-encode input))
                    "")))
    (llminate-layout-log-activity "Tool" (format "%s %s" name args-str))))

(defun llminate-layout--on-tool-result (output)
  "Log a ToolResult event.  OUTPUT is the result."
  (let ((out-str (if (stringp output) output
                   (let ((json-encoding-pretty-print nil))
                     (json-encode output)))))
    (llminate-layout-log-activity "Result" out-str)))

(defun llminate-layout--on-emacs-eval (command args _request-id)
  "Log an EmacsEval event.  COMMAND and ARGS describe the call."
  (llminate-layout-log-activity
   "Emacs"
   (format "%s%s" command (if args (format " %S" args) ""))))

(defun llminate-layout--on-error (msg)
  "Log an Error event.  MSG is the error message."
  (llminate-layout-log-activity "Error" msg))

(defun llminate-layout--on-tool-approval (event)
  "Log a ToolApproval event.  EVENT is the full plist."
  (let ((tool (plist-get event :tool_name))
        (desc (plist-get event :description)))
    (llminate-layout-log-activity
     "Approval"
     (format "Awaiting: %s — %s" tool (or desc "")))))

;;;; Conversation event handlers

(defun llminate-layout--on-start ()
  "Log a session Start event."
  (llminate-layout-log-activity
   "Session"
   (format "Started (model: %s)"
           (or (llminate-bridge-model) "unknown"))))

(defun llminate-layout--on-ready ()
  "Log a Ready event (idle between turns)."
  (llminate-layout-log-activity "Session" "Ready — awaiting input"))

(defun llminate-layout--on-message (role content)
  "Log a Message event.  ROLE is \"user\" or \"assistant\", CONTENT is the text."
  (cond
   ((string= role "user")
    (llminate-layout-log-activity
     "User"
     (or content "(empty)")))
   ((string= role "assistant")
    ;; Only log the first chunk to avoid flooding the activity buffer
    ;; with hundreds of per-token entries.
    )))

(defun llminate-layout--on-end (reason)
  "Log an End event.  REASON describes why the turn ended."
  (llminate-layout-log-activity
   "End"
   (format "Turn complete%s"
           (if reason (format " (%s)" reason) ""))))

;;;; Register hooks

(defun llminate-layout--register-hooks ()
  "Register activity-log hooks on the bridge."
  (add-hook 'llminate-bridge-start-hook          #'llminate-layout--on-start)
  (add-hook 'llminate-bridge-ready-hook          #'llminate-layout--on-ready)
  (add-hook 'llminate-bridge-message-hook        #'llminate-layout--on-message)
  (add-hook 'llminate-bridge-end-hook            #'llminate-layout--on-end)
  (add-hook 'llminate-bridge-tool-use-hook       #'llminate-layout--on-tool-use)
  (add-hook 'llminate-bridge-tool-result-hook    #'llminate-layout--on-tool-result)
  (add-hook 'llminate-bridge-emacs-eval-hook     #'llminate-layout--on-emacs-eval)
  (add-hook 'llminate-bridge-error-hook          #'llminate-layout--on-error)
  (add-hook 'llminate-bridge-tool-approval-hook  #'llminate-layout--on-tool-approval))

(defun llminate-layout--unregister-hooks ()
  "Remove activity-log hooks."
  (remove-hook 'llminate-bridge-start-hook          #'llminate-layout--on-start)
  (remove-hook 'llminate-bridge-ready-hook          #'llminate-layout--on-ready)
  (remove-hook 'llminate-bridge-message-hook        #'llminate-layout--on-message)
  (remove-hook 'llminate-bridge-end-hook            #'llminate-layout--on-end)
  (remove-hook 'llminate-bridge-tool-use-hook       #'llminate-layout--on-tool-use)
  (remove-hook 'llminate-bridge-tool-result-hook    #'llminate-layout--on-tool-result)
  (remove-hook 'llminate-bridge-emacs-eval-hook     #'llminate-layout--on-emacs-eval)
  (remove-hook 'llminate-bridge-error-hook          #'llminate-layout--on-error)
  (remove-hook 'llminate-bridge-tool-approval-hook  #'llminate-layout--on-tool-approval))

;;;; Layout creation

(defun llminate-layout--create ()
  "Build the IDE layout using side windows.

Layout:
  +----------+------------------+-----------+
  | treemacs |  main editor     |  chat log |
  | (left)   |                  |  (right)  |
  +----------+--------+---------+-----------+
  | activity log      | prompt input        |
  +-------------------+---------------------+"
  ;; Chat log — right side
  (display-buffer-in-side-window
   (llminate-chat--log-buffer)
   `((side . right)
     (window-width . ,llminate-layout-chat-width)
     (slot . 0)
     (window-parameters . ((no-delete-other-windows . t)))))
  ;; Activity log — bottom left
  (display-buffer-in-side-window
   (llminate-layout--activity-buffer)
   `((side . bottom)
     (window-height . ,llminate-layout-activity-height)
     (slot . 0)
     (window-parameters . ((no-delete-other-windows . t)))))
  ;; Prompt input — bottom right
  (display-buffer-in-side-window
   (llminate-chat--prompt-buffer)
   `((side . bottom)
     (window-height . ,llminate-layout-prompt-height)
     (slot . 1)
     (window-parameters . ((no-delete-other-windows . t)))))
  ;; Treemacs on the left (if available)
  (when (fboundp 'treemacs-get-local-window)
    (unless (treemacs-get-local-window)
      (when (fboundp 'treemacs)
        (save-selected-window
          (treemacs))))))

(defun llminate-layout--teardown ()
  "Remove all llminate side windows."
  (dolist (name '("*llminate Chat*"
                  "*llminate Prompt*"
                  "*llminate Activity*"))
    (when-let* ((win (get-buffer-window name)))
      (delete-window win))))

;;;; Toggle

;;;###autoload
(defun llminate-layout-toggle ()
  "Toggle the llminate IDE layout on or off.
Saves the current window configuration to a register before
activating, and restores it when deactivating."
  (interactive)
  (if llminate-layout--active-p
      (progn
        (llminate-layout--teardown)
        (llminate-layout--unregister-hooks)
        (jump-to-register llminate-layout--saved-register)
        (setq llminate-layout--active-p nil)
        (message "[llminate] Layout disabled"))
    ;; Save current config and build the layout
    (window-configuration-to-register llminate-layout--saved-register)
    (llminate-layout--create)
    (llminate-layout--register-hooks)
    (setq llminate-layout--active-p t)
    (message "[llminate] Layout enabled")))

(defun llminate-layout-active-p ()
  "Return non-nil if the llminate layout is active."
  llminate-layout--active-p)

;; Re-register hooks on reload if the layout is already active,
;; so that reloading this file picks up new/changed handlers.
(when llminate-layout--active-p
  (llminate-layout--unregister-hooks)
  (llminate-layout--register-hooks))

(provide 'llminate-layout)

;;; llminate-layout.el ends here
