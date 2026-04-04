;;; llminate-approval.el --- Tool approval UX for llminate -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1") (transient "0.4"))

;;; Commentary:
;; When llminate requests tool approval (file writes, bash commands, etc.)
;; or when an EmacsCommand has security level `prompt', this module shows
;; a rich approval interface:
;;
;;   - Edit/Write tools: ediff preview of before/after
;;   - Bash tool: syntax-highlighted command in a read-only buffer
;;   - EmacsCommand: show function + args with elisp highlighting
;;   - Other tools: formatted JSON input display
;;
;; Uses transient.el for the approval menu with keybindings:
;;   y = approve       n = deny       e = edit input (Bash)
;;   d = show diff     a = always allow this tool
;;
;; Integrates with:
;;   - llminate-bridge.el (llminate-bridge-tool-approval-hook,
;;     llminate-bridge-send-approval-response)
;;   - llminate-emacs-commands.el (llminate-emacs-commands--prompt-approval
;;     delegates here for 'prompt level commands)

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ediff)
(require 'transient)
(require 'llminate-bridge)
(require 'llminate-emacs-commands)

;;;; Customization

(defgroup llminate-approval nil
  "Tool approval interface for llminate."
  :group 'llminate
  :prefix "llminate-approval-")

(defcustom llminate-approval-auto-allow-tools nil
  "List of tool names that are automatically approved.
Add tool names here to skip the approval prompt for them."
  :type '(repeat string)
  :group 'llminate-approval)

(defcustom llminate-approval-preview-max-lines 80
  "Maximum lines to show in a preview buffer before truncating."
  :type 'integer
  :group 'llminate-approval)

;;;; Faces

(defface llminate-approval-header-face
  '((t :foreground "#61AFEF" :weight bold :height 1.1))
  "Face for the approval header."
  :group 'llminate-approval)

(defface llminate-approval-tool-face
  '((t :foreground "#E5C07B" :weight bold))
  "Face for tool name display."
  :group 'llminate-approval)

(defface llminate-approval-description-face
  '((t :foreground "#ABB2BF"))
  "Face for the tool description."
  :group 'llminate-approval)

(defface llminate-approval-warning-face
  '((t :foreground "#E06C75" :weight bold))
  "Face for warnings and deny messages."
  :group 'llminate-approval)

;;;; Internal state

(defvar llminate-approval--current nil
  "Plist holding the current approval request context.
Keys: :request-id :tool-name :description :input :ediff-buffers
      :preview-buffer :type :send-fn :command :args")

(defvar llminate-approval--always-allow nil
  "List of tool names the user has chosen to always allow this session.")

;;;; Preview buffer management

(defconst llminate-approval--preview-buffer-name "*llminate Approval*"
  "Name of the approval preview buffer.")

(defun llminate-approval--preview-buffer ()
  "Get or create the approval preview buffer."
  (let ((buf (get-buffer-create llminate-approval--preview-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'llminate-approval-preview-mode)
        (llminate-approval-preview-mode)))
    buf))

(defvar llminate-approval-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "y") #'llminate-approval-approve)
    (define-key map (kbd "n") #'llminate-approval-deny)
    (define-key map (kbd "a") #'llminate-approval-always-allow)
    (define-key map (kbd "e") #'llminate-approval-edit-input)
    (define-key map (kbd "d") #'llminate-approval-show-diff)
    (define-key map (kbd "q") #'llminate-approval-deny)
    map)
  "Keymap for `llminate-approval-preview-mode'.")

(define-derived-mode llminate-approval-preview-mode special-mode "llminate Approval"
  "Major mode for the llminate tool approval preview.
Shows tool details and provides approval keybindings.

\\{llminate-approval-preview-mode-map}"
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local buffer-read-only t))

;;;; Main entry point: handle ToolApproval events from bridge

(defun llminate-approval--handle (event)
  "Handle a ToolApproval EVENT from the llminate bridge.
EVENT is a plist with :tool_name, :description, :input, :request_id."
  (let* ((tool-name   (plist-get event :tool_name))
         (description (plist-get event :description))
         (input       (plist-get event :input))
         (request-id  (plist-get event :request_id)))
    ;; Check auto-allow lists (customization + session)
    (if (or (member tool-name llminate-approval-auto-allow-tools)
            (member tool-name llminate-approval--always-allow))
        ;; Auto-approve
        (llminate-bridge-send-approval-response request-id t)
      ;; Store current context
      (setq llminate-approval--current
            (list :request-id request-id
                  :tool-name tool-name
                  :description description
                  :input input
                  :type 'tool))
      ;; Dispatch to tool-specific preview
      (cond
       ((member tool-name '("Edit" "Write" "FileEdit" "FileWrite" "MultiEdit"))
        (llminate-approval--show-file-edit-preview tool-name input description))
       ((member tool-name '("Bash" "BashCommand"))
        (llminate-approval--show-bash-preview input description))
       ((string= tool-name "EmacsCommand")
        (llminate-approval--show-emacs-command-preview input description))
       (t
        (llminate-approval--show-generic-preview tool-name input description))))))

;; Hook into the bridge
(add-hook 'llminate-bridge-tool-approval-hook #'llminate-approval--handle)

;;;; Tool-specific preview displays

(defun llminate-approval--show-file-edit-preview (tool-name input description)
  "Show a preview for file edit tools.
TOOL-NAME, INPUT, and DESCRIPTION describe the pending tool call."
  (let* ((buf (llminate-approval--preview-buffer))
         (file-path (or (plist-get input :file_path)
                        (plist-get input :path)
                        "unknown"))
         (old-string (plist-get input :old_string))
         (new-string (plist-get input :new_string))
         (content    (plist-get input :content)))
    ;; Save ediff buffers for potential diff display
    (when (and old-string new-string)
      (let ((buf-a (generate-new-buffer " *llminate-old*"))
            (buf-b (generate-new-buffer " *llminate-new*")))
        (with-current-buffer buf-a (insert old-string))
        (with-current-buffer buf-b (insert new-string))
        (plist-put llminate-approval--current :ediff-buffers
                   (cons buf-a buf-b))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (llminate-approval--insert-header tool-name description)
        (insert "\n")
        (llminate-approval--insert-field "File" file-path)
        (cond
         ;; Edit tool: show old -> new
         ((and old-string new-string)
          (insert "\n")
          (llminate-approval--insert-field "Old" "")
          (llminate-approval--insert-code old-string)
          (insert "\n")
          (llminate-approval--insert-field "New" "")
          (llminate-approval--insert-code new-string))
         ;; Write tool: show content
         (content
          (insert "\n")
          (llminate-approval--insert-field "Content" "")
          (llminate-approval--insert-code
           (llminate-approval--truncate-text content))))
        (insert "\n")
        (llminate-approval--insert-keybinding-help
         '(("y" . "approve") ("n" . "deny") ("d" . "show ediff") ("a" . "always allow") ("q" . "quit/deny")))))
    (llminate-approval--display-preview buf)))

(defun llminate-approval--show-bash-preview (input description)
  "Show a preview for Bash tool calls.
INPUT and DESCRIPTION describe the pending command."
  (let* ((buf (llminate-approval--preview-buffer))
         (command (or (plist-get input :command) ""))
         (timeout (plist-get input :timeout))
         (desc    (plist-get input :description)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (llminate-approval--insert-header "Bash" (or description desc ""))
        (insert "\n")
        (when desc
          (llminate-approval--insert-field "Description" desc))
        (when timeout
          (llminate-approval--insert-field "Timeout" (format "%sms" timeout)))
        (insert "\n")
        (llminate-approval--insert-field "Command" "")
        ;; Show command with sh-mode syntax highlighting
        (let ((start (point)))
          (insert command)
          (insert "\n")
          ;; Apply basic shell highlighting via font-lock
          (let ((temp-buf (generate-new-buffer " *llminate-sh-hl*")))
            (unwind-protect
                (let ((highlighted
                       (with-current-buffer temp-buf
                         (insert command)
                         (sh-mode)
                         (font-lock-ensure)
                         (buffer-string))))
                  (delete-region start (1- (point)))
                  (goto-char start)
                  (insert highlighted))
              (kill-buffer temp-buf))))
        (insert "\n")
        (llminate-approval--insert-keybinding-help
         '(("y" . "approve") ("n" . "deny") ("e" . "edit command") ("a" . "always allow") ("q" . "quit/deny")))))
    (llminate-approval--display-preview buf)))

(defun llminate-approval--show-emacs-command-preview (input description)
  "Show a preview for EmacsCommand tool calls.
INPUT and DESCRIPTION describe the pending function call."
  (let* ((buf (llminate-approval--preview-buffer))
         (command (or (plist-get input :command) ""))
         (args    (plist-get input :args))
         (desc    (plist-get input :description)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (llminate-approval--insert-header "EmacsCommand" (or description desc ""))
        (insert "\n")
        ;; Show the elisp form with highlighting
        (llminate-approval--insert-field "Function" command)
        (when args
          (llminate-approval--insert-field "Arguments" (format "%S" args)))
        (insert "\n")
        (llminate-approval--insert-field "Elisp form" "")
        (let* ((form (if args
                         (format "(%s %s)"
                                 command
                                 (mapconcat (lambda (a) (format "%S" a)) args " "))
                       (format "(%s)" command)))
               (start (point)))
          ;; Insert with emacs-lisp highlighting
          (let ((temp-buf (generate-new-buffer " *llminate-el-hl*")))
            (unwind-protect
                (let ((highlighted
                       (with-current-buffer temp-buf
                         (insert form)
                         (emacs-lisp-mode)
                         (font-lock-ensure)
                         (buffer-string))))
                  (insert highlighted))
              (kill-buffer temp-buf))))
        (insert "\n\n")
        ;; Show the security level from the registry
        (let ((level (llminate-emacs-commands-get-level command)))
          (when level
            (llminate-approval--insert-field
             "Security level" (symbol-name level))))
        (insert "\n")
        (llminate-approval--insert-keybinding-help
         '(("y" . "approve") ("n" . "deny") ("a" . "always allow") ("q" . "quit/deny")))))
    (llminate-approval--display-preview buf)))

(defun llminate-approval--show-generic-preview (tool-name input description)
  "Show a generic preview for unrecognized TOOL-NAME.
INPUT and DESCRIPTION describe the tool call."
  (let ((buf (llminate-approval--preview-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (llminate-approval--insert-header tool-name (or description ""))
        (insert "\n")
        (llminate-approval--insert-field "Input" "")
        (let ((json-encoding-pretty-print t))
          (insert (json-encode input)))
        (insert "\n\n")
        (llminate-approval--insert-keybinding-help
         '(("y" . "approve") ("n" . "deny") ("a" . "always allow") ("q" . "quit/deny")))))
    (llminate-approval--display-preview buf)))

;;;; Display helpers

(defun llminate-approval--insert-header (tool-name description)
  "Insert a formatted header for TOOL-NAME and DESCRIPTION."
  (let ((start (point)))
    (insert (format "Tool Approval: %s" tool-name))
    (add-text-properties start (point)
                         (list 'face 'llminate-approval-header-face))
    (insert "\n")
    (insert (make-string 50 ?═))
    (insert "\n")
    (when (and description (not (string-empty-p description)))
      (let ((desc-start (point)))
        (insert description)
        (add-text-properties desc-start (point)
                             (list 'face 'llminate-approval-description-face))
        (insert "\n")))))

(defun llminate-approval--insert-field (label value)
  "Insert a LABEL: VALUE line with appropriate faces."
  (let ((start (point)))
    (insert (format "  %s: " label))
    (add-text-properties start (point)
                         (list 'face 'llminate-approval-tool-face))
    (insert (format "%s\n" value))))

(defun llminate-approval--insert-code (text)
  "Insert TEXT as an indented code block."
  (let ((lines (split-string (or text "") "\n")))
    (dolist (line lines)
      (insert (format "    %s\n" line)))))

(defun llminate-approval--insert-keybinding-help (bindings)
  "Insert a help line showing BINDINGS as (KEY . DESCRIPTION) pairs."
  (insert (make-string 50 ?─))
  (insert "\n")
  (let ((start (point)))
    (insert "  ")
    (dolist (binding bindings)
      (insert (format "[%s] %s  " (car binding) (cdr binding))))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'face 'font-lock-comment-face))))

(defun llminate-approval--truncate-text (text)
  "Truncate TEXT to `llminate-approval-preview-max-lines' lines."
  (let ((lines (split-string text "\n")))
    (if (> (length lines) llminate-approval-preview-max-lines)
        (concat
         (mapconcat #'identity
                    (cl-subseq lines 0 llminate-approval-preview-max-lines)
                    "\n")
         (format "\n... (%d more lines)" (- (length lines) llminate-approval-preview-max-lines)))
      text)))

(defun llminate-approval--display-preview (buf)
  "Display the preview BUF in a popup window and select it."
  (plist-put llminate-approval--current :preview-buffer buf)
  (let ((win (display-buffer-in-side-window
              buf
              '((side . bottom)
                (window-height . 0.35)
                (slot . -1)
                (window-parameters . ((no-delete-other-windows . t)))))))
    (when win
      (select-window win)
      (goto-char (point-min)))))

(defun llminate-approval--cleanup ()
  "Clean up preview buffers and ediff state."
  ;; Kill ediff temp buffers
  (let ((ediff-bufs (plist-get llminate-approval--current :ediff-buffers)))
    (when ediff-bufs
      (when (buffer-live-p (car ediff-bufs))
        (kill-buffer (car ediff-bufs)))
      (when (buffer-live-p (cdr ediff-bufs))
        (kill-buffer (cdr ediff-bufs)))))
  ;; Close the preview window (but keep the buffer for reference)
  (let ((buf (get-buffer llminate-approval--preview-buffer-name)))
    (when buf
      (let ((win (get-buffer-window buf)))
        (when win (delete-window win)))))
  (setq llminate-approval--current nil))

;;;; Approval actions

(defun llminate-approval--respond (approved)
  "Send an approval response and clean up.
APPROVED is t to approve, nil to deny."
  (let ((ctx llminate-approval--current))
    (unless ctx
      (user-error "No pending approval request"))
    (let ((req-type (plist-get ctx :type)))
      (cond
       ;; Tool approval from the bridge
       ((eq req-type 'tool)
        (let ((request-id (plist-get ctx :request-id)))
          (llminate-bridge-send-approval-response request-id approved)))
       ;; Emacs command approval (delegated from llminate-emacs-commands)
       ((eq req-type 'emacs-command)
        (let ((request-id (plist-get ctx :request-id))
              (command    (plist-get ctx :command))
              (args       (plist-get ctx :args))
              (send-fn    (plist-get ctx :send-fn)))
          (if approved
              (llminate-emacs-commands--do-execute command args request-id send-fn)
            (funcall send-fn request-id nil
                     (format "User denied execution of '%s'" command)))))))
    (llminate-approval--cleanup)
    (message "[llminate] %s" (if approved "Approved" "Denied"))))

(defun llminate-approval-approve ()
  "Approve the current tool request."
  (interactive)
  (llminate-approval--respond t))

(defun llminate-approval-deny ()
  "Deny the current tool request."
  (interactive)
  (llminate-approval--respond nil))

(defun llminate-approval-always-allow ()
  "Approve and remember: always allow this tool for the rest of the session."
  (interactive)
  (let ((ctx llminate-approval--current))
    (unless ctx
      (user-error "No pending approval request"))
    (let ((tool-name (plist-get ctx :tool-name))
          (command   (plist-get ctx :command)))
      (cond
       ;; Tool from the bridge
       (tool-name
        (push tool-name llminate-approval--always-allow)
        (message "[llminate] '%s' will be auto-approved this session" tool-name))
       ;; Emacs command
       (command
        (llminate-emacs-commands-upgrade-to-allow command)
        (message "[llminate] '%s' upgraded to always-allow" command))))
    (llminate-approval--respond t)))

(defun llminate-approval-edit-input ()
  "Edit the input before approving (primarily for Bash commands).
Opens an editable buffer; C-c C-c to approve with edits, C-c C-k to cancel."
  (interactive)
  (let ((ctx llminate-approval--current))
    (unless ctx
      (user-error "No pending approval request"))
    (let* ((input (plist-get ctx :input))
           (command (or (plist-get input :command) ""))
           (edit-buf (get-buffer-create "*llminate Edit Input*")))
      (with-current-buffer edit-buf
        (erase-buffer)
        (insert command)
        (sh-mode)
        (font-lock-ensure)
        (goto-char (point-min))
        ;; Set up keybindings for the edit buffer
        (local-set-key (kbd "C-c C-c")
                       (lambda ()
                         (interactive)
                         (let ((new-command (string-trim (buffer-string))))
                           ;; Update the input in the current context
                           (plist-put (plist-get llminate-approval--current :input)
                                      :command new-command)
                           (kill-buffer edit-buf)
                           (llminate-approval--respond t))))
        (local-set-key (kbd "C-c C-k")
                       (lambda ()
                         (interactive)
                         (kill-buffer edit-buf)
                         (message "[llminate] Edit cancelled"))))
      (pop-to-buffer edit-buf)
      (message "Edit the command. C-c C-c to approve, C-c C-k to cancel."))))

(defun llminate-approval-show-diff ()
  "Show an ediff comparison for file edit tools."
  (interactive)
  (let ((ctx llminate-approval--current))
    (unless ctx
      (user-error "No pending approval request"))
    (let ((ediff-bufs (plist-get ctx :ediff-buffers)))
      (unless ediff-bufs
        (user-error "No diff available for this tool"))
      (let ((buf-a (car ediff-bufs))
            (buf-b (cdr ediff-bufs)))
        (unless (and (buffer-live-p buf-a) (buffer-live-p buf-b))
          (user-error "Diff buffers are no longer available"))
        ;; Set up ediff to not steal focus from approval
        (let ((ediff-split-window-function #'split-window-horizontally)
              (ediff-window-setup-function #'ediff-setup-windows-plain))
          (ediff-buffers buf-a buf-b
                         (list (lambda ()
                                 (add-hook 'ediff-quit-hook
                                           (lambda ()
                                             ;; Return to the approval preview
                                             (let ((preview (get-buffer llminate-approval--preview-buffer-name)))
                                               (when preview
                                                 (pop-to-buffer preview))))
                                           nil t)))))))))

;;;; Transient integration for richer approval menu

(transient-define-prefix llminate-approval-transient ()
  "Tool approval menu for llminate."
  :transient-non-suffix 'transient--do-exit
  ["llminate Tool Approval"
   ("y" "Approve"       llminate-approval-approve)
   ("n" "Deny"          llminate-approval-deny)
   ("a" "Always allow"  llminate-approval-always-allow)
   ("e" "Edit input"    llminate-approval-edit-input)
   ("d" "Show diff"     llminate-approval-show-diff)
   ("q" "Quit (deny)"   llminate-approval-deny)])

;;;; Integration with llminate-emacs-commands.el
;;
;; Replace the simple read-char-exclusive prompt with the rich approval UX.
;; This is done by advising the prompt function.

(defun llminate-approval--emacs-command-prompt (command args request-id send-result-fn)
  "Rich approval prompt for Emacs commands with security level `prompt'.
COMMAND, ARGS, REQUEST-ID, and SEND-RESULT-FN are passed through
from `llminate-emacs-commands-execute'."
  ;; Store context
  (setq llminate-approval--current
        (list :request-id request-id
              :command command
              :args args
              :send-fn send-result-fn
              :type 'emacs-command))
  ;; Show the preview
  (llminate-approval--show-emacs-command-preview
   (list :command command :args args)
   (format "Execute Emacs function: %s" command)))

;; Override the prompt function from llminate-emacs-commands.el
;; so that 'prompt level commands use this rich UX
(advice-add 'llminate-emacs-commands--prompt-approval
            :override #'llminate-approval--emacs-command-prompt)

;;;; Reset session state

(defun llminate-approval-reset ()
  "Reset all session-level always-allow lists."
  (interactive)
  (setq llminate-approval--always-allow nil)
  (message "[llminate] Session auto-allow list cleared"))

(provide 'llminate-approval)

;;; llminate-approval.el ends here
