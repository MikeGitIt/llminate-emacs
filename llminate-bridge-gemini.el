;;; llminate-bridge-gemini.el --- Gemini CLI backend adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Protocol adapter for using Google's Gemini CLI (`gemini -p`) as the
;; backend instead of the llminate Rust binary.
;;
;; Key differences from the llminate backend:
;;   - One process per turn (not a long-lived subprocess)
;;   - Multi-turn via `--resume SESSION_ID`
;;   - Prompt delivered as `-p "prompt"` CLI argument (not stdin)
;;   - NDJSON stream via `--output-format stream-json`
;;   - Tool approval not available (tools execute autonomously)
;;   - EmacsEval not supported
;;
;; NDJSON event types from Gemini CLI:
;;   init       -> Store session ID/model, fire start-hook
;;   message    -> Streaming text (delta) or full text
;;   tool_use   -> Tool invocation
;;   tool_result -> Tool execution result
;;   error      -> Error with severity/message
;;   result     -> Turn complete (success or error)
;;
;; This module translates Gemini CLI's NDJSON stream into the same
;; hooks used by `llminate-bridge.el' so all downstream modules
;; (chat, layout, approval, session) work unchanged.

;;; Code:

(require 'json)
(require 'cl-lib)

;; Forward declarations -- these are defined in llminate-bridge.el and
;; accessed at runtime after it loads us.
(defvar llminate-bridge-model)
(defvar llminate-bridge-permission-mode)
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

(defcustom llminate-bridge-gemini-executable "gemini"
  "Path to the Gemini CLI executable."
  :type 'string
  :group 'llminate-bridge)

;;;; Internal state

(defvar llminate-bridge-gemini--process nil
  "The current per-turn Gemini CLI subprocess.")

(defvar llminate-bridge-gemini--session-id nil
  "Session ID persisted across turns for `--resume'.")

(defvar llminate-bridge-gemini--line-buffer ""
  "Partial NDJSON line accumulator for the process filter.")

;;;; Process argument construction

(defun llminate-bridge-gemini--build-args (prompt)
  "Build the argument list for a Gemini CLI subprocess.
PROMPT is passed via the `-p' flag as a CLI argument."
  (let ((args (list "-p" prompt
                    "--output-format" "stream-json")))
    ;; Resume previous session if we have one
    (when llminate-bridge-gemini--session-id
      (setq args (append args (list "--resume" llminate-bridge-gemini--session-id))))
    ;; Model
    (when llminate-bridge-model
      (setq args (append args (list "--model" llminate-bridge-model))))
    ;; Extra args
    (when llminate-bridge-extra-args
      (setq args (append args llminate-bridge-extra-args)))
    args))

;;;; Process lifecycle

(defun llminate-bridge-gemini--start (dir)
  "Initialize the Gemini CLI backend for project DIR.
Does not spawn a process -- processes are per-turn."
  (setq llminate-bridge--project-dir (expand-file-name dir))
  (setq llminate-bridge-gemini--line-buffer "")
  (setq llminate-bridge--accumulated-text "")
  (setq llminate-bridge--state 'idle)
  (setq llminate-bridge--prompt-queue nil)
  ;; Fire start and ready hooks immediately -- no process to wait for
  (run-hooks 'llminate-bridge-start-hook)
  (run-hooks 'llminate-bridge-ready-hook)
  (message "[gemini] Backend ready (dir: %s)" dir)
  ;; Drain any queued prompts
  (when llminate-bridge--prompt-queue
    (let ((next (pop llminate-bridge--prompt-queue)))
      (llminate-bridge-gemini--send-prompt (car next) (cdr next)))))

(defun llminate-bridge-gemini--stop ()
  "Stop the Gemini CLI backend.  Kill any running process."
  (setq llminate-bridge--state 'stopped)
  (when (and llminate-bridge-gemini--process
             (process-live-p llminate-bridge-gemini--process))
    (delete-process llminate-bridge-gemini--process))
  (setq llminate-bridge-gemini--process nil)
  ;; Preserve session-id so it can be used on next start
  (setq llminate-bridge-gemini--line-buffer "")
  (message "[gemini] Stopped"))

(defun llminate-bridge-gemini--running-p ()
  "Return non-nil if the Gemini CLI backend is active.
The backend is \"running\" when state is not `stopped', even if
no per-turn process is currently alive."
  (not (eq llminate-bridge--state 'stopped)))

;;;; Sending prompts (spawns a per-turn process)

(defun llminate-bridge-gemini--send-prompt (prompt callback)
  "Spawn a Gemini CLI process for PROMPT.  Register CALLBACK.
If a process is still running, queue the prompt.
The prompt is passed as a CLI argument to `-p', not via stdin."
  (cl-block llminate-bridge-gemini--send-prompt
    ;; If a turn is still in progress, queue and bail
    (when (and llminate-bridge-gemini--process
               (process-live-p llminate-bridge-gemini--process))
      (push (cons prompt callback) llminate-bridge--prompt-queue)
      (cl-return-from llminate-bridge-gemini--send-prompt))
    ;; Set up state
    (setq llminate-bridge--response-callback callback)
    (setq llminate-bridge--accumulated-text "")
    (setq llminate-bridge--state 'streaming)
    (setq llminate-bridge-gemini--line-buffer "")
    ;; Build process
    (let* ((default-directory (or llminate-bridge--project-dir default-directory))
           (args (llminate-bridge-gemini--build-args prompt)))
      (setq llminate-bridge-gemini--process
            (make-process
             :name "gemini-cli"
             :buffer (get-buffer-create " *gemini-cli-process*")
             :command (cons llminate-bridge-gemini-executable args)
             :connection-type 'pipe
             :coding 'utf-8
             :noquery t
             :filter #'llminate-bridge-gemini--process-filter
             :sentinel #'llminate-bridge-gemini--process-sentinel)))))

;;;; Process filter (NDJSON parsing)

(defun llminate-bridge-gemini--process-filter (proc output)
  "Accumulate OUTPUT from PROC and dispatch complete NDJSON lines."
  ;; Debug: optionally write raw output
  (when llminate-bridge-debug-process-output
    (when-let* ((buf (process-buffer proc)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (goto-char (point-max))
          (insert output)))))
  ;; Accumulate
  (setq llminate-bridge-gemini--line-buffer
        (concat llminate-bridge-gemini--line-buffer output))
  ;; Scan for complete lines
  (let ((buf llminate-bridge-gemini--line-buffer)
        (start 0)
        nl)
    (while (setq nl (string-search "\n" buf start))
      (when (> nl start)
        (llminate-bridge-gemini--handle-line (substring buf start nl)))
      (setq start (1+ nl)))
    (setq llminate-bridge-gemini--line-buffer
          (if (= start 0) buf (substring buf start)))))

(defun llminate-bridge-gemini--handle-line (line)
  "Parse a single NDJSON LINE and dispatch to the appropriate handler."
  (condition-case err
      (let* ((event (json-parse-string line
                                        :object-type 'plist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil))
             (event-type (plist-get event :type)))
        (cond
         ((string= event-type "init")
          (llminate-bridge-gemini--handle-init event))
         ((string= event-type "message")
          (llminate-bridge-gemini--handle-message event))
         ((string= event-type "tool_use")
          (llminate-bridge-gemini--handle-tool-use event))
         ((string= event-type "tool_result")
          (llminate-bridge-gemini--handle-tool-result event))
         ((string= event-type "error")
          (llminate-bridge-gemini--handle-error event))
         ((string= event-type "result")
          (llminate-bridge-gemini--handle-result event))
         ;; Log unhandled types for debugging
         (t
          (when llminate-bridge-debug-process-output
            (message "[gemini] Unhandled event type: %s" event-type)))))
    ((json-parse-error error)
     (message "[gemini] JSON parse error: %s (line: %.80s)"
              (error-message-string err) line))))

;;;; Event handlers

(defun llminate-bridge-gemini--handle-init (event)
  "Handle an `init' EVENT from Gemini CLI.
Extracts session_id and model, stores them, and fires start-hook."
  (let ((session-id (plist-get event :session_id))
        (model (plist-get event :model)))
    (when session-id
      (setq llminate-bridge-gemini--session-id session-id)
      (setq llminate-bridge--session-id session-id))
    (when model
      (setq llminate-bridge--model-name model))
    (run-hooks 'llminate-bridge-start-hook)
    (message "[gemini] Session: %s (model: %s)"
             (or session-id "?") (or model "?"))))

(defun llminate-bridge-gemini--handle-message (event)
  "Handle a `message' EVENT from Gemini CLI.
Two modes:
  - delta=true: streaming text chunk (incremental)
  - no delta: complete message text"
  (let ((role (plist-get event :role))
        (content (plist-get event :content))
        (delta (plist-get event :delta)))
    (when (and (stringp role) (string= role "assistant"))
      (when (and content (stringp content) (not (string-empty-p content)))
        ;; Accumulate text
        (setq llminate-bridge--accumulated-text
              (concat llminate-bridge--accumulated-text content))
        (setq llminate-bridge--state 'streaming)
        ;; Fire message hook
        (run-hook-with-args 'llminate-bridge-message-hook "assistant" content)
        ;; Fire callback
        (when llminate-bridge--response-callback
          (funcall llminate-bridge--response-callback 'message content))))))

(defun llminate-bridge-gemini--handle-tool-use (event)
  "Handle a `tool_use' EVENT from Gemini CLI.
Fires tool-use-hook with the tool name and parameters."
  (let ((name (plist-get event :tool_name))
        (input (plist-get event :parameters)))
    (setq llminate-bridge--state 'tool-executing)
    ;; Fire tool-use hook
    (run-hook-with-args 'llminate-bridge-tool-use-hook name input)
    (when llminate-bridge--response-callback
      (funcall llminate-bridge--response-callback
               'tool-use (list :name name :input input)))))

(defun llminate-bridge-gemini--handle-tool-result (event)
  "Handle a `tool_result' EVENT from Gemini CLI.
Fires tool-result-hook with the output."
  (let ((output (plist-get event :output))
        (status (plist-get event :status)))
    (setq llminate-bridge--state 'streaming)
    ;; Use output directly; if absent, synthesize from status
    (let ((result-text (cond
                        ((and output (stringp output)) output)
                        ((and status (stringp status))
                         (format "(tool %s)" status))
                        (t "(tool executed by Gemini CLI)"))))
      (run-hook-with-args 'llminate-bridge-tool-result-hook result-text)
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback 'tool-result result-text)))))

(defun llminate-bridge-gemini--handle-error (event)
  "Handle an `error' EVENT from Gemini CLI.
Fires error-hook with the error message."
  (let ((msg (plist-get event :message))
        (severity (plist-get event :severity)))
    (let ((error-text (if (and severity (stringp severity))
                          (format "[%s] %s" severity (or msg "Unknown error"))
                        (or msg "Unknown error"))))
      (run-hook-with-args 'llminate-bridge-error-hook error-text)
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback 'error error-text))
      (message "[gemini] Error: %s" error-text))))

(defun llminate-bridge-gemini--handle-result (event)
  "Handle a `result' EVENT from Gemini CLI -- turn is complete.
Dispatches based on status field: \"success\" or \"error\"."
  (let ((status (plist-get event :status))
        (session-id (plist-get event :session_id))
        (text llminate-bridge--accumulated-text))
    ;; Capture session-id if provided in the result
    (when session-id
      (setq llminate-bridge-gemini--session-id session-id)
      (setq llminate-bridge--session-id session-id))
    (cond
     ((and (stringp status) (string= status "success"))
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
          (llminate-bridge-gemini--send-prompt (car next) (cdr next)))))
     ((and (stringp status) (string= status "error"))
      (let ((error-msg (or (plist-get event :error)
                           (plist-get event :message)
                           "Unknown error")))
        ;; When error is a plist (object), extract the message
        (when (and (listp error-msg) (plist-get error-msg :message))
          (setq error-msg (plist-get error-msg :message)))
        (run-hook-with-args 'llminate-bridge-error-hook
                            (if (stringp error-msg) error-msg
                              (format "%s" error-msg)))
        (when llminate-bridge--response-callback
          (funcall llminate-bridge--response-callback 'error
                   (if (stringp error-msg) error-msg
                     (format "%s" error-msg))))
        (setq llminate-bridge--response-callback nil)
        (setq llminate-bridge--accumulated-text "")
        (setq llminate-bridge--state 'idle)
        (run-hooks 'llminate-bridge-ready-hook)
        ;; Drain queue
        (when llminate-bridge--prompt-queue
          (let ((next (pop llminate-bridge--prompt-queue)))
            (llminate-bridge-gemini--send-prompt (car next) (cdr next))))))
     ;; Unknown status -- treat as error
     (t
      (let ((msg (format "Unexpected result status: %s" status)))
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
            (llminate-bridge-gemini--send-prompt (car next) (cdr next)))))))))

;;;; Process sentinel

(defun llminate-bridge-gemini--process-sentinel (proc event)
  "Handle process state changes for PROC (Gemini CLI per-turn process).
EVENT describes the change.  On unexpected exit during streaming,
fire error + ready hooks."
  (let ((status (process-status proc)))
    (unless (eq status 'run)
      (setq llminate-bridge-gemini--process nil)
      ;; If we were still streaming, this is an unexpected exit
      (when (memq llminate-bridge--state '(streaming tool-executing))
        (let ((msg (format "Gemini CLI process exited unexpectedly: %s"
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
              (llminate-bridge-gemini--send-prompt
               (car next) (cdr next)))))))))

;;;; Self-registration

(llminate-bridge-register-backend
 '(:name           gemini-cli
   :label          "Gemini CLI (Google)"
   :prefix         "gm"
   :start-fn       llminate-bridge-gemini--start
   :stop-fn        llminate-bridge-gemini--stop
   :running-p-fn   llminate-bridge-gemini--running-p
   :send-prompt-fn llminate-bridge-gemini--send-prompt
   :enrich-fn      llminate-bridge--emacsclient-instructions))

(provide 'llminate-bridge-gemini)

;;; llminate-bridge-gemini.el ends here
