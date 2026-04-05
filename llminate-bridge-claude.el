;;; llminate-bridge-claude.el --- Claude Code CLI backend adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Protocol adapter for using Claude Code CLI (`claude -p`) as the
;; backend instead of the llminate Rust binary.
;;
;; Key differences from the llminate backend:
;;   - One process per turn (not a long-lived subprocess)
;;   - Multi-turn via `--resume SESSION_ID`
;;   - Nested stream_event envelope around Anthropic API events
;;   - Tool approval not available (tools execute autonomously)
;;   - EmacsEval not supported
;;
;; This module translates Claude Code's NDJSON stream into the same
;; hooks used by `llminate-bridge.el' so all downstream modules
;; (chat, layout, approval, session) work unchanged.

;;; Code:

(require 'json)
(require 'cl-lib)

;; Forward declarations — these are defined in llminate-bridge.el and
;; accessed at runtime after it loads us.
(defvar llminate-bridge-claude-executable)  ; defcustom in llminate-bridge.el
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

(declare-function llminate-bridge-state "llminate-bridge")

;;;; Internal state

(defvar llminate-bridge-claude--process nil
  "The current per-turn Claude Code subprocess.")

(defvar llminate-bridge-claude--session-id nil
  "Session ID persisted across turns for `--resume'.")

(defvar llminate-bridge-claude--line-buffer ""
  "Partial NDJSON line accumulator for the process filter.")

(defvar llminate-bridge-claude--content-blocks (make-vector 0 nil)
  "Vector tracking content block state during a response.
Each entry is a plist with :type (\"text\" or \"tool_use\"),
:text or :input-json (accumulated strings), and tool metadata
\(:name, :id) for tool_use blocks.")

;;;; Permission mode mapping

(defun llminate-bridge-claude--map-permission-mode (mode)
  "Map llminate permission MODE to Claude Code equivalent.
\"ask\" -> \"default\", \"allow\" -> \"bypassPermissions\",
\"deny\" -> \"plan\"."
  (pcase mode
    ("ask"   "default")
    ("allow" "bypassPermissions")
    ("deny"  "plan")
    (_       mode)))

;;;; Process argument construction

(defun llminate-bridge-claude--build-args ()
  "Build the argument list for a Claude Code subprocess.
The prompt is not included — it is piped via stdin."
  (let ((args (list "-p"
                    "--output-format" "stream-json"
                    "--verbose")))
    ;; Pre-approve emacsclient so Claude Code's permission system
    ;; doesn't block Emacs IDE integration commands
    (setq args (append args (list "--allowedTools" "Bash(*emacsclient*)")))
    ;; Resume previous session if we have one
    (when llminate-bridge-claude--session-id
      (setq args (append args (list "--resume" llminate-bridge-claude--session-id))))
    ;; Model
    (when llminate-bridge-model
      (setq args (append args (list "--model" llminate-bridge-model))))
    ;; Permission mode (mapped)
    (when llminate-bridge-permission-mode
      (let ((mapped (llminate-bridge-claude--map-permission-mode
                     llminate-bridge-permission-mode)))
        (setq args (append args (list "--permission-mode" mapped)))))
    ;; Extra args
    (when llminate-bridge-extra-args
      (setq args (append args llminate-bridge-extra-args)))
    args))

;;;; Process lifecycle

(defun llminate-bridge-claude--start (dir)
  "Initialize the Claude Code backend for project DIR.
Does not spawn a process — processes are per-turn."
  (setq llminate-bridge--project-dir (expand-file-name dir))
  (setq llminate-bridge-claude--line-buffer "")
  (setq llminate-bridge-claude--content-blocks (make-vector 0 nil))
  (setq llminate-bridge--accumulated-text "")
  (setq llminate-bridge--state 'idle)
  (setq llminate-bridge--prompt-queue nil)
  ;; Fire start and ready hooks immediately — no process to wait for
  (run-hooks 'llminate-bridge-start-hook)
  (run-hooks 'llminate-bridge-ready-hook)
  (message "[claude-code] Backend ready (dir: %s)" dir)
  ;; Drain any queued prompts
  (when llminate-bridge--prompt-queue
    (let ((next (pop llminate-bridge--prompt-queue)))
      (llminate-bridge-claude--send-prompt (car next) (cdr next)))))

(defun llminate-bridge-claude--stop ()
  "Stop the Claude Code backend.  Kill any running process."
  (setq llminate-bridge--state 'stopped)
  (when (and llminate-bridge-claude--process
             (process-live-p llminate-bridge-claude--process))
    (delete-process llminate-bridge-claude--process))
  (setq llminate-bridge-claude--process nil)
  ;; Preserve session-id so it can be used on next start
  (setq llminate-bridge-claude--line-buffer "")
  (setq llminate-bridge-claude--content-blocks (make-vector 0 nil))
  (message "[claude-code] Stopped"))

(defun llminate-bridge-claude--running-p ()
  "Return non-nil if the Claude Code backend is active.
The backend is \"running\" when state is not `stopped', even if
no per-turn process is currently alive."
  (not (eq llminate-bridge--state 'stopped)))

;;;; Sending prompts (spawns a per-turn process)

(defun llminate-bridge-claude--send-prompt (prompt callback)
  "Spawn a Claude Code process for PROMPT.  Register CALLBACK.
If a process is still running, queue the prompt."
  (cl-block llminate-bridge-claude--send-prompt
    ;; If a turn is still in progress, queue and bail
    (when (and llminate-bridge-claude--process
               (process-live-p llminate-bridge-claude--process))
      (push (cons prompt callback) llminate-bridge--prompt-queue)
      (cl-return-from llminate-bridge-claude--send-prompt))
    ;; Set up state
    (setq llminate-bridge--response-callback callback)
    (setq llminate-bridge--accumulated-text "")
    (setq llminate-bridge--state 'streaming)
    (setq llminate-bridge-claude--line-buffer "")
    (setq llminate-bridge-claude--content-blocks (make-vector 0 nil))
    ;; Build process environment — strip CLAUDE_CODE vars to avoid
    ;; nested-instance detection
    (let* ((default-directory (or llminate-bridge--project-dir default-directory))
           (process-environment
            (cl-remove-if (lambda (e)
                            (string-prefix-p "CLAUDECODE" e))
                          process-environment))
           (args (llminate-bridge-claude--build-args)))
      (setq llminate-bridge-claude--process
            (make-process
             :name "claude-code"
             :buffer (get-buffer-create " *claude-code-process*")
             :command (cons llminate-bridge-claude-executable args)
             :connection-type 'pipe
             :coding 'utf-8
             :noquery t
             :filter #'llminate-bridge-claude--process-filter
             :sentinel #'llminate-bridge-claude--process-sentinel))
      ;; Pipe the prompt to stdin then close it
      (process-send-string llminate-bridge-claude--process prompt)
      (process-send-string llminate-bridge-claude--process "\n")
      (process-send-eof llminate-bridge-claude--process))))

;;;; Process filter (NDJSON parsing)

(defun llminate-bridge-claude--process-filter (proc output)
  "Accumulate OUTPUT from PROC and dispatch complete NDJSON lines."
  ;; Debug: optionally write raw output
  (when llminate-bridge-debug-process-output
    (when-let* ((buf (process-buffer proc)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (goto-char (point-max))
          (insert output)))))
  ;; Accumulate
  (setq llminate-bridge-claude--line-buffer
        (concat llminate-bridge-claude--line-buffer output))
  ;; Scan for complete lines
  (let ((buf llminate-bridge-claude--line-buffer)
        (start 0)
        nl)
    (while (setq nl (string-search "\n" buf start))
      (when (> nl start)
        (llminate-bridge-claude--handle-line (substring buf start nl)))
      (setq start (1+ nl)))
    (setq llminate-bridge-claude--line-buffer
          (if (= start 0) buf (substring buf start)))))

(defun llminate-bridge-claude--handle-line (line)
  "Parse a single NDJSON LINE and dispatch to the appropriate handler."
  (condition-case err
      (let* ((event (json-parse-string line
                                        :object-type 'plist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil))
             (event-type (plist-get event :type)))
        (cond
         ((string= event-type "system")
          (llminate-bridge-claude--handle-system event))
         ((string= event-type "assistant")
          (llminate-bridge-claude--handle-assistant event))
         ((string= event-type "content_block_start")
          (llminate-bridge-claude--handle-content-block-start event))
         ((string= event-type "content_block_delta")
          (llminate-bridge-claude--handle-content-block-delta event))
         ((string= event-type "content_block_stop")
          (llminate-bridge-claude--handle-content-block-stop event))
         ((string= event-type "result")
          (llminate-bridge-claude--handle-result event))
         ;; Claude Code may wrap streaming events in a stream_event envelope
         ((string= event-type "stream_event")
          (llminate-bridge-claude--unwrap-stream-event event))
         ;; Log unhandled types for debugging
         (t
          (when llminate-bridge-debug-process-output
            (message "[claude-code] Unhandled event type: %s" event-type)))))
    ((json-parse-error error)
     (message "[claude-code] JSON parse error: %s (line: %.80s)"
              (error-message-string err) line))))

;;;; Stream event unwrapping

(defun llminate-bridge-claude--unwrap-stream-event (event)
  "Unwrap a `stream_event' EVENT envelope and dispatch the inner event.
Claude Code may wrap content_block_* events inside:
  {\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",...}}"
  (let* ((inner (plist-get event :event))
         (inner-type (when inner (plist-get inner :type))))
    (when inner-type
      (cond
       ((string= inner-type "content_block_start")
        (llminate-bridge-claude--handle-content-block-start inner))
       ((string= inner-type "content_block_delta")
        (llminate-bridge-claude--handle-content-block-delta inner))
       ((string= inner-type "content_block_stop")
        (llminate-bridge-claude--handle-content-block-stop inner))
       ((string= inner-type "message_start") nil)
       ((string= inner-type "message_delta") nil)
       ((string= inner-type "message_stop") nil)
       (t
        (when llminate-bridge-debug-process-output
          (message "[claude-code] Unhandled stream_event inner type: %s"
                   inner-type)))))))

;;;; Event handlers

(defun llminate-bridge-claude--handle-system (event)
  "Handle a `system' EVENT from Claude Code.
Extracts session-id and model from init subtype."
  (let ((subtype (plist-get event :subtype)))
    (when (string= subtype "init")
      (let ((session-id (plist-get event :session_id))
            (model (plist-get event :model)))
        (when session-id
          (setq llminate-bridge-claude--session-id session-id)
          (setq llminate-bridge--session-id session-id))
        (when model
          (setq llminate-bridge--model-name model))
        (message "[claude-code] Session: %s (model: %s)"
                 (or session-id "?") (or model "?"))))))

(defun llminate-bridge-claude--handle-assistant (event)
  "Handle an `assistant' EVENT.
In print mode (`-p'), Claude Code returns the full response here
rather than streaming via content_block_* events.  Extract
message.content blocks and fire the appropriate hooks."
  (let* ((message (plist-get event :message))
         (content (when message (plist-get message :content))))
    (when (listp content)
      (dolist (block content)
        (let ((block-type (plist-get block :type)))
          (cond
           ((string= block-type "text")
            (let ((text (plist-get block :text)))
              (when (and text (not (string-empty-p text)))
                ;; Accumulate
                (setq llminate-bridge--accumulated-text
                      (concat llminate-bridge--accumulated-text text))
                (setq llminate-bridge--state 'streaming)
                ;; Fire message hook and callback
                (run-hook-with-args 'llminate-bridge-message-hook
                                    "assistant" text)
                (when llminate-bridge--response-callback
                  (funcall llminate-bridge--response-callback
                           'message text)))))
           ((string= block-type "tool_use")
            (let ((name (plist-get block :name))
                  (id (plist-get block :id))
                  (input (plist-get block :input)))
              (setq llminate-bridge--state 'tool-executing)
              ;; Fire tool-use hook
              (run-hook-with-args 'llminate-bridge-tool-use-hook name input)
              (when llminate-bridge--response-callback
                (funcall llminate-bridge--response-callback
                         'tool-use (list :name name :id id :input input)))
              ;; Synthetic tool-result (Claude Code executes internally)
              (run-hook-with-args 'llminate-bridge-tool-result-hook
                                  "(tool executed by Claude Code)")
              (when llminate-bridge--response-callback
                (funcall llminate-bridge--response-callback
                         'tool-result "(tool executed by Claude Code)"))))
           (t nil)))))))

(defun llminate-bridge-claude--handle-content-block-start (event)
  "Handle a `content_block_start' EVENT.
Initialize tracking for a new content block (text or tool_use)."
  (let* ((index (plist-get event :index))
         (block (plist-get event :content_block))
         (block-type (plist-get block :type))
         ;; Grow the content-blocks vector if needed
         (needed (1+ (or index 0)))
         (current-len (length llminate-bridge-claude--content-blocks)))
    (when (> needed current-len)
      (setq llminate-bridge-claude--content-blocks
            (vconcat llminate-bridge-claude--content-blocks
                     (make-vector (- needed current-len) nil))))
    (cond
     ((string= block-type "text")
      (aset llminate-bridge-claude--content-blocks index
            (list :type "text" :text "")))
     ((string= block-type "tool_use")
      (let ((tool-name (plist-get block :name))
            (tool-id (plist-get block :id)))
        (setq llminate-bridge--state 'tool-executing)
        (aset llminate-bridge-claude--content-blocks index
              (list :type "tool_use"
                    :name tool-name
                    :id tool-id
                    :input-json "")))))))

(defun llminate-bridge-claude--handle-content-block-delta (event)
  "Handle a `content_block_delta' EVENT.
Accumulate text or tool input JSON."
  (let* ((index (plist-get event :index))
         (delta (plist-get event :delta))
         (delta-type (plist-get delta :type))
         (block (when (and index
                           (< index (length llminate-bridge-claude--content-blocks)))
                  (aref llminate-bridge-claude--content-blocks index))))
    (when block
      (cond
       ((string= delta-type "text_delta")
        (let ((text (plist-get delta :text)))
          (when text
            ;; Accumulate into the block
            (plist-put block :text (concat (plist-get block :text) text))
            ;; Accumulate into the bridge accumulated text
            (setq llminate-bridge--accumulated-text
                  (concat llminate-bridge--accumulated-text text))
            ;; Fire message hook
            (setq llminate-bridge--state 'streaming)
            (run-hook-with-args 'llminate-bridge-message-hook "assistant" text)
            ;; Fire callback
            (when llminate-bridge--response-callback
              (funcall llminate-bridge--response-callback 'message text)))))
       ((string= delta-type "input_json_delta")
        (let ((partial-json (plist-get delta :partial_json)))
          (when partial-json
            (plist-put block :input-json
                       (concat (plist-get block :input-json) partial-json)))))))))

(defun llminate-bridge-claude--handle-content-block-stop (event)
  "Handle a `content_block_stop' EVENT.
For tool_use blocks: parse the accumulated JSON, fire tool hooks."
  (let* ((index (plist-get event :index))
         (block (when (and index
                           (< index (length llminate-bridge-claude--content-blocks)))
                  (aref llminate-bridge-claude--content-blocks index))))
    (when (and block (string= (plist-get block :type) "tool_use"))
      (let* ((name (plist-get block :name))
             (id (plist-get block :id))
             (json-str (plist-get block :input-json))
             (input (condition-case nil
                        (when (and json-str (not (string-empty-p json-str)))
                          (json-parse-string json-str
                                             :object-type 'plist
                                             :array-type 'list
                                             :null-object nil
                                             :false-object nil))
                      (json-parse-error nil))))
        ;; Fire tool-use hook
        (run-hook-with-args 'llminate-bridge-tool-use-hook name input)
        (when llminate-bridge--response-callback
          (funcall llminate-bridge--response-callback
                   'tool-use (list :name name :id id :input input)))
        ;; Claude Code executes tools internally — emit synthetic result
        (run-hook-with-args 'llminate-bridge-tool-result-hook
                            "(tool executed by Claude Code)")
        (when llminate-bridge--response-callback
          (funcall llminate-bridge--response-callback
                   'tool-result "(tool executed by Claude Code)"))
        ;; Return to streaming state for any subsequent text blocks
        (setq llminate-bridge--state 'streaming)))))

(defun llminate-bridge-claude--handle-result (event)
  "Handle a `result' EVENT — turn is complete."
  (let ((subtype (plist-get event :subtype))
        (session-id (plist-get event :session_id))
        (text llminate-bridge--accumulated-text))
    ;; Capture session-id if provided in the result
    (when session-id
      (setq llminate-bridge-claude--session-id session-id)
      (setq llminate-bridge--session-id session-id))
    (cond
     ((string= subtype "success")
      ;; End hook
      (run-hook-with-args 'llminate-bridge-end-hook "complete")
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback 'end text))
      (setq llminate-bridge--response-callback nil)
      (setq llminate-bridge--accumulated-text "")
      (setq llminate-bridge--state 'idle)
      ;; Ready hook — idle between turns
      (run-hooks 'llminate-bridge-ready-hook)
      ;; Drain queued prompts
      (when llminate-bridge--prompt-queue
        (let ((next (pop llminate-bridge--prompt-queue)))
          (llminate-bridge-claude--send-prompt (car next) (cdr next)))))
     ((string= subtype "error")
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
            (llminate-bridge-claude--send-prompt (car next) (cdr next)))))))))

;;;; Process sentinel

(defun llminate-bridge-claude--process-sentinel (proc event)
  "Handle process state changes for PROC (Claude Code per-turn process).
EVENT describes the change.  On unexpected exit during streaming,
fire error + ready hooks."
  (let ((status (process-status proc)))
    (unless (eq status 'run)
      (setq llminate-bridge-claude--process nil)
      ;; If we were still streaming, this is an unexpected exit
      (when (memq llminate-bridge--state '(streaming tool-executing))
        (let ((msg (format "Claude Code process exited unexpectedly: %s"
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
              (llminate-bridge-claude--send-prompt
               (car next) (cdr next)))))))))

(provide 'llminate-bridge-claude)

;;; llminate-bridge-claude.el ends here
