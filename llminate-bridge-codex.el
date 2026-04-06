;;; llminate-bridge-codex.el --- Codex CLI (OpenAI) backend adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Protocol adapter for using OpenAI's Codex CLI (`codex exec --json`)
;; as the backend instead of the llminate Rust binary.
;;
;; Key differences from the Claude Code adapter:
;;   - One process per turn (not a long-lived subprocess)
;;   - Multi-turn via `codex exec resume SESSION_ID`
;;   - Prompt delivered via stdin (pipe and EOF)
;;   - NDJSON stream via `codex exec --json`
;;   - Text arrives all at once in `item.completed` (no streaming deltas)
;;   - Tool use uses `item.started`/`item.completed` lifecycle
;;   - Session ID (from thread.started event) for resume
;;   - Tool approval not available (tools execute autonomously)
;;   - EmacsEval not supported
;;
;; NDJSON event types (from codex-rs/exec/src/exec_events.rs):
;;   thread.started     -> Store thread_id, fire start-hook
;;   turn.started       -> Set state to streaming
;;   item.completed     -> agent_message: message-hook (full text)
;;                      -> command_execution: tool-result-hook
;;                      -> file_change: synthetic tool-use + tool-result
;;   item.started       -> command_execution: tool-use-hook
;;   turn.completed     -> end-hook, ready-hook, drain queue
;;   turn.failed        -> error-hook
;;   error              -> error-hook
;;
;; This module translates Codex CLI's NDJSON stream into the same
;; hooks used by `llminate-bridge.el' so all downstream modules
;; (chat, layout, approval, session) work unchanged.

;;; Code:

(require 'json)
(require 'cl-lib)

;; Forward declarations -- these are defined in llminate-bridge.el and
;; accessed at runtime after it loads us.
(defvar llminate-bridge-model)
(defvar llminate-bridge-extra-args)
(defvar llminate-bridge--state)
(defvar llminate-bridge--session-id)
(defvar llminate-bridge--model-name)
(defvar llminate-bridge--accumulated-text)
(defvar llminate-bridge--response-callback)
(defvar llminate-bridge--prompt-queue)
(defvar llminate-bridge--project-dir)
(defvar llminate-bridge-debug-process-output)

(declare-function llminate-bridge-register-backend "llminate-bridge")
(declare-function llminate-bridge--emacsclient-instructions "llminate-bridge")

;;;; Customization

(defcustom llminate-bridge-codex-executable "codex"
  "Path to the Codex CLI executable."
  :type 'string
  :group 'llminate-bridge)

(defcustom llminate-bridge-codex-sandbox "read-only"
  "Sandbox policy for Codex CLI shell command execution.
Set to \"danger-full-access\" if you need emacsclient to reach
the Emacs server socket (outside the workspace).

Possible values:
  \"read-only\"           - Default.  No writes allowed.
  \"workspace-write\"     - Writes inside the project only.
  \"danger-full-access\"  - No restrictions.  Required for emacsclient."
  :type '(choice (const :tag "Read-only (default)" "read-only")
                 (const :tag "Workspace write" "workspace-write")
                 (const :tag "Full access (needed for emacsclient)" "danger-full-access"))
  :group 'llminate-bridge)

;;;; Internal state

(defvar llminate-bridge-codex--process nil
  "The current per-turn Codex CLI subprocess.")

(defvar llminate-bridge-codex--session-id nil
  "Session ID persisted across turns for `codex exec resume SESSION_ID'.
Extracted from the `thread_id' field in the `thread.started' event.")

(defvar llminate-bridge-codex--line-buffer ""
  "Partial NDJSON line accumulator for the process filter.")

;;;; Process argument construction

(defun llminate-bridge-codex--build-args ()
  "Build the argument list for a Codex CLI subprocess.
The prompt is not included -- it is piped via stdin.
Resume uses `codex exec --json resume SESSION_ID' subcommand."
  (let ((args (list "exec" "--json"
                     "--sandbox" llminate-bridge-codex-sandbox)))
    ;; Model (must come before the resume subcommand)
    (when llminate-bridge-model
      (setq args (append args (list "--model" llminate-bridge-model))))
    ;; Extra args
    (when llminate-bridge-extra-args
      (setq args (append args llminate-bridge-extra-args)))
    ;; Resume previous session if we have one
    (when llminate-bridge-codex--session-id
      (setq args (append args (list "resume" llminate-bridge-codex--session-id))))
    args))

;;;; Process lifecycle

(defun llminate-bridge-codex--start (dir)
  "Initialize the Codex CLI backend for project DIR.
Does not spawn a process -- processes are per-turn."
  (setq llminate-bridge--project-dir (expand-file-name dir))
  (setq llminate-bridge-codex--line-buffer "")
  (setq llminate-bridge--accumulated-text "")
  (setq llminate-bridge--state 'idle)
  (setq llminate-bridge--prompt-queue nil)
  ;; Fire start and ready hooks immediately -- no process to wait for
  (run-hooks 'llminate-bridge-start-hook)
  (run-hooks 'llminate-bridge-ready-hook)
  (message "[codex] Backend ready (dir: %s)" dir)
  ;; Drain any queued prompts
  (when llminate-bridge--prompt-queue
    (let ((next (pop llminate-bridge--prompt-queue)))
      (llminate-bridge-codex--send-prompt (car next) (cdr next)))))

(defun llminate-bridge-codex--stop ()
  "Stop the Codex CLI backend.  Kill any running process."
  (setq llminate-bridge--state 'stopped)
  (when (and llminate-bridge-codex--process
             (process-live-p llminate-bridge-codex--process))
    (delete-process llminate-bridge-codex--process))
  (setq llminate-bridge-codex--process nil)
  ;; Preserve thread-id so it can be used on next start
  (setq llminate-bridge-codex--line-buffer "")
  (message "[codex] Stopped"))

(defun llminate-bridge-codex--running-p ()
  "Return non-nil if the Codex CLI backend is active.
The backend is \"running\" when state is not `stopped', even if
no per-turn process is currently alive."
  (not (eq llminate-bridge--state 'stopped)))

;;;; Sending prompts (spawns a per-turn process)

(defun llminate-bridge-codex--send-prompt (prompt callback)
  "Spawn a Codex CLI process for PROMPT.  Register CALLBACK.
If a process is still running, queue the prompt.
The prompt is piped via stdin then EOF is sent."
  (cl-block llminate-bridge-codex--send-prompt
    ;; If a turn is still in progress, queue and bail
    (when (and llminate-bridge-codex--process
               (process-live-p llminate-bridge-codex--process))
      (push (cons prompt callback) llminate-bridge--prompt-queue)
      (cl-return-from llminate-bridge-codex--send-prompt))
    ;; Set up state
    (setq llminate-bridge--response-callback callback)
    (setq llminate-bridge--accumulated-text "")
    (setq llminate-bridge--state 'streaming)
    (setq llminate-bridge-codex--line-buffer "")
    ;; Build process
    (let* ((default-directory (or llminate-bridge--project-dir default-directory))
           (args (llminate-bridge-codex--build-args)))
      (setq llminate-bridge-codex--process
            (make-process
             :name "codex-cli"
             :buffer (get-buffer-create " *codex-cli-process*")
             :command (cons llminate-bridge-codex-executable args)
             :connection-type 'pipe
             :coding 'utf-8
             :noquery t
             :filter #'llminate-bridge-codex--process-filter
             :sentinel #'llminate-bridge-codex--process-sentinel))
      ;; Pipe the prompt to stdin then close it
      (process-send-string llminate-bridge-codex--process prompt)
      (process-send-string llminate-bridge-codex--process "\n")
      (process-send-eof llminate-bridge-codex--process))))

;;;; Process filter (NDJSON parsing)

(defun llminate-bridge-codex--process-filter (proc output)
  "Accumulate OUTPUT from PROC and dispatch complete NDJSON lines."
  ;; Debug: optionally write raw output
  (when llminate-bridge-debug-process-output
    (when-let* ((buf (process-buffer proc)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (goto-char (point-max))
          (insert output)))))
  ;; Accumulate
  (setq llminate-bridge-codex--line-buffer
        (concat llminate-bridge-codex--line-buffer output))
  ;; Scan for complete lines
  (let ((buf llminate-bridge-codex--line-buffer)
        (start 0)
        nl)
    (while (setq nl (string-search "\n" buf start))
      (when (> nl start)
        (llminate-bridge-codex--handle-line (substring buf start nl)))
      (setq start (1+ nl)))
    (setq llminate-bridge-codex--line-buffer
          (if (= start 0) buf (substring buf start)))))

(defun llminate-bridge-codex--handle-line (line)
  "Parse a single NDJSON LINE and dispatch to the appropriate handler.
Non-JSON lines (e.g. Rust tracing output) are silently skipped."
  ;; Skip blank lines and lines that don't start with '{' -- these are
  ;; Rust tracing/debug log lines, not NDJSON events.
  (let ((trimmed (string-trim-left line)))
    (unless (or (string-empty-p trimmed)
                (not (eq (aref trimmed 0) ?{)))
      (condition-case err
          (let* ((event (json-parse-string trimmed
                                           :object-type 'plist
                                           :array-type 'list
                                           :null-object nil
                                           :false-object nil))
                 (event-type (plist-get event :type)))
            (cond
             ((string= event-type "thread.started")
              (llminate-bridge-codex--handle-thread-started event))
             ((string= event-type "turn.started")
              (llminate-bridge-codex--handle-turn-started event))
             ((string= event-type "item.started")
              (llminate-bridge-codex--handle-item-started event))
             ((string= event-type "item.completed")
              (llminate-bridge-codex--handle-item-completed event))
             ((string= event-type "turn.completed")
              (llminate-bridge-codex--handle-turn-completed event))
             ((string= event-type "turn.failed")
              (llminate-bridge-codex--handle-turn-failed event))
             ((string= event-type "error")
              (llminate-bridge-codex--handle-error event))
             ;; Log unhandled types for debugging
             (t
              (when llminate-bridge-debug-process-output
                (message "[codex] Unhandled event type: %s" event-type)))))
        ((json-parse-error error)
         (when llminate-bridge-debug-process-output
           (message "[codex] JSON parse error: %s (line: %.80s)"
                    (error-message-string err) trimmed)))))))

;;;; Event handlers

(defun llminate-bridge-codex--handle-thread-started (event)
  "Handle a `thread.started' EVENT from Codex CLI.
Extracts thread_id and stores it for multi-turn continuation.
Fires `llminate-bridge-start-hook'."
  (let ((thread-id (plist-get event :thread_id)))
    (when thread-id
      (setq llminate-bridge-codex--session-id thread-id)
      ;; Map thread-id to session-id for bridge compatibility
      (setq llminate-bridge--session-id thread-id))
    (run-hooks 'llminate-bridge-start-hook)
    (message "[codex] Thread started: %s" (or thread-id "?"))))

(defun llminate-bridge-codex--handle-turn-started (_event)
  "Handle a `turn.started' EVENT from Codex CLI.
Sets state to streaming to indicate the model is generating a response."
  (setq llminate-bridge--state 'streaming))

(defun llminate-bridge-codex--handle-item-started (event)
  "Handle an `item.started' EVENT from Codex CLI.
For command_execution items, fires `llminate-bridge-tool-use-hook'
with the command information."
  (let* ((item (plist-get event :item))
         (item-type (when item (plist-get item :type))))
    (when (and item-type (string= item-type "command_execution"))
      (setq llminate-bridge--state 'tool-executing)
      ;; Extract command info for the tool-use hook
      ;; Codex provides the command in item.call_id or item.command
      (let ((call-id (plist-get item :call_id))
            (command (plist-get item :command)))
        ;; Fire tool-use hook with available command info
        ;; Use command if available, otherwise call_id as the tool name
        (let ((tool-name (or command call-id "command_execution"))
              (tool-input (when command (list :command command))))
          (run-hook-with-args 'llminate-bridge-tool-use-hook
                              tool-name tool-input)
          (when llminate-bridge--response-callback
            (funcall llminate-bridge--response-callback
                     'tool-use (list :name tool-name :input tool-input))))))))

(defun llminate-bridge-codex--handle-item-completed (event)
  "Handle an `item.completed' EVENT from Codex CLI.
Dispatches based on the nested item type:
  - agent_message: fire message-hook with full text
  - command_execution: fire tool-result-hook with output
  - file_change: fire synthetic tool-use + tool-result with file paths"
  (let* ((item (plist-get event :item))
         (item-type (when item (plist-get item :type))))
    (cond
     ;; Agent message -- text arrives all at once (not streamed)
     ((and item-type (string= item-type "agent_message"))
      (llminate-bridge-codex--handle-agent-message item))
     ;; Command execution completed -- has aggregated output
     ((and item-type (string= item-type "command_execution"))
      (llminate-bridge-codex--handle-command-execution-completed item))
     ;; File change -- synthetic tool-use + tool-result
     ((and item-type (string= item-type "file_change"))
      (llminate-bridge-codex--handle-file-change item))
     ;; Unknown item type
     (t
      (when llminate-bridge-debug-process-output
        (message "[codex] Unhandled item.completed type: %s" item-type))))))

(defun llminate-bridge-codex--handle-agent-message (item)
  "Handle an agent_message ITEM from Codex CLI.
The text is in item.text (a plain string).
Text arrives all at once, not streamed."
  (let ((text (plist-get item :text)))
    (when (and text (stringp text) (not (string-empty-p text)))
      ;; Accumulate
      (setq llminate-bridge--accumulated-text
            (concat llminate-bridge--accumulated-text text))
      (setq llminate-bridge--state 'streaming)
      ;; Fire message hook
      (run-hook-with-args 'llminate-bridge-message-hook "assistant" text)
      ;; Fire callback
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback 'message text)))))

(defun llminate-bridge-codex--handle-command-execution-completed (item)
  "Handle a completed command_execution ITEM from Codex CLI.
Fires `llminate-bridge-tool-result-hook' with the aggregated output."
  (let ((output (plist-get item :aggregated_output))
        (call-id (plist-get item :call_id))
        (command (plist-get item :command))
        (exit-code (plist-get item :exit_code)))
    ;; Build the result text from available fields
    (let ((result-text (cond
                         ;; Use aggregated_output if available
                         ((and output (stringp output) (not (string-empty-p output)))
                          output)
                         ;; Synthesize from exit code and command
                         ((and exit-code command)
                          (format "(command %s exited with code %s)"
                                  command exit-code))
                         ((and exit-code call-id)
                          (format "(command %s exited with code %s)"
                                  call-id exit-code))
                         (t "(tool executed by Codex CLI)"))))
      (setq llminate-bridge--state 'streaming)
      (run-hook-with-args 'llminate-bridge-tool-result-hook result-text)
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback 'tool-result result-text)))))

(defun llminate-bridge-codex--handle-file-change (item)
  "Handle a file_change ITEM from Codex CLI.
Fires a synthetic `llminate-bridge-tool-use-hook' followed by
`llminate-bridge-tool-result-hook' with the changed file paths."
  (let ((file-path (plist-get item :file_path))
        (change-type (plist-get item :change_type))
        (additions (plist-get item :additions))
        (deletions (plist-get item :deletions)))
    ;; Fire synthetic tool-use hook for the file change
    (let ((tool-name "file_change")
          (tool-input (list :file_path (or file-path "unknown")
                            :change_type (or change-type "modified"))))
      (setq llminate-bridge--state 'tool-executing)
      (run-hook-with-args 'llminate-bridge-tool-use-hook tool-name tool-input)
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback
                 'tool-use (list :name tool-name :input tool-input))))
    ;; Fire synthetic tool-result with the change summary
    (let ((result-text (format "%s: %s%s"
                               (or change-type "modified")
                               (or file-path "unknown file")
                               (if (or additions deletions)
                                   (format " (+%s/-%s)"
                                           (or additions 0)
                                           (or deletions 0))
                                 ""))))
      (setq llminate-bridge--state 'streaming)
      (run-hook-with-args 'llminate-bridge-tool-result-hook result-text)
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback 'tool-result result-text)))))

(defun llminate-bridge-codex--handle-turn-completed (_event)
  "Handle a `turn.completed' EVENT from Codex CLI.
Fires end-hook, transitions to idle, fires ready-hook, and drains
the prompt queue."
  (let ((text llminate-bridge--accumulated-text))
    ;; End hook
    (run-hook-with-args 'llminate-bridge-end-hook "complete")
    (when llminate-bridge--response-callback
      (funcall llminate-bridge--response-callback 'end text))
    (setq llminate-bridge--response-callback nil)
    (setq llminate-bridge--accumulated-text "")
    (setq llminate-bridge--state 'idle)
    ;; Ready hook -- idle between turns
    (run-hooks 'llminate-bridge-ready-hook)
    ;; Drain queued prompts
    (when llminate-bridge--prompt-queue
      (let ((next (pop llminate-bridge--prompt-queue)))
        (llminate-bridge-codex--send-prompt (car next) (cdr next))))))

(defun llminate-bridge-codex--handle-turn-failed (event)
  "Handle a `turn.failed' EVENT from Codex CLI.
Fires error-hook with the error message, then transitions to idle."
  (let ((error-msg (or (plist-get event :message)
                       (plist-get event :error)
                       "Turn failed (unknown reason)")))
    ;; Extract message from plist if error is an object
    (when (and (listp error-msg) (plist-get error-msg :message))
      (setq error-msg (plist-get error-msg :message)))
    (let ((msg (if (stringp error-msg) error-msg
                 (format "%s" error-msg))))
      (run-hook-with-args 'llminate-bridge-error-hook msg)
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback 'error msg))
      (setq llminate-bridge--response-callback nil)
      (setq llminate-bridge--accumulated-text "")
      (setq llminate-bridge--state 'idle)
      (run-hooks 'llminate-bridge-ready-hook)
      ;; Drain queue
      (when llminate-bridge--prompt-queue
        (let ((next (pop llminate-bridge--prompt-queue)))
          (llminate-bridge-codex--send-prompt (car next) (cdr next)))))))

(defun llminate-bridge-codex--handle-error (event)
  "Handle a top-level `error' EVENT from Codex CLI.
Fires error-hook with the error message."
  (let ((msg (or (plist-get event :message)
                 (plist-get event :error)
                 "Unknown error")))
    ;; Extract message from plist if error is an object
    (when (and (listp msg) (plist-get msg :message))
      (setq msg (plist-get msg :message)))
    (let ((error-text (if (stringp msg) msg (format "%s" msg))))
      (run-hook-with-args 'llminate-bridge-error-hook error-text)
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback 'error error-text))
      (message "[codex] Error: %s" error-text))))

;;;; Process sentinel

(defun llminate-bridge-codex--process-sentinel (proc event)
  "Handle process state changes for PROC (Codex CLI per-turn process).
EVENT describes the change.  On unexpected exit during streaming,
fire error + ready hooks."
  (let ((status (process-status proc)))
    (unless (eq status 'run)
      (setq llminate-bridge-codex--process nil)
      ;; If we were still streaming, this is an unexpected exit
      (when (memq llminate-bridge--state '(streaming tool-executing))
        (let ((msg (format "Codex CLI process exited unexpectedly: %s"
                           (string-trim event))))
          (run-hook-with-args 'llminate-bridge-error-hook msg)
          (when llminate-bridge--response-callback
            (funcall llminate-bridge--response-callback 'error msg))
          (setq llminate-bridge--response-callback nil)
          (setq llminate-bridge--accumulated-text "")
          (setq llminate-bridge--state 'idle)
          (run-hooks 'llminate-bridge-ready-hook)
          ;; Drain queue
          (when llminate-bridge--prompt-queue
            (let ((next (pop llminate-bridge--prompt-queue)))
              (llminate-bridge-codex--send-prompt
               (car next) (cdr next)))))))))

;;;; Setup (runs when backend is activated)

(defun llminate-bridge-codex--setup ()
  "Prompt the user to choose a sandbox level for Codex CLI.
Only `danger-full-access' allows emacsclient to reach the Emacs
server socket (which lives outside the workspace)."
  (let ((choice (completing-read
                 "Codex sandbox policy (full-access needed for Emacs commands): "
                 '("read-only" "workspace-write" "danger-full-access")
                 nil t nil nil llminate-bridge-codex-sandbox)))
    (setq llminate-bridge-codex-sandbox choice)
    (message "[codex] Sandbox policy: %s" choice)
    ;; Start Emacs server if full-access chosen (emacsclient needs it)
    (when (string= choice "danger-full-access")
      (unless (and (fboundp 'server-running-p) (server-running-p))
        (server-start)
        (message "[codex] Emacs server started for emacsclient access")))))

;;;; Resume

(defun llminate-bridge-codex--resume (session-id dir)
  "Resume a Codex session identified by SESSION-ID in DIR.
Sets the session ID so that `build-args' emits `resume SESSION-ID',
then starts the backend."
  (setq llminate-bridge-codex--session-id session-id)
  (llminate-bridge-codex--start dir))

;;;; Self-registration

(llminate-bridge-register-backend
 '(:name           codex-cli
   :label          "Codex CLI (OpenAI)"
   :prefix         "cx"
   :start-fn       llminate-bridge-codex--start
   :stop-fn        llminate-bridge-codex--stop
   :running-p-fn   llminate-bridge-codex--running-p
   :send-prompt-fn llminate-bridge-codex--send-prompt
   :enrich-fn      llminate-bridge--emacsclient-instructions
   :setup-fn       llminate-bridge-codex--setup
   :resume-fn      llminate-bridge-codex--resume))

(provide 'llminate-bridge-codex)

;;; llminate-bridge-codex.el ends here
