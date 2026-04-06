;;; llminate-session.el --- Session persistence for llminate -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Persist and resume llminate sessions across Emacs restarts.
;; Sessions are stored in ~/.emacs.d/llminate-sessions.json.
;; Uses llminate's --resume SESSION_ID flag to restore context.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'llminate-bridge)

;;;; Customization

(defgroup llminate-session nil
  "Session persistence for the llminate coding assistant."
  :group 'llminate
  :prefix "llminate-session-")

(defcustom llminate-session-file
  (expand-file-name "llminate-sessions.json" user-emacs-directory)
  "File for persisting llminate sessions."
  :type 'file
  :group 'llminate-session)

(defcustom llminate-session-max-entries 50
  "Maximum number of saved sessions."
  :type 'integer
  :group 'llminate-session)

(defcustom llminate-session-auto-save t
  "Whether to auto-save the session on `kill-emacs-hook'."
  :type 'boolean
  :group 'llminate-session)

(defcustom llminate-session-auto-resume nil
  "Whether to auto-resume the last session when starting llminate.
If non-nil, `llminate-bridge-start' will attempt to resume the
most recent session for the current project."
  :type 'boolean
  :group 'llminate-session)

;;;; Internal helpers

(defun llminate-session--read-sessions ()
  "Read the sessions alist from the sessions file.
Returns a list of plists, each with keys:
  :session_id :project_dir :timestamp :model :excerpt"
  (if (file-exists-p llminate-session-file)
      (condition-case err
          (let* ((json-object-type 'plist)
                 (json-array-type 'list)
                 (json-key-type 'keyword)
                 (json-false nil))
            (json-read-file llminate-session-file))
        (error
         (message "[llminate-session] Error reading sessions: %s"
                  (error-message-string err))
         nil))
    nil))

(defun llminate-session--write-sessions (sessions)
  "Write SESSIONS to the sessions file."
  (let ((json-encoding-pretty-print t)
        (json-false :json-false)
        (json-null :null))
    (with-temp-file llminate-session-file
      (insert (json-encode sessions)))))

(defun llminate-session--chat-excerpt ()
  "Return a short excerpt from the chat log for session metadata."
  (let ((buf (get-buffer "*llminate Chat*")))
    (if (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (let* ((text (buffer-substring-no-properties
                        (point-min)
                        (min (point-max) (+ (point-min) 300))))
                 (trimmed (string-trim text)))
            (if (> (length trimmed) 200)
                (concat (substring trimmed 0 197) "...")
              trimmed)))
      "")))

;;;; Save

;;;###autoload
(defun llminate-session-save ()
  "Save the current llminate session to the sessions file.
No-op if there is no active session."
  (interactive)
  (let ((session-id (llminate-bridge-session-id))
        (project-dir llminate-bridge--project-dir)
        (model (llminate-bridge-model)))
    (unless session-id
      (when (called-interactively-p 'interactive)
        (message "[llminate-session] No active session to save"))
      (cl-return-from llminate-session-save))
    (let* ((sessions (llminate-session--read-sessions))
           ;; Remove any existing entry for this session-id
           (sessions (cl-remove-if
                      (lambda (s) (string= (plist-get s :session_id) session-id))
                      sessions))
           (entry (list :session_id session-id
                        :project_dir (or project-dir "")
                        :timestamp (format-time-string "%Y-%m-%dT%H:%M:%S")
                        :model (or model "")
                        :excerpt (llminate-session--chat-excerpt))))
      ;; Prepend newest entry
      (push entry sessions)
      ;; Trim to max
      (when (> (length sessions) llminate-session-max-entries)
        (setq sessions (cl-subseq sessions 0 llminate-session-max-entries)))
      (llminate-session--write-sessions sessions)
      (message "[llminate-session] Saved session %s" session-id))))

;;;; Resume

;;;###autoload
(defun llminate-session-resume (session-id)
  "Resume a session identified by SESSION-ID.
Delegates to the current backend's `:resume-fn' if one is registered,
otherwise falls back to passing `--resume SESSION-ID' to `llminate-bridge-start'."
  (interactive
   (list (llminate-session--pick-session "Resume session: ")))
  (unless session-id
    (user-error "No session selected"))
  ;; Find the session entry for the project dir
  (let* ((sessions (llminate-session--read-sessions))
         (entry (cl-find-if
                 (lambda (s) (string= (plist-get s :session_id) session-id))
                 sessions))
         (project-dir (when entry (plist-get entry :project_dir)))
         (desc (llminate-bridge--get-backend))
         (resume-fn (plist-get desc :resume-fn)))
    ;; Stop current session if running
    (when (llminate-bridge-running-p)
      (llminate-bridge-stop)
      (sit-for 0.3))
    (if resume-fn
        ;; Backend-specific resume
        (funcall resume-fn session-id (or project-dir default-directory))
      ;; Default: pass --resume to llminate-bridge-start
      (let ((llminate-bridge-extra-args
             (append llminate-bridge-extra-args
                     (list "--resume" session-id))))
        (llminate-bridge-start (or project-dir default-directory))))
    (message "[llminate-session] Resuming session %s" session-id)))

(defun llminate-session--pick-session (prompt)
  "Let the user pick a session ID using `completing-read'.
PROMPT is the prompt string."
  (let* ((sessions (llminate-session--read-sessions))
         (candidates
          (mapcar (lambda (s)
                    (let ((id (plist-get s :session_id))
                          (dir (plist-get s :project_dir))
                          (ts (plist-get s :timestamp))
                          (model (plist-get s :model)))
                      (cons (format "%s  %s  %s  %s"
                                    (or ts "?")
                                    (or model "?")
                                    (file-name-nondirectory
                                     (directory-file-name (or dir "?")))
                                    (or id "?"))
                            id)))
                  sessions)))
    (when candidates
      (cdr (assoc (completing-read prompt candidates nil t) candidates)))))

;;;; Auto-resume for project

(defun llminate-session--latest-for-project (project-dir)
  "Return the most recent session-id for PROJECT-DIR, or nil."
  (let* ((sessions (llminate-session--read-sessions))
         (matches (cl-remove-if-not
                   (lambda (s)
                     (string= (expand-file-name (or (plist-get s :project_dir) ""))
                              (expand-file-name project-dir)))
                   sessions)))
    (when matches
      (plist-get (car matches) :session_id))))

;;;; List / manage sessions

;;;###autoload
(defun llminate-session-list ()
  "Display saved sessions in a buffer.
RET to resume, d to delete, q to quit."
  (interactive)
  (let* ((sessions (llminate-session--read-sessions))
         (buf (get-buffer-create "*llminate Sessions*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "llminate Sessions\n" 'face 'bold))
        (insert (make-string 60 ?─) "\n")
        (insert (format "%-20s %-12s %-20s %s\n"
                        "Timestamp" "Model" "Project" "Session ID"))
        (insert (make-string 60 ?─) "\n")
        (if (null sessions)
            (insert "(no saved sessions)\n")
          (dolist (s sessions)
            (let ((start (point))
                  (id (plist-get s :session_id))
                  (dir (plist-get s :project_dir))
                  (ts (plist-get s :timestamp))
                  (model (plist-get s :model)))
              (insert (format "%-20s %-12s %-20s %s\n"
                              (or ts "?")
                              (or model "?")
                              (file-name-nondirectory
                               (directory-file-name (or dir "?")))
                              (or id "?")))
              (put-text-property start (point) 'llminate-session-id id)))))
      (llminate-session-list-mode))
    (display-buffer buf)))

(defvar llminate-session-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'llminate-session-list-resume)
    (define-key map (kbd "d")   #'llminate-session-list-delete)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "g")   #'llminate-session-list)
    map)
  "Keymap for `llminate-session-list-mode'.")

(define-derived-mode llminate-session-list-mode special-mode "llminate Sessions"
  "Mode for the llminate sessions list buffer.
\\{llminate-session-list-mode-map}"
  (setq-local truncate-lines t))

(defun llminate-session-list--id-at-point ()
  "Return the session ID at point, or nil."
  (get-text-property (line-beginning-position) 'llminate-session-id))

(defun llminate-session-list-resume ()
  "Resume the session at point."
  (interactive)
  (let ((id (llminate-session-list--id-at-point)))
    (unless id (user-error "No session at point"))
    (llminate-session-resume id)))

(defun llminate-session-list-delete ()
  "Delete the session at point from the sessions file."
  (interactive)
  (let ((id (llminate-session-list--id-at-point)))
    (unless id (user-error "No session at point"))
    (when (yes-or-no-p (format "Delete session %s? " id))
      (let* ((sessions (llminate-session--read-sessions))
             (sessions (cl-remove-if
                        (lambda (s) (string= (plist-get s :session_id) id))
                        sessions)))
        (llminate-session--write-sessions sessions)
        (llminate-session-list)
        (message "[llminate-session] Deleted session %s" id)))))

;;;; Chat log export — markdown, HTML, org
;;
;; After each assistant turn, export the full conversation in 3 formats
;; into the project's conversations directory (default: .llminate/conversations/).

(defcustom llminate-session-chatlog-auto-save t
  "When non-nil, auto-export chat logs after each assistant turn."
  :type 'boolean
  :group 'llminate-session)

(defcustom llminate-session-pandoc-executable "pandoc"
  "Path to the pandoc executable for HTML/org conversion."
  :type 'string
  :group 'llminate-session)

(defcustom llminate-session-conversations-dir ".llminate/conversations/"
  "Relative directory (under the project root) for exported chat logs."
  :type 'string
  :group 'llminate-session)

(defun llminate-session--conversations-dir ()
  "Return the conversations directory for the current project.
Creates it if necessary."
  (let ((dir (expand-file-name llminate-session-conversations-dir
                                (or llminate-bridge--project-dir
                                    default-directory))))
    (make-directory dir t)
    dir))

(defun llminate-session--build-markdown ()
  "Build a markdown document from `llminate-chat-message-log'.
Returns a string."
  (let ((messages (llminate-chat-message-log))
        (session-id (or (llminate-bridge-session-id) "unknown"))
        (model (or (llminate-bridge-model) "unknown")))
    (with-temp-buffer
      (insert (format "---\nsession: %s\nmodel: %s\ndate: %s\n---\n\n"
                      session-id model
                      (format-time-string "%Y-%m-%d %H:%M:%S")))
      (dolist (msg messages)
        (let ((role (plist-get msg :role))
              (content (plist-get msg :content))
              (ts (plist-get msg :timestamp)))
          (cond
           ((string= role "user")
            (insert (format "## You — %s\n\n%s\n\n---\n\n" (or ts "") (or content ""))))
           ((string= role "assistant")
            (insert (format "## Assistant — %s\n\n%s\n\n---\n\n" (or ts "") (or content "")))))))
      (buffer-string))))

(defun llminate-session--save-markdown (md-text session-id)
  "Save MD-TEXT as SESSION-ID.md in the conversations directory."
  (let ((path (expand-file-name (format "%s.md" session-id)
                                 (llminate-session--conversations-dir))))
    (with-temp-file path
      (insert md-text))
    path))

(defun llminate-session--save-html (md-text session-id)
  "Convert MD-TEXT to HTML via pandoc and save as SESSION-ID.html."
  (let ((path (expand-file-name (format "%s.html" session-id)
                                 (llminate-session--conversations-dir))))
    (condition-case err
        (with-temp-buffer
          (insert md-text)
          (let ((exit-code
                 (call-process-region (point-min) (point-max)
                                      llminate-session-pandoc-executable
                                      t t nil
                                      "-f" "markdown" "-t" "html"
                                      "--standalone"
                                      "--metadata" "title=Chat Log")))
            (if (eq exit-code 0)
                (progn
                  (write-region (point-min) (point-max) path nil 'quiet)
                  path)
              (message "[llminate-session] pandoc HTML exit code %s" exit-code)
              nil)))
      (error
       (message "[llminate-session] HTML export failed: %s"
                (error-message-string err))
       nil))))

(defun llminate-session--save-org (md-text session-id)
  "Convert MD-TEXT to org via pandoc and save as SESSION-ID.org."
  (let ((path (expand-file-name (format "%s.org" session-id)
                                 (llminate-session--conversations-dir))))
    (condition-case err
        (with-temp-buffer
          (insert md-text)
          (let ((exit-code
                 (call-process-region (point-min) (point-max)
                                      llminate-session-pandoc-executable
                                      t t nil
                                      "-f" "markdown" "-t" "org")))
            (if (eq exit-code 0)
                (progn
                  (write-region (point-min) (point-max) path nil 'quiet)
                  path)
              (message "[llminate-session] pandoc org exit code %s" exit-code)
              nil)))
      (error
       (message "[llminate-session] Org export failed: %s"
                (error-message-string err))
       nil))))

(defun llminate-session-export-chatlog ()
  "Export the current chat log in all 3 formats (md, html, org).
Returns a plist (:md PATH :html PATH :org PATH) of saved files."
  (interactive)
  (let ((session-id (llminate-bridge-session-id)))
    (unless session-id
      (when (called-interactively-p 'interactive)
        (message "[llminate-session] No active session"))
      (cl-return-from llminate-session-export-chatlog nil))
    (let ((messages (llminate-chat-message-log)))
      (unless messages
        (when (called-interactively-p 'interactive)
          (message "[llminate-session] No messages to export"))
        (cl-return-from llminate-session-export-chatlog nil))
      (let* ((md-text (llminate-session--build-markdown))
             (md-path (llminate-session--save-markdown md-text session-id))
             (html-path (llminate-session--save-html md-text session-id))
             (org-path (llminate-session--save-org md-text session-id)))
        (when (called-interactively-p 'interactive)
          (message "[llminate-session] Exported: %s (.md .html .org)"
                   (file-name-directory md-path)))
        (list :md md-path :html html-path :org org-path)))))

(defun llminate-session--auto-export-chatlog ()
  "Auto-export chat log after each turn (if enabled)."
  (when (and llminate-session-chatlog-auto-save
             (llminate-bridge-session-id))
    (llminate-session-export-chatlog)))

;;;; Auto-save on kill-emacs

(defun llminate-session--auto-save ()
  "Auto-save hook for `kill-emacs-hook'."
  (when (and llminate-session-auto-save
             (llminate-bridge-running-p))
    (llminate-session-save)
    (llminate-session-export-chatlog)))

(add-hook 'kill-emacs-hook #'llminate-session--auto-save)

;; Hook into the chat turn-end to auto-export
(with-eval-after-load 'llminate-chat
  (add-hook 'llminate-chat-turn-end-hook #'llminate-session--auto-export-chatlog))

(provide 'llminate-session)

;;; llminate-session.el ends here
