;;; llminate-emacs-commands.el --- Emacs command whitelist and safety layer for llminate -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Whitelist-based security layer for the llminate <-> Emacs bridge.
;; When llminate requests execution of an Emacs function via EmacsEval,
;; this module checks whether the command is registered in the whitelist,
;; what security level it has (allow, prompt, deny), serializes the
;; result back to JSON-compatible values, and provides runtime
;; add/remove/list management.

;;; Code:

(require 'cl-lib)

;;;; Customization

(defgroup llminate-emacs-commands nil
  "Security whitelist for llminate Emacs command execution."
  :group 'llminate
  :prefix "llminate-emacs-commands-")

;;;; Security levels:
;;   allow  - execute immediately, return result
;;   prompt - show approval before executing
;;   deny   - never execute, return error

;;;; Command registry

(defvar llminate-emacs-commands--registry
  '(;; ── File / Buffer operations ──────────────────────────────
    ("find-file"              . allow)
    ("find-file-other-window" . allow)
    ("switch-to-buffer"       . allow)
    ("save-buffer"            . allow)
    ("save-some-buffers"      . prompt)
    ("revert-buffer"          . allow)
    ("kill-buffer"            . prompt)
    ("goto-line"              . allow)
    ("goto-char"              . allow)
    ("set-mark-command"       . allow)
    ("kill-ring-save"         . allow)
    ("buffer-string"          . allow)
    ("buffer-file-name"       . allow)
    ("buffer-list"            . allow)
    ("buffer-name"            . allow)
    ("current-buffer"         . allow)
    ("with-current-buffer"    . allow)

    ;; ── Magit (git) operations ──────────────────────────────
    ("magit-status"              . allow)
    ("magit-stage-file"          . allow)
    ("magit-unstage-file"        . allow)
    ("magit-commit"              . prompt)
    ("magit-push"                . prompt)
    ("magit-pull"                . allow)
    ("magit-log-current"         . allow)
    ("magit-diff-buffer-file"    . allow)
    ("magit-get-current-branch"  . allow)
    ("magit-git-string"          . allow)
    ("magit-stash"               . prompt)

    ;; ── Eglot / LSP operations ──────────────────────────────
    ("eglot-rename"              . prompt)
    ("eglot-code-actions"        . allow)
    ("eglot-find-declaration"    . allow)
    ("eglot-find-implementation" . allow)
    ("xref-find-definitions"     . allow)
    ("xref-find-references"      . allow)
    ("flymake-diagnostics"       . allow)
    ("eglot-format-buffer"       . prompt)

    ;; ── Compilation ─────────────────────────────────────────
    ("compile"                   . prompt)
    ("recompile"                 . allow)
    ("compilation-next-error"    . allow)
    ("next-error"                . allow)
    ("previous-error"            . allow)

    ;; ── Project operations ──────────────────────────────────
    ("project-current"           . allow)
    ("project-root"              . allow)
    ("project-files"             . allow)
    ("project-find-file"         . allow)

    ;; ── Window management ───────────────────────────────────
    ("split-window-right"        . allow)
    ("split-window-below"        . allow)
    ("delete-window"             . allow)
    ("delete-other-windows"      . allow)
    ("balance-windows"           . allow)

    ;; ── Treemacs ────────────────────────────────────────────
    ("treemacs"                  . allow)
    ("treemacs-select-window"    . allow)

    ;; ── Read-only queries (always safe) ─────────────────────
    ("point"                     . allow)
    ("point-min"                 . allow)
    ("point-max"                 . allow)
    ("line-number-at-pos"        . allow)
    ("current-column"            . allow)
    ("buffer-modified-p"         . allow)
    ("window-start"              . allow)
    ("window-end"                . allow)
    ("region-beginning"          . allow)
    ("region-end"                . allow)
    ("mark"                      . allow)
    ("default-directory"         . allow))
  "Alist mapping Emacs command names (strings) to security levels.
Security levels:
  `allow'  -- Execute immediately and return the result.
  `prompt' -- Require user approval before executing.
  `deny'   -- Never execute; return an error.")

;;;; Registry management

(defun llminate-emacs-commands-add (command level)
  "Register COMMAND at security LEVEL in the whitelist.
COMMAND is a string (e.g. \"find-file\").
LEVEL is one of the symbols: `allow', `prompt', `deny'."
  (unless (memq level '(allow prompt deny))
    (error "Invalid security level: %s (must be allow, prompt, or deny)" level))
  (let ((existing (assoc command llminate-emacs-commands--registry)))
    (if existing
        (setcdr existing level)
      (push (cons command level) llminate-emacs-commands--registry))))

(defun llminate-emacs-commands-remove (command)
  "Remove COMMAND from the whitelist."
  (setq llminate-emacs-commands--registry
        (cl-remove-if (lambda (entry) (string= (car entry) command))
                      llminate-emacs-commands--registry)))

(defun llminate-emacs-commands-get-level (command)
  "Return the security level for COMMAND, or nil if not registered."
  (cdr (assoc command llminate-emacs-commands--registry)))

(defun llminate-emacs-commands-list ()
  "Display all registered commands and their security levels."
  (interactive)
  (let ((buf (get-buffer-create "*llminate Commands*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%-35s  %s\n" "Command" "Level"))
        (insert (make-string 50 ?─))
        (insert "\n")
        (dolist (entry (sort (copy-sequence llminate-emacs-commands--registry)
                             (lambda (a b) (string< (car a) (car b)))))
          (insert (format "%-35s  %s\n" (car entry) (cdr entry)))))
      (special-mode))
    (display-buffer buf)))

(defun llminate-emacs-commands-upgrade-to-allow (command)
  "Upgrade COMMAND from `prompt' to `allow' level."
  (let ((entry (assoc command llminate-emacs-commands--registry)))
    (when (and entry (eq (cdr entry) 'prompt))
      (setcdr entry 'allow))))

;;;; Result serialization: Emacs values -> JSON-compatible values

(defun llminate-emacs-commands--serialize-result (value)
  "Serialize an Emacs VALUE to a JSON-compatible representation.
- strings   -> JSON strings
- numbers   -> JSON numbers
- nil       -> :null (JSON null)
- t         -> t (JSON true)
- lists     -> JSON arrays (recursively serialized)
- vectors   -> JSON arrays (recursively serialized)
- buffers   -> their buffer-name (string)
- markers   -> their position (number)
- symbols   -> their name (string)
- hash-tables -> JSON objects (alist)
- Other     -> (format \"%S\" value) as string"
  (cond
   ((null value) :null)
   ((eq value t) t)
   ((stringp value) value)
   ((numberp value) value)
   ((bufferp value) (buffer-name value))
   ((markerp value) (marker-position value))
   ((keywordp value) (substring (symbol-name value) 1))
   ((symbolp value) (symbol-name value))
   ((hash-table-p value)
    (let (result)
      (maphash (lambda (k v)
                 (push (cons (if (symbolp k) (symbol-name k) (format "%s" k))
                             (llminate-emacs-commands--serialize-result v))
                       result))
               value)
      (nreverse result)))
   ((vectorp value)
    (cl-map 'vector #'llminate-emacs-commands--serialize-result value))
   ((listp value)
    ;; Check if it looks like an alist (list of conses with non-list cdrs)
    ;; or a regular list
    (if (and (consp (car value))
             (not (listp (cdar value))))
        ;; Treat as alist -> JSON object
        (mapcar (lambda (pair)
                  (cons (if (symbolp (car pair))
                            (symbol-name (car pair))
                          (format "%s" (car pair)))
                        (llminate-emacs-commands--serialize-result (cdr pair))))
                value)
      ;; Regular list -> JSON array
      (mapcar #'llminate-emacs-commands--serialize-result value)))
   (t (format "%S" value))))

;;;; Command execution

(defvar llminate-emacs-commands--pending-prompts nil
  "Alist of (REQUEST-ID . (COMMAND . ARGS)) awaiting user approval.")

(defun llminate-emacs-commands-execute (command args request-id send-result-fn)
  "Execute COMMAND with ARGS according to its security level.
REQUEST-ID is used to correlate the response.
SEND-RESULT-FN is called with (REQUEST-ID SUCCESS RESULT) to send the result back.

Returns immediately for `allow' commands.
For `prompt' commands, shows an approval dialog first.
For `deny' or unregistered commands, sends an error result."
  (let ((level (llminate-emacs-commands-get-level command)))
    (cond
     ;; Not registered or explicitly denied
     ((or (null level) (eq level 'deny))
      (funcall send-result-fn request-id nil
               (format "Command '%s' is not allowed" command)))

     ;; Execute immediately
     ((eq level 'allow)
      (llminate-emacs-commands--do-execute command args request-id send-result-fn))

     ;; Require user approval
     ((eq level 'prompt)
      (llminate-emacs-commands--prompt-approval
       command args request-id send-result-fn)))))

(defun llminate-emacs-commands--do-execute (command args request-id send-result-fn)
  "Actually execute COMMAND with ARGS and send result via SEND-RESULT-FN."
  (condition-case err
      (let* ((fn (intern command))
             (raw-result (if args
                             (apply fn args)
                           (funcall fn)))
             (result (llminate-emacs-commands--serialize-result raw-result)))
        (funcall send-result-fn request-id t result))
    (error
     (funcall send-result-fn request-id nil
              (error-message-string err)))))

(defun llminate-emacs-commands--prompt-approval (command args request-id send-result-fn)
  "Show approval prompt for COMMAND with ARGS.
REQUEST-ID and SEND-RESULT-FN are forwarded to the execution or denial path.

Keybindings in the prompt:
  y -- approve and execute
  n -- deny
  a -- always allow this command (upgrade to `allow' level) and execute"
  (let ((prompt-msg (format "[llminate] Execute `%s'%s? (y)es (n)o (a)lways: "
                            command
                            (if args
                                (format " with args %S" args)
                              ""))))
    (let ((response (read-char-exclusive prompt-msg)))
      (cond
       ((eq response ?y)
        (llminate-emacs-commands--do-execute command args request-id send-result-fn))
       ((eq response ?a)
        (llminate-emacs-commands-upgrade-to-allow command)
        (message "[llminate] '%s' upgraded to always-allow" command)
        (llminate-emacs-commands--do-execute command args request-id send-result-fn))
       (t
        (funcall send-result-fn request-id nil
                 (format "User denied execution of '%s'" command)))))))

(provide 'llminate-emacs-commands)

;;; llminate-emacs-commands.el ends here
