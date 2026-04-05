;;; llminate-bridge.el --- Bidirectional process bridge for llminate -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Manages llminate as a long-lived subprocess communicating over
;; JSON-lines (stdin/stdout).  The bridge is bidirectional:
;;
;;   Emacs  -> llminate : user prompts, ToolApprovalResponse, EmacsEvalResult
;;   llminate -> Emacs  : Start, Ready, Message, ToolUse, ToolResult,
;;                        ToolApproval, EmacsEval, Error, End
;;
;; The process runs with:
;;   llminate -p --output-format stream-json --input-format stream-json
;;            --keep-alive --permission-mode ask

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'llminate-emacs-commands)
(require 'llminate-bridge-claude)

;; Declare flymake functions used in --collect-diagnostics.
;; The actual calls are guarded by (fboundp 'flymake-diagnostics).
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-beg "flymake" (diagnostic))
(declare-function flymake-diagnostic-type "flymake" (diagnostic))
(declare-function flymake-diagnostic-text "flymake" (diagnostic))

;; Declare server function used when switching to claude-code backend.
;; Guarded by (require 'server) at runtime.
(declare-function server-running-p "server" (&optional name))

;;;; Customization

(defgroup llminate-bridge nil
  "Process bridge for the llminate agentic coding assistant."
  :group 'llminate
  :prefix "llminate-bridge-")

(defcustom llminate-bridge-backend 'llminate
  "Which AI backend to use.
`llminate'    — the llminate Rust binary (long-lived subprocess)
`claude-code' — the Claude Code CLI via `claude -p' (per-turn processes)"
  :type '(choice (const :tag "llminate (Rust binary)" llminate)
                 (const :tag "Claude Code CLI" claude-code))
  :group 'llminate-bridge)

(defcustom llminate-bridge-executable "llminate"
  "Path to the llminate executable."
  :type 'string
  :group 'llminate-bridge)

(defcustom llminate-bridge-claude-executable "claude"
  "Path to the Claude Code CLI executable."
  :type 'string
  :group 'llminate-bridge)

(defcustom llminate-bridge-model nil
  "Model to pass via --model flag.  nil means use llminate default."
  :type '(choice (const :tag "Default" nil)
                 string)
  :group 'llminate-bridge)

(defcustom llminate-bridge-permission-mode "ask"
  "Permission mode for tool execution.
One of \"ask\", \"allow\", \"deny\"."
  :type '(choice (const "ask")
                 (const "allow")
                 (const "deny"))
  :group 'llminate-bridge)

(defcustom llminate-bridge-extra-args nil
  "Extra command-line arguments passed to llminate."
  :type '(repeat string)
  :group 'llminate-bridge)

(defcustom llminate-bridge-restart-on-crash t
  "Whether to automatically restart llminate if it crashes."
  :type 'boolean
  :group 'llminate-bridge)

(defcustom llminate-bridge-debug-process-output nil
  "When non-nil, write raw subprocess output to the *llminate-process* buffer.
Disabled by default for performance — every process filter call would
do a buffer-switch + insert.  Enable temporarily for debugging."
  :type 'boolean
  :group 'llminate-bridge)

;;;; Hooks

(defvar llminate-bridge-start-hook nil
  "Hook run after the llminate process starts (after Start event).")

(defvar llminate-bridge-ready-hook nil
  "Hook run when llminate emits a Ready event (idle between turns).")

(defvar llminate-bridge-message-hook nil
  "Hook run on each Message event.  Called with (ROLE CONTENT).")

(defvar llminate-bridge-tool-use-hook nil
  "Hook run on ToolUse events.  Called with (NAME INPUT).")

(defvar llminate-bridge-tool-result-hook nil
  "Hook run on ToolResult events.  Called with (OUTPUT).")

(defvar llminate-bridge-tool-approval-hook nil
  "Hook run on ToolApproval events.  Called with the full event plist.")

(defvar llminate-bridge-emacs-eval-hook nil
  "Hook run on EmacsEval events.  Called with (COMMAND ARGS REQUEST-ID).")

(defvar llminate-bridge-error-hook nil
  "Hook run on Error events.  Called with (MESSAGE).")

(defvar llminate-bridge-end-hook nil
  "Hook run on End events.  Called with (REASON).")

(defvar llminate-bridge-session-resume-hook nil
  "Hook run on SessionResume events.  Called with (MESSAGES).
MESSAGES is a list of plists, each with :role, :content, :timestamp.")

;;;; Internal state

(defvar llminate-bridge--process nil
  "The llminate subprocess.")

(defvar llminate-bridge--line-buffer ""
  "Partial line accumulator for the process filter.")

(defvar llminate-bridge--session-id nil
  "Current session ID reported by llminate.")

(defvar llminate-bridge--model-name nil
  "Current model name reported by llminate.")

(defvar llminate-bridge--state 'stopped
  "Current bridge state.
One of: `stopped', `starting', `idle', `streaming',
`tool-executing', `awaiting-approval', `emacs-eval'.")

(defvar llminate-bridge--response-callback nil
  "Callback for the current response.
Called with (TYPE DATA) where TYPE is `message', `end', or `error'.")

(defvar llminate-bridge--accumulated-text ""
  "Text accumulated during the current streaming response.")

(defvar llminate-bridge--prompt-queue nil
  "Queue of prompts waiting to be sent (list of (PROMPT . CALLBACK) conses).")

(defvar llminate-bridge--project-dir nil
  "The project directory for the current llminate session.")

;;;; Process management

(defun llminate-bridge--build-args ()
  "Build the argument list for the llminate subprocess."
  (let ((args (list "-p"
                    "--output-format" "stream-json"
                    "--input-format" "stream-json"
                    "--keep-alive"
                    "--permission-mode" llminate-bridge-permission-mode)))
    (when llminate-bridge-model
      (setq args (append args (list "--model" llminate-bridge-model))))
    (when llminate-bridge-extra-args
      (setq args (append args llminate-bridge-extra-args)))
    args))

(defun llminate-bridge-start (&optional project-dir)
  "Start the AI backend subprocess.
Dispatches to the llminate or Claude Code backend based on
`llminate-bridge-backend'.  Optional PROJECT-DIR sets the working directory."
  (interactive
   (list (read-directory-name "Project directory: " default-directory)))
  (let ((dir (or project-dir
                 llminate-bridge--project-dir
                 (when (fboundp 'project-root)
                   (when-let* ((proj (project-current)))
                     (project-root proj)))
                 default-directory)))
    (pcase llminate-bridge-backend
      ('claude-code
       (when (llminate-bridge-running-p)
         (user-error "Claude Code backend is already running; use `llminate-bridge-stop' first"))
       (llminate-bridge-claude--start dir))
      (_
       (llminate-bridge--start-llminate dir)))))

(defun llminate-bridge--start-llminate (dir)
  "Start the llminate Rust binary as a long-lived subprocess in DIR."
  (when (and llminate-bridge--process
             (process-live-p llminate-bridge--process))
    (user-error "llminate is already running; use `llminate-bridge-stop' first"))
  (let* ((default-directory (expand-file-name dir))
         (args (llminate-bridge--build-args)))
    (setq llminate-bridge--project-dir default-directory)
    (setq llminate-bridge--line-buffer "")
    (setq llminate-bridge--accumulated-text "")
    (setq llminate-bridge--state 'starting)
    (setq llminate-bridge--prompt-queue nil)
    (setq llminate-bridge--process
          (make-process
           :name "llminate"
           :buffer (get-buffer-create " *llminate-process*")
           :command (cons llminate-bridge-executable args)
           :connection-type 'pipe
           :coding 'utf-8
           :noquery t
           :filter #'llminate-bridge--process-filter
           :sentinel #'llminate-bridge--process-sentinel
           :stderr (get-buffer-create " *llminate-stderr*")))
    (message "[llminate] Started (dir: %s)" default-directory)))

(defun llminate-bridge-stop ()
  "Stop the AI backend."
  (interactive)
  (pcase llminate-bridge-backend
    ('claude-code
     (llminate-bridge-claude--stop))
    (_
     (llminate-bridge--stop-llminate))))

(defun llminate-bridge--stop-llminate ()
  "Stop the llminate Rust binary subprocess."
  ;; Set state BEFORE killing — the sentinel fires synchronously on delete-process
  ;; and must see 'stopped to avoid auto-restart.
  (setq llminate-bridge--state 'stopped)
  (when (and llminate-bridge--process
             (process-live-p llminate-bridge--process))
    (delete-process llminate-bridge--process))
  (setq llminate-bridge--process nil)
  (setq llminate-bridge--session-id nil)
  (setq llminate-bridge--line-buffer "")
  (message "[llminate] Stopped"))

(defun llminate-bridge-restart ()
  "Restart the llminate subprocess."
  (interactive)
  (llminate-bridge-stop)
  (sit-for 0.3)
  (llminate-bridge-start llminate-bridge--project-dir))

(defun llminate-bridge-ensure-running ()
  "Start the backend if it is not already running."
  (unless (llminate-bridge-running-p)
    (llminate-bridge-start)))

(defun llminate-bridge-running-p ()
  "Return non-nil if the AI backend is active."
  (pcase llminate-bridge-backend
    ('claude-code
     (llminate-bridge-claude--running-p))
    (_
     (and llminate-bridge--process
          (process-live-p llminate-bridge--process)))))

;;;; Process sentinel (crash handling)

(defun llminate-bridge--process-sentinel (proc event)
  "Handle process state changes for PROC.
EVENT is a string describing the change."
  (let ((status (process-status proc)))
    (unless (eq status 'run)
      (setq llminate-bridge--state 'stopped)
      (setq llminate-bridge--process nil)
      (cond
       ((string-match-p "finished" event)
        (message "[llminate] Process exited normally"))
       ((string-match-p "\\(killed\\|interrupt\\)" event)
        (message "[llminate] Process was killed"))
       (t
        (message "[llminate] Process crashed: %s" (string-trim event))
        ;; Only auto-restart if not intentionally stopped
        (when (and llminate-bridge-restart-on-crash
                   (not (eq llminate-bridge--state 'stopped)))
          (run-with-timer 1.0 nil #'llminate-bridge-start
                          llminate-bridge--project-dir)))))))

;;;; Process filter (JSON-lines parsing & dispatch)

(defun llminate-bridge--process-filter (proc output)
  "Accumulate OUTPUT from PROC and dispatch complete JSON-lines.
Optimized: single-pass newline scan via `string-search', optional
debug buffer (controlled by `llminate-bridge-debug-process-output')."
  ;; Debug: optionally write raw output to the process buffer
  (when llminate-bridge-debug-process-output
    (when-let* ((buf (process-buffer proc)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (goto-char (point-max))
          (insert output)))))
  ;; Accumulate into line buffer
  (setq llminate-bridge--line-buffer
        (concat llminate-bridge--line-buffer output))
  ;; Single-pass scan for newlines — avoids split-string, butlast, (car (last ...))
  (let ((buf llminate-bridge--line-buffer)
        (start 0)
        nl)
    (while (setq nl (string-search "\n" buf start))
      (when (> nl start)                ; skip empty lines
        (llminate-bridge--handle-line (substring buf start nl)))
      (setq start (1+ nl)))
    ;; Keep only the incomplete tail (no allocation if no newline was found)
    (setq llminate-bridge--line-buffer
          (if (= start 0) buf (substring buf start)))))

(defun llminate-bridge--handle-line (line)
  "Parse a single JSON LINE and dispatch to the appropriate handler.
Uses native `json-parse-string' (C implementation, ~5-10x faster
than the elisp `json-read-from-string')."
  (condition-case err
      (let* ((event (json-parse-string line
                                        :object-type 'plist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil))
             (event-type (plist-get event :type)))
        (cond
         ((string= event-type "Start")
          (llminate-bridge--handle-start event))
         ((string= event-type "Ready")
          (llminate-bridge--handle-ready event))
         ((string= event-type "Message")
          (llminate-bridge--handle-message event))
         ((string= event-type "ToolUse")
          (llminate-bridge--handle-tool-use event))
         ((string= event-type "ToolResult")
          (llminate-bridge--handle-tool-result event))
         ((string= event-type "ToolApproval")
          (llminate-bridge--handle-tool-approval event))
         ((string= event-type "EmacsEval")
          (llminate-bridge--handle-emacs-eval event))
         ((string= event-type "Error")
          (llminate-bridge--handle-error event))
         ((string= event-type "End")
          (llminate-bridge--handle-end event))
         ((string= event-type "SessionResume")
          (llminate-bridge--handle-session-resume event))
         (t
          (message "[llminate] Unknown event type: %s" event-type))))
    ((json-parse-error error)
     (message "[llminate] JSON parse error: %s (line: %.80s)"
              (error-message-string err) line))))

;;;; Event handlers

(defun llminate-bridge--handle-start (event)
  "Handle a Start EVENT from llminate."
  (setq llminate-bridge--session-id (plist-get event :session_id))
  (setq llminate-bridge--model-name (plist-get event :model))
  (setq llminate-bridge--state 'idle)
  (run-hooks 'llminate-bridge-start-hook)
  (message "[llminate] Session started (model: %s)"
           (or llminate-bridge--model-name "unknown"))
  ;; Drain queued prompts — a prompt may have been queued while state was 'starting
  (when llminate-bridge--prompt-queue
    (let ((next (pop llminate-bridge--prompt-queue)))
      (llminate-bridge--send-prompt-internal (car next) (cdr next)))))

(defun llminate-bridge--handle-ready (_event)
  "Handle a Ready EVENT -- llminate is idle between turns."
  (setq llminate-bridge--state 'idle)
  (run-hooks 'llminate-bridge-ready-hook)
  ;; Send queued prompts if any
  (when llminate-bridge--prompt-queue
    (let ((next (pop llminate-bridge--prompt-queue)))
      (llminate-bridge--send-prompt-internal (car next) (cdr next)))))

(defun llminate-bridge--handle-message (event)
  "Handle a Message EVENT (streaming text chunk).
Only assistant messages are forwarded to the response callback for
streaming display; user message echoes from the protocol are ignored
since the chat UI already displays them when the prompt is sent."
  (let ((role (plist-get event :role))
        (content (plist-get event :content)))
    (run-hook-with-args 'llminate-bridge-message-hook role content)
    ;; Only process assistant messages for streaming display
    (when (string= role "assistant")
      (setq llminate-bridge--state 'streaming)
      (when content
        (setq llminate-bridge--accumulated-text
              (concat llminate-bridge--accumulated-text content)))
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback 'message content)))))

(defun llminate-bridge--handle-tool-use (event)
  "Handle a ToolUse EVENT."
  (let ((name (plist-get event :name))
        (input (plist-get event :input)))
    (setq llminate-bridge--state 'tool-executing)
    (run-hook-with-args 'llminate-bridge-tool-use-hook name input)
    (when llminate-bridge--response-callback
      (funcall llminate-bridge--response-callback 'tool-use
               (list :name name :input input)))))

(defun llminate-bridge--handle-tool-result (event)
  "Handle a ToolResult EVENT."
  (let ((output (plist-get event :output)))
    (setq llminate-bridge--state 'streaming)
    (run-hook-with-args 'llminate-bridge-tool-result-hook output)
    (when llminate-bridge--response-callback
      (funcall llminate-bridge--response-callback 'tool-result output))))

(defun llminate-bridge--handle-tool-approval (event)
  "Handle a ToolApproval EVENT -- llminate wants permission."
  (setq llminate-bridge--state 'awaiting-approval)
  (run-hook-with-args 'llminate-bridge-tool-approval-hook event)
  (when llminate-bridge--response-callback
    (funcall llminate-bridge--response-callback 'tool-approval event)))

(defun llminate-bridge--handle-emacs-eval (event)
  "Handle an EmacsEval EVENT -- llminate requests Emacs function execution.
Looks up the command in the whitelist, executes if allowed, and
sends the result back via EmacsEvalResult."
  (let ((command (plist-get event :command))
        (args (plist-get event :args))
        (request-id (plist-get event :request_id)))
    (setq llminate-bridge--state 'emacs-eval)
    (run-hook-with-args 'llminate-bridge-emacs-eval-hook command args request-id)
    ;; Delegate to the command security layer
    (llminate-emacs-commands-execute
     command
     (if (and args (listp args)) args nil)
     request-id
     #'llminate-bridge--send-eval-result)))

(defun llminate-bridge--handle-error (event)
  "Handle an Error EVENT."
  (let ((msg (plist-get event :message)))
    (run-hook-with-args 'llminate-bridge-error-hook msg)
    (when llminate-bridge--response-callback
      (funcall llminate-bridge--response-callback 'error msg))
    (message "[llminate] Error: %s" msg)))

(defun llminate-bridge--handle-end (event)
  "Handle an End EVENT -- response is complete."
  (let ((reason (plist-get event :reason))
        (text llminate-bridge--accumulated-text))
    (setq llminate-bridge--state 'idle)
    (run-hook-with-args 'llminate-bridge-end-hook reason)
    (when llminate-bridge--response-callback
      (funcall llminate-bridge--response-callback 'end text))
    (setq llminate-bridge--response-callback nil)
    (setq llminate-bridge--accumulated-text "")))

(defun llminate-bridge--handle-session-resume (event)
  "Handle a SessionResume EVENT -- restore previous conversation.
Populates the chat log with the previous conversation messages
so the user can see the history when resuming a session."
  (let ((messages (plist-get event :messages)))
    (run-hook-with-args 'llminate-bridge-session-resume-hook messages)
    (message "[llminate] Resumed session with %d messages"
             (length messages))))

;;;; Sending data to llminate (stdin)

(defun llminate-bridge--send (plist)
  "Encode PLIST as JSON and write to llminate's stdin with trailing newline."
  (unless (llminate-bridge-running-p)
    (error "[llminate] Process is not running"))
  (let* ((json-encoding-pretty-print nil)
         (json-false :json-false)
         (json-null :null)
         (json-str (json-encode plist)))
    (process-send-string llminate-bridge--process
                         (concat json-str "\n"))))

(defun llminate-bridge--send-eval-result (request-id success result)
  "Send an EmacsEvalResult back to llminate.
REQUEST-ID correlates with the original EmacsEval.
SUCCESS is t or nil.  RESULT is the serialized value or error message."
  (llminate-bridge--send
   (list :type "EmacsEvalResult"
         :request_id request-id
         :success (if success t :json-false)
         :result (or result :null))))

(defun llminate-bridge-send-approval-response (request-id approved)
  "Send a ToolApprovalResponse to llminate.
REQUEST-ID correlates with the ToolApproval event.
APPROVED is t or nil."
  (llminate-bridge--send
   (list :type "ToolApprovalResponse"
         :request_id request-id
         :approved (if approved t :json-false))))

(defun llminate-bridge-send-prompt (prompt &optional callback)
  "Send PROMPT to the AI backend as a user message.
Optional CALLBACK is called with (TYPE DATA) for each event in
the response: `message', `tool-use', `tool-result', `end', `error'.

If the backend is not idle, the prompt is queued."
  (llminate-bridge-ensure-running)
  (if (eq llminate-bridge--state 'idle)
      (llminate-bridge--send-prompt-internal prompt callback)
    ;; Queue the prompt
    (push (cons prompt callback) llminate-bridge--prompt-queue)))

(defun llminate-bridge--send-prompt-internal (prompt callback)
  "Internal: dispatch PROMPT + CALLBACK to the active backend."
  (pcase llminate-bridge-backend
    ('claude-code
     (llminate-bridge-claude--send-prompt prompt callback))
    (_
     (llminate-bridge--send-prompt-llminate prompt callback))))

(defun llminate-bridge--send-prompt-llminate (prompt callback)
  "Send PROMPT to the llminate Rust binary via stdin.  Register CALLBACK."
  (setq llminate-bridge--response-callback callback)
  (setq llminate-bridge--accumulated-text "")
  (setq llminate-bridge--state 'streaming)
  (llminate-bridge--send
   (list :type "Message"
         :role "user"
         :content prompt)))

;;;; Utility accessors

(defun llminate-bridge-state ()
  "Return the current bridge state as a symbol."
  llminate-bridge--state)

(defun llminate-bridge-session-id ()
  "Return the current session ID, or nil."
  llminate-bridge--session-id)

(defun llminate-bridge-model ()
  "Return the model name reported by llminate, or nil."
  llminate-bridge--model-name)

;;;; Backend switching

(defun llminate-bridge-switch-backend (backend)
  "Switch the AI backend to BACKEND.
Stops the current backend if running, switches, and restarts.
BACKEND is a symbol: `llminate' or `claude-code'."
  (interactive
   (let* ((other (if (eq llminate-bridge-backend 'claude-code) "llminate" "claude-code"))
          (current (symbol-name llminate-bridge-backend))
          (choice (completing-read
                   (format "Switch backend (current: %s): " current)
                   '("llminate" "claude-code") nil t nil nil other)))
     (list (intern choice))))
  (cl-block llminate-bridge-switch-backend
    (when (eq backend llminate-bridge-backend)
      (message "[llminate] Already using %s backend" backend)
      (cl-return-from llminate-bridge-switch-backend))
    (let ((was-running (llminate-bridge-running-p))
          (dir llminate-bridge--project-dir))
      (when was-running
        (llminate-bridge-stop)
        (sit-for 0.3))
      (setq llminate-bridge-backend backend)
      ;; Ensure Emacs server is running for the Claude Code backend
      (when (eq backend 'claude-code)
        (require 'server)
        (unless (server-running-p)
          (server-start)
          (message "[llminate] Started Emacs server for emacsclient access")))
      (when was-running
        (llminate-bridge-start dir))
      (message "[llminate] Switched to %s backend" backend))))

;;;; Phase 5: Deep Editor Context Integration

(defun llminate-bridge--collect-editor-context ()
  "Collect rich context from the current Emacs state.
Returns a JSON-compatible alist with keys:
  current_file, cursor_line, cursor_column, visible_range,
  selection, language, diagnostics, git_status, git_branch,
  project_root, open_files, available_emacs_commands,
  active_modes, eglot_active."
  (let* ((file (buffer-file-name))
         (line (line-number-at-pos (point) t))
         (col (current-column))
         ;; Visible range
         (win (selected-window))
         (vis-start (when win (line-number-at-pos (window-start win) t)))
         (vis-end (when win (line-number-at-pos (window-end win t) t)))
         ;; Selection
         (selection (when (use-region-p)
                      (buffer-substring-no-properties
                       (region-beginning) (region-end))))
         ;; Language
         (language (symbol-name major-mode))
         ;; Diagnostics (flymake/eglot)
         (diagnostics (llminate-bridge--collect-diagnostics))
         ;; Git status (magit)
         (git-status (llminate-bridge--git-status))
         (git-branch (llminate-bridge--git-branch))
         ;; Project
         (proj-root (when (fboundp 'project-root)
                      (when-let* ((proj (project-current)))
                        (project-root proj))))
         ;; Open files
         (open-files (cl-remove-if
                      #'null
                      (mapcar #'buffer-file-name (buffer-list))))
         ;; Available Emacs commands
         (emacs-cmds (when (boundp 'llminate-emacs-commands--registry)
                       (mapcar #'car llminate-emacs-commands--registry)))
         ;; Active minor modes
         (active-modes (cl-remove-if-not
                        (lambda (m)
                          (and (boundp m) (symbol-value m)))
                        minor-mode-list))
         (active-mode-names (mapcar #'symbol-name
                                    (cl-subseq active-modes
                                               0 (min 30 (length active-modes)))))
         ;; Eglot active
         (eglot-active (and (fboundp 'eglot-managed-p) (eglot-managed-p))))
    `((current_file . ,(or file ""))
      (cursor_line . ,line)
      (cursor_column . ,col)
      (visible_range . ((start . ,(or vis-start 1))
                        (end . ,(or vis-end 1))))
      ,@(when selection `((selection . ,selection)))
      (language . ,language)
      (diagnostics . ,(or diagnostics []))
      (git_status . ,(or git-status ""))
      (git_branch . ,(or git-branch ""))
      (project_root . ,(or proj-root ""))
      (open_files . ,(vconcat (cl-subseq open-files
                                         0 (min 20 (length open-files)))))
      (available_emacs_commands . ,(vconcat emacs-cmds))
      (active_modes . ,(vconcat active-mode-names))
      (eglot_active . ,(if eglot-active t :json-false)))))

(defun llminate-bridge--collect-diagnostics ()
  "Collect flymake/eglot diagnostics as a vector of alists."
  (when (and (fboundp 'flymake-diagnostics)
             (bound-and-true-p flymake-mode))
    (let ((diags (flymake-diagnostics)))
      (vconcat
       (mapcar (lambda (d)
                 `((line . ,(line-number-at-pos (flymake-diagnostic-beg d)))
                   (type . ,(symbol-name (flymake-diagnostic-type d)))
                   (message . ,(flymake-diagnostic-text d))))
               (cl-subseq diags 0 (min 20 (length diags))))))))

(defun llminate-bridge--git-status ()
  "Return short git status via magit if available, else shell."
  (cond
   ((fboundp 'magit-git-string)
    (condition-case nil
        (magit-git-string "status" "--porcelain" "--short")
      (error nil)))
   (t
    (condition-case nil
        (string-trim
         (shell-command-to-string "git status --porcelain --short 2>/dev/null | head -20"))
      (error nil)))))

(defun llminate-bridge--git-branch ()
  "Return the current git branch."
  (cond
   ((fboundp 'magit-get-current-branch)
    (condition-case nil
        (magit-get-current-branch)
      (error nil)))
   (t
    (condition-case nil
        (string-trim
         (shell-command-to-string "git rev-parse --abbrev-ref HEAD 2>/dev/null"))
      (error nil)))))

(defun llminate-bridge--context-system-prompt ()
  "Generate a system prompt addendum describing the Emacs environment.
Tells the AI about EmacsCommand availability and current editor state."
  (let* ((ctx (llminate-bridge--collect-editor-context))
         (json-encoding-pretty-print nil)
         (ctx-json (json-encode ctx))
         (cmds (alist-get 'available_emacs_commands ctx)))
    (format "You are running inside Emacs. You have access to the EmacsCommand tool \
which lets you call Emacs functions directly. Available commands: %s.
Current editor state: %s
Use EmacsCommand for git operations (via magit), LSP operations (via eglot), \
buffer navigation, and window management instead of shelling out when possible."
            (mapconcat #'identity (append cmds nil) ", ")
            ctx-json)))

(defun llminate-bridge--emacsclient-instructions ()
  "Build instructions telling the AI how to use emacsclient for Emacs commands.
Used when the Claude Code backend is active, since it cannot use EmacsCommand
directly.  The AI calls Emacs via its Bash tool + emacsclient -e.
Resolves the full emacsclient path and server socket at build time
so the subprocess does not depend on PATH or socket discovery."
  (let* ((cmds (when (boundp 'llminate-emacs-commands--registry)
                 (mapcar #'car llminate-emacs-commands--registry)))
         ;; Resolve full emacsclient path
         (ec-path (or (executable-find "emacsclient") "emacsclient"))
         ;; Resolve server name for -s flag
         (sock-name (or (bound-and-true-p server-name) "server"))
         ;; Build the base command with resolved paths
         (ec-cmd (format "%s -s %s -e" ec-path sock-name)))
    (format "\
# IMPORTANT: Emacs IDE Integration

You are operating as an assistant inside the user's Emacs IDE.  The user \
sees your actions reflected in their editor.  You MUST prefer using Emacs \
commands via emacsclient for any operation that has an Emacs equivalent, \
so the user sees the result in their editor.

## How to call Emacs commands

Use your Bash tool with the EXACT command prefix below (path and socket \
are pre-resolved):

  %s '(llminate-emacs-commands-cli-dispatch \"COMMAND\" ARGS...)'

Return value is JSON:
  {\"success\": true, \"result\": ...}   on success
  {\"success\": false, \"error\": \"...\"}  on denial or failure

If a command is denied or fails, fall back to your standard tools \
(Bash, Read, Write, etc.).  Do NOT skip emacsclient preemptively.

## When to use emacsclient (PREFERRED)

ALWAYS prefer emacsclient for these — your standard tools are the FALLBACK:

- **Opening/navigating files**: Use `find-file` so the file opens in the \
user's editor, not just read silently.  Fall back to Read only for \
programmatic inspection where the user doesn't need to see the buffer.
- **Git operations**: Use magit commands so results appear in the user's \
magit interface.  For file-specific commands (magit-diff-buffer-file, \
magit-stage-file), first call find-file to open the file, then call \
the magit command with NO arguments (it operates on the current buffer). \
Fall back to raw git commands only if the magit equivalent fails.
- **Code navigation**: Use xref-find-definitions, xref-find-references, \
eglot-find-declaration, eglot-find-implementation to jump the user's \
cursor to the right location.
- **Diagnostics**: Use flymake-diagnostics to get errors from the user's \
live session (includes unsaved changes and LSP analysis).
- **Compilation**: Use compile or recompile to trigger builds in the \
user's compilation buffer.  Fall back to Bash only if denied.
- **Queries about editor state**: Use point, line-number-at-pos, \
buffer-modified-p, default-directory, buffer-file-name, buffer-list, \
project-root to understand what the user is looking at right now.
- **Window management**: Use split-window-right, split-window-below, \
delete-other-windows, balance-windows when arranging the user's layout.

## When to use your standard tools directly

- **Read/Write/Edit**: For programmatic file modifications (the user \
asked you to edit code, not just view it)
- **Grep/Glob**: For searching across many files
- **Bash**: For shell commands with no Emacs equivalent, or as fallback \
when an emacsclient command is denied

## Whitelisted commands

File/buffer: find-file, find-file-other-window, switch-to-buffer, \
save-buffer, revert-buffer, buffer-string, buffer-file-name, \
buffer-list, goto-line, goto-char

Git (magit): magit-status, magit-stage-file, magit-unstage-file, \
magit-commit*, magit-push*, magit-pull, magit-log-current, \
magit-diff-buffer-file (diff for current file), \
magit-diff-unstaged (all unstaged changes), \
magit-diff-staged (all staged changes), \
magit-get-current-branch, magit-git-string, magit-stash*

LSP (eglot): eglot-rename*, eglot-code-actions, eglot-find-declaration, \
eglot-find-implementation, xref-find-definitions, xref-find-references, \
flymake-diagnostics, eglot-format-buffer*

Compilation: compile*, recompile, next-error, previous-error

Project: project-root, project-files, project-find-file

Window: split-window-right, split-window-below, delete-window, \
delete-other-windows, balance-windows

Queries: point, line-number-at-pos, current-column, buffer-modified-p, \
default-directory, mark, region-beginning, region-end

(* = requires user approval before executing)

## Examples

  %s '(llminate-emacs-commands-cli-dispatch \"find-file\" \"/path/to/file.rs\")'
  %s '(llminate-emacs-commands-cli-dispatch \"magit-status\")'
  %s '(llminate-emacs-commands-cli-dispatch \"goto-line\" 42)'
  %s '(llminate-emacs-commands-cli-dispatch \"magit-get-current-branch\")'
  %s '(llminate-emacs-commands-cli-dispatch \"xref-find-definitions\" \"my_function\")'
  %s '(llminate-emacs-commands-cli-dispatch \"recompile\")'
  %s '(llminate-emacs-commands-cli-dispatch \"flymake-diagnostics\")'
  %s '(llminate-emacs-commands-cli-dispatch \"project-root\")'

Full command list: %s"
            ec-cmd
            ec-cmd ec-cmd ec-cmd ec-cmd ec-cmd ec-cmd ec-cmd ec-cmd
            (mapconcat #'identity cmds ", "))))

(defun llminate-bridge-send-prompt-with-context (prompt &optional callback)
  "Send PROMPT to the backend with editor context prepended.
For the llminate backend, prepends editor state JSON.
For the Claude Code backend, also includes emacsclient instructions
so the AI knows how to call Emacs functions via Bash.
Optional CALLBACK is forwarded to `llminate-bridge-send-prompt'."
  (let* ((ctx (llminate-bridge--collect-editor-context))
         (json-encoding-pretty-print nil)
         (ctx-str (json-encode ctx))
         (emacsclient-section
          (when (eq llminate-bridge-backend 'claude-code)
            (llminate-bridge--emacsclient-instructions)))
         (enriched (if emacsclient-section
                       (format "%s\n\n[Editor Context]\n%s\n\n[User Prompt]\n%s"
                               emacsclient-section ctx-str prompt)
                     (format "[Editor Context]\n%s\n\n[User Prompt]\n%s"
                             ctx-str prompt))))
    (llminate-bridge-send-prompt enriched callback)))

(provide 'llminate-bridge)

;;; llminate-bridge.el ends here
