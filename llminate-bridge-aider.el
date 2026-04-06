;;; llminate-bridge-aider.el --- Aider CLI backend adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Protocol adapter for using Aider (`aider --message`) as the backend
;; instead of the llminate Rust binary.
;;
;; Key differences from JSON-based adapters:
;;   - One process per turn (`--message` causes aider to exit after response)
;;   - NO structured JSON output (maintainer explicitly rejected adding it)
;;   - Output is plain text with SEARCH/REPLACE edit blocks mixed in
;;   - Parsing is best-effort: detect "Applied edit to FILE" lines
;;   - Prompt delivered via `--message "prompt"` CLI argument
;;   - No multi-turn session resumption (each invocation is independent)
;;   - Tool approval not available (--yes auto-approves)
;;   - EmacsEval not supported
;;
;; CLI invocation:
;;   aider --message "prompt" --yes --no-pretty --no-stream [files...]
;;
;; Parsing strategy (text-based, best-effort):
;;   - Process filter accumulates ALL stdout as raw text (no JSON parsing)
;;   - Process sentinel fires hooks when the process exits:
;;     1. Scan for "Applied edit to FILE" lines -> tool-use + tool-result hooks
;;     2. Fire message-hook("assistant", full-text) with complete output
;;     3. Fire end-hook("complete")
;;     4. Set state to idle, fire ready-hook, drain queue
;;   - If process exits with non-zero status, fire error-hook instead
;;
;; This module translates Aider's plain text output into the same hooks
;; used by `llminate-bridge.el' so all downstream modules (chat, layout,
;; approval, session) work unchanged.

;;; Code:

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

(defcustom llminate-bridge-aider-executable "aider"
  "Path to the Aider executable."
  :type 'string
  :group 'llminate-bridge)

(defcustom llminate-bridge-aider-auto-commit nil
  "When non-nil, allow Aider to auto-commit changes.
When nil (the default), passes `--no-auto-commits' to aider so
the user retains full control over git behavior."
  :type 'boolean
  :group 'llminate-bridge)

(defcustom llminate-bridge-aider-extra-files nil
  "List of extra file paths to pass to Aider.
These files are added to the aider context so it can read and edit them.
Each entry should be an absolute or project-relative file path."
  :type '(repeat string)
  :group 'llminate-bridge)

;;;; Internal state

(defvar llminate-bridge-aider--process nil
  "The current per-turn Aider subprocess.")

(defvar llminate-bridge-aider--output-buffer ""
  "Accumulator for all raw stdout from the current Aider process.
Unlike JSON-based adapters, we accumulate the entire output here and
parse it only when the process exits (in the sentinel).")

;;;; ANSI escape code stripping

(defun llminate-bridge-aider--strip-ansi (text)
  "Remove ANSI escape sequences from TEXT.
Even with `--no-pretty', some ANSI codes may leak through from
aider or from tools it invokes.  This strips:
  - CSI sequences: ESC [ ... final-byte
  - OSC sequences: ESC ] ... ST
  - Simple escape sequences: ESC followed by a single character"
  (let ((result text))
    ;; CSI sequences: ESC [ (params) (intermediate) final-byte
    ;; Matches: \e[ followed by optional params (0-9;) and a letter
    (setq result (replace-regexp-in-string
                  "\033\\[\\([0-9;]*\\)[A-Za-z]" "" result t t))
    ;; OSC sequences: ESC ] ... (terminated by BEL or ESC \)
    (setq result (replace-regexp-in-string
                  "\033\\][^\007\033]*\\(\007\\|\033\\\\\\)" "" result t t))
    ;; Remaining simple escape sequences: ESC + single char
    (setq result (replace-regexp-in-string
                  "\033[^[\\]]" "" result t t))
    ;; Strip any bare carriage returns (from \r\n -> \n normalization)
    (setq result (replace-regexp-in-string "\r" "" result t t))
    result))

;;;; Output parsing (text-based, best-effort)

(defun llminate-bridge-aider--parse-applied-edits (text)
  "Scan TEXT for \"Applied edit to FILE\" lines.
Returns a list of file paths that aider reports having edited.
Aider outputs lines like:
  Applied edit to src/main.rs
  Applied edit to tests/test_foo.rs"
  (let ((edits nil)
        (start 0))
    (while (string-match "^Applied edit to \\(.+\\)$" text start)
      (push (match-string 1 text) edits)
      (setq start (match-end 0)))
    (nreverse edits)))

(defun llminate-bridge-aider--parse-commits (text)
  "Scan TEXT for commit lines from Aider.
Aider outputs lines like:
  Commit abcdef0 Fix the bug in parsing
Returns a list of (HASH . MESSAGE) cons cells."
  (let ((commits nil)
        (start 0))
    (while (string-match "^Commit \\([0-9a-f]+\\) \\(.+\\)$" text start)
      (push (cons (match-string 1 text) (match-string 2 text)) commits)
      (setq start (match-end 0)))
    (nreverse commits)))

(defun llminate-bridge-aider--fire-edit-hooks (edited-files)
  "Fire tool-use and tool-result hooks for each file in EDITED-FILES.
Each entry triggers:
  1. `llminate-bridge-tool-use-hook' with (\"Edit\" (:file FILE))
  2. `llminate-bridge-tool-result-hook' with (\"Applied edit to FILE\")"
  (dolist (file edited-files)
    ;; Fire tool-use hook
    (let ((tool-name "Edit")
          (tool-input (list :file file)))
      (run-hook-with-args 'llminate-bridge-tool-use-hook tool-name tool-input)
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback
                 'tool-use (list :name tool-name :input tool-input))))
    ;; Fire tool-result hook
    (let ((result-text (format "Applied edit to %s" file)))
      (run-hook-with-args 'llminate-bridge-tool-result-hook result-text)
      (when llminate-bridge--response-callback
        (funcall llminate-bridge--response-callback
                 'tool-result result-text)))))

;;;; Process argument construction

(defun llminate-bridge-aider--build-args (prompt)
  "Build the argument list for an Aider subprocess.
PROMPT is passed via the `--message' flag."
  (let ((args (list "--message" prompt
                    "--yes"
                    "--no-pretty"
                    "--no-stream")))
    ;; Auto-commit control
    (unless llminate-bridge-aider-auto-commit
      (setq args (append args (list "--no-auto-commits"))))
    ;; Model
    (when llminate-bridge-model
      (setq args (append args (list "--model" llminate-bridge-model))))
    ;; Extra files to include in context
    (when llminate-bridge-aider-extra-files
      (setq args (append args llminate-bridge-aider-extra-files)))
    ;; Extra args from bridge
    (when llminate-bridge-extra-args
      (setq args (append args llminate-bridge-extra-args)))
    args))

;;;; Process lifecycle

(defun llminate-bridge-aider--start (dir)
  "Initialize the Aider backend for project DIR.
Does not spawn a process -- processes are per-turn."
  (setq llminate-bridge--project-dir (expand-file-name dir))
  (setq llminate-bridge-aider--output-buffer "")
  (setq llminate-bridge--accumulated-text "")
  (setq llminate-bridge--state 'idle)
  (setq llminate-bridge--prompt-queue nil)
  ;; Aider has no session concept -- set a synthetic session-id
  (setq llminate-bridge--session-id
        (format "aider-%s" (format-time-string "%Y%m%d%H%M%S")))
  ;; Fire start and ready hooks immediately -- no process to wait for
  (run-hooks 'llminate-bridge-start-hook)
  (run-hooks 'llminate-bridge-ready-hook)
  (message "[aider] Backend ready (dir: %s)" dir)
  ;; Drain any queued prompts
  (when llminate-bridge--prompt-queue
    (let ((next (pop llminate-bridge--prompt-queue)))
      (llminate-bridge-aider--send-prompt (car next) (cdr next)))))

(defun llminate-bridge-aider--stop ()
  "Stop the Aider backend.  Kill any running process."
  (setq llminate-bridge--state 'stopped)
  (when (and llminate-bridge-aider--process
             (process-live-p llminate-bridge-aider--process))
    (delete-process llminate-bridge-aider--process))
  (setq llminate-bridge-aider--process nil)
  (setq llminate-bridge-aider--output-buffer "")
  (message "[aider] Stopped"))

(defun llminate-bridge-aider--running-p ()
  "Return non-nil if the Aider backend is active.
The backend is \"running\" when state is not `stopped', even if
no per-turn process is currently alive."
  (not (eq llminate-bridge--state 'stopped)))

;;;; Sending prompts (spawns a per-turn process)

(defun llminate-bridge-aider--send-prompt (prompt callback)
  "Spawn an Aider process for PROMPT.  Register CALLBACK.
If a process is still running, queue the prompt.
The prompt is passed via `--message' as a CLI argument.
Aider processes one prompt and exits."
  (cl-block llminate-bridge-aider--send-prompt
    ;; If a turn is still in progress, queue and bail
    (when (and llminate-bridge-aider--process
               (process-live-p llminate-bridge-aider--process))
      (push (cons prompt callback) llminate-bridge--prompt-queue)
      (cl-return-from llminate-bridge-aider--send-prompt))
    ;; Set up state
    (setq llminate-bridge--response-callback callback)
    (setq llminate-bridge--accumulated-text "")
    (setq llminate-bridge--state 'streaming)
    (setq llminate-bridge-aider--output-buffer "")
    ;; Build process
    (let* ((default-directory (or llminate-bridge--project-dir default-directory))
           (args (llminate-bridge-aider--build-args prompt)))
      (setq llminate-bridge-aider--process
            (make-process
             :name "aider"
             :buffer (get-buffer-create " *aider-process*")
             :command (cons llminate-bridge-aider-executable args)
             :connection-type 'pipe
             :coding 'utf-8
             :noquery t
             :filter #'llminate-bridge-aider--process-filter
             :sentinel #'llminate-bridge-aider--process-sentinel)))))

;;;; Process filter (raw text accumulation -- NO JSON parsing)

(defun llminate-bridge-aider--process-filter (proc output)
  "Accumulate raw text OUTPUT from PROC.
Unlike JSON-based adapters, no line-by-line parsing happens here.
All output is accumulated into `llminate-bridge-aider--output-buffer'
and processed when the process exits (in the sentinel)."
  ;; Debug: optionally write raw output to the process buffer
  (when llminate-bridge-debug-process-output
    (when-let* ((buf (process-buffer proc)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (goto-char (point-max))
          (insert output)))))
  ;; Accumulate all output -- parsing happens in the sentinel
  (setq llminate-bridge-aider--output-buffer
        (concat llminate-bridge-aider--output-buffer output)))

;;;; Process sentinel (fires all hooks on process exit)

(defun llminate-bridge-aider--process-sentinel (proc event)
  "Handle process state changes for PROC (Aider per-turn process).
EVENT describes the change.

When the process exits, this is where ALL hook firing happens:
  - Strip ANSI codes from accumulated output
  - Detect applied edits -> fire tool-use + tool-result hooks
  - Fire message-hook with the full text
  - Fire end-hook or error-hook depending on exit status
  - Transition to idle, fire ready-hook, drain queue"
  (let ((status (process-status proc))
        (exit-code (process-exit-status proc)))
    (unless (eq status 'run)
      (setq llminate-bridge-aider--process nil)
      ;; Only process output if we were in a streaming/active state
      (when (memq llminate-bridge--state '(streaming tool-executing))
        (let* ((raw-output llminate-bridge-aider--output-buffer)
               (clean-output (llminate-bridge-aider--strip-ansi raw-output)))
          (cond
           ;; Successful exit (exit code 0)
           ((= exit-code 0)
            (llminate-bridge-aider--handle-successful-exit clean-output))
           ;; Non-zero exit -- treat as error
           (t
            (llminate-bridge-aider--handle-error-exit clean-output exit-code)))
          ;; Clean up the output buffer
          (setq llminate-bridge-aider--output-buffer ""))))))

(defun llminate-bridge-aider--handle-successful-exit (output)
  "Handle a successful (exit code 0) Aider process completion.
OUTPUT is the ANSI-stripped full text from the process.

Fires hooks in this order:
  1. Tool-use + tool-result for each detected file edit
  2. Message-hook with the full output text
  3. End-hook with \"complete\"
  4. Transitions to idle, fires ready-hook, drains queue"
  ;; 1. Detect and fire hooks for applied edits
  (let ((edited-files (llminate-bridge-aider--parse-applied-edits output)))
    (when edited-files
      (setq llminate-bridge--state 'tool-executing)
      (llminate-bridge-aider--fire-edit-hooks edited-files)))
  ;; 2. Fire message-hook with the full assistant text
  (when (and output (not (string-empty-p output)))
    (setq llminate-bridge--accumulated-text output)
    (setq llminate-bridge--state 'streaming)
    (run-hook-with-args 'llminate-bridge-message-hook "assistant" output)
    (when llminate-bridge--response-callback
      (funcall llminate-bridge--response-callback 'message output)))
  ;; 3. Fire end-hook
  (let ((text llminate-bridge--accumulated-text))
    (run-hook-with-args 'llminate-bridge-end-hook "complete")
    (when llminate-bridge--response-callback
      (funcall llminate-bridge--response-callback 'end text)))
  ;; 4. Clean up and transition to idle
  (setq llminate-bridge--response-callback nil)
  (setq llminate-bridge--accumulated-text "")
  (setq llminate-bridge--state 'idle)
  ;; Ready hook -- idle between turns
  (run-hooks 'llminate-bridge-ready-hook)
  ;; Drain queued prompts
  (when llminate-bridge--prompt-queue
    (let ((next (pop llminate-bridge--prompt-queue)))
      (llminate-bridge-aider--send-prompt (car next) (cdr next)))))

(defun llminate-bridge-aider--handle-error-exit (output exit-code)
  "Handle a non-zero exit from an Aider process.
OUTPUT is the ANSI-stripped text; EXIT-CODE is the process exit code.

If there is any output, it is included in the error message.
Fires error-hook, transitions to idle, fires ready-hook, drains queue."
  (let ((error-msg (if (and output (not (string-empty-p output)))
                       (format "Aider exited with code %d:\n%s"
                               exit-code
                               ;; Truncate very long error output
                               (if (> (length output) 2000)
                                   (concat (substring output 0 2000) "\n... (truncated)")
                                 output))
                     (format "Aider exited with code %d" exit-code))))
    ;; Fire error-hook
    (run-hook-with-args 'llminate-bridge-error-hook error-msg)
    (when llminate-bridge--response-callback
      (funcall llminate-bridge--response-callback 'error error-msg))
    ;; Clean up and transition to idle
    (setq llminate-bridge--response-callback nil)
    (setq llminate-bridge--accumulated-text "")
    (setq llminate-bridge--state 'idle)
    ;; Ready hook -- idle between turns
    (run-hooks 'llminate-bridge-ready-hook)
    ;; Drain queued prompts
    (when llminate-bridge--prompt-queue
      (let ((next (pop llminate-bridge--prompt-queue)))
        (llminate-bridge-aider--send-prompt (car next) (cdr next))))))

;;;; Self-registration

(llminate-bridge-register-backend
 '(:name           aider
   :label          "Aider"
   :prefix         "ai"
   :start-fn       llminate-bridge-aider--start
   :stop-fn        llminate-bridge-aider--stop
   :running-p-fn   llminate-bridge-aider--running-p
   :send-prompt-fn llminate-bridge-aider--send-prompt
   :enrich-fn      llminate-bridge--emacsclient-instructions))

(provide 'llminate-bridge-aider)

;;; llminate-bridge-aider.el ends here
