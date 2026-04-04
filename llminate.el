;;; llminate.el --- AI coding assistant for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.4"))
;; URL: https://github.com/mickillah/llminate-emacs
;; Keywords: ai tools convenience

;;; Commentary:

;; llminate is an Emacs integration for the llminate AI coding assistant.
;; It provides:
;;
;;  - A bidirectional JSON-lines bridge to the llminate subprocess
;;  - Streaming chat UI with markdown rendering
;;  - IDE-style multi-panel layout (treemacs, chat, activity, prompt)
;;  - Tool approval interface with diff preview (ediff)
;;  - Whitelisted Emacs command execution from AI
;;  - Session persistence and resume
;;  - Copilot-style ghost text code completion
;;
;; Quick start:
;;
;;   (require 'llminate)
;;   (llminate-mode 1)
;;
;; Then use C-c q to access all llminate commands.
;; See README.md for full documentation.

;;; Code:

(require 'llminate-bridge)
(require 'llminate-chat)
(require 'llminate-layout)
(require 'llminate-approval)
(require 'llminate-emacs-commands)
(require 'llminate-session)
(require 'llminate-mode)

;; Optional — loaded only if the completion server binary exists
(require 'llminate-completion nil t)

(provide 'llminate)
;;; llminate.el ends here
