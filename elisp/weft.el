;;; weft.el --- Owner console for Weft -*- lexical-binding: t; -*-

(require 'json)
(require 'seq)
(require 'subr-x)
(require 'map)

(defgroup weft nil "Shared Scheme workspace." :group 'tools)
(defcustom weft-program "weft" "Weft command." :type 'string)
(defcustom weft-zone-order nil "Owner-selected zone order." :type '(repeat string))

(defun weft--call (&rest arguments)
  (with-temp-buffer
    (unless (zerop (apply #'process-file weft-program nil (current-buffer) nil arguments))
      (error "Weft: %s" (string-trim (buffer-string))))
    (buffer-string)))

(defun weft--decide (effect decision)
  (let ((expected (alist-get 'expected effect)))
    (when (yes-or-no-p (format "%s this exact effect?\n%s\n" (capitalize decision) expected))
      (weft--call-async "owner" decision (number-to-string (alist-get 'id effect)) expected))))

(defun weft--call-async (&rest arguments)
  (let ((console (current-buffer))
        (output (generate-new-buffer " *weft-effect*")))
    (make-process
     :name "weft-effect" :buffer output :connection-type 'pipe :noquery t
     :command (cons weft-program arguments)
     :sentinel
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (unwind-protect
             (if (zerop (process-exit-status process))
                 (when (buffer-live-p console)
                   (with-current-buffer console (weft-refresh)))
               (message "Weft effect failed: %s"
                        (with-current-buffer output (string-trim (buffer-string)))))
           (kill-buffer output)))))))

(defun weft--insert-zone (zone)
  (let ((start (point)))
    (insert (propertize (alist-get 'name zone) 'face 'bold) "\n")
    (pcase (alist-get 'type zone)
      ("metric" (insert (propertize (alist-get 'display zone) 'face 'font-lock-number-face) "\n"))
      ("table"
       (let* ((rows (alist-get 'rows zone))
              (columns (apply #'max 0 (mapcar #'length rows)))
              (widths (make-vector columns 0)))
         (dolist (row rows)
           (seq-map-indexed (lambda (cell index)
                              (aset widths index (max (aref widths index) (string-width cell)))) row))
         (dolist (row rows)
           (seq-map-indexed (lambda (cell index)
                              (insert cell (make-string (+ 2 (- (aref widths index) (string-width cell))) ?\s))) row)
           (insert "\n"))))
      ("wiring"
       (dolist (edge (alist-get 'rows zone))
         (insert (car edge) " → " (cadr edge) "\n")))
      (_ (insert (alist-get 'display zone) "\n")))
    (insert "\n")
    (add-text-properties start (point) `(weft-zone ,(alist-get 'name zone)))))

(defun weft-refresh ()
  "Refresh the owner console without evaluating room code."
  (interactive)
  (let* ((view (json-parse-string (weft--call "owner" "view") :object-type 'alist :array-type 'list))
         (position (point))
         (inhibit-read-only t)
         (zones (alist-get 'zones view)))
    (erase-buffer)
    (insert (propertize "Weft workspace\n" 'face 'info-title-1)
            "g refresh   e evaluate   m move zone first   s sessions\n\n")
    (dolist (name weft-zone-order)
      (when-let ((zone (seq-find (lambda (zone) (equal name (alist-get 'name zone))) zones)))
        (weft--insert-zone zone)))
    (dolist (zone zones)
      (unless (member (alist-get 'name zone) weft-zone-order) (weft--insert-zone zone)))
    (insert (propertize "Effect requests\n\n" 'face 'bold))
    (dolist (effect (alist-get 'effects view))
      (insert (format "#%s  %s  %s\n%s\n"
                      (alist-get 'id effect) (alist-get 'state effect)
                      (alist-get 'type effect) (alist-get 'expected effect)))
      (if (equal "pending" (alist-get 'state effect))
          (progn
            (insert-text-button "Approve" 'action (lambda (_) (weft--decide effect "approve")))
            (insert "  ")
            (insert-text-button "Reject" 'action (lambda (_) (weft--decide effect "reject"))))
        (insert (alist-get 'receipt effect) "\n")
        (insert-text-button "Archive"
          'action (lambda (_)
                    (weft--call "owner" "archive" (number-to-string (alist-get 'id effect)))
                    (weft-refresh))))
      (insert "\n\n"))
    (insert (propertize "Owner inbox\n\n" 'face 'bold))
    (condition-case err
        (dolist (entry (json-parse-string (weft--call "inbox") :object-type 'alist :array-type 'list))
          (insert (format "%s: %s\n\n" (alist-get 'from entry) (alist-get 'text entry))))
      (error (insert (error-message-string err) "\n")))
    (goto-char (min position (point-max)))))

(defun weft-evaluate (code)
  "Evaluate CODE in the isolated shared room."
  (interactive "sScheme: ")
  (message "%s" (string-trim (weft--call "room-eval" code)))
  (weft-refresh))

(defun weft-zone-first ()
  "Move the zone at point to the top of the owner's layout."
  (interactive)
  (let ((name (get-text-property (point) 'weft-zone)))
    (unless name (user-error "Point is not in a zone"))
    (customize-save-variable 'weft-zone-order (cons name (delete name (copy-sequence weft-zone-order))))
    (weft-refresh)))

(defun weft-session-list ()
  "List live ACP sessions without starting another conversation."
  (seq-filter #'identity
    (mapcar (lambda (buffer)
              (with-current-buffer buffer
                (when (and (derived-mode-p 'agent-shell-mode)
                           (bound-and-true-p agent-shell--state))
                  (list :buffer (buffer-name) :directory default-directory
                        :session (map-nested-elt agent-shell--state '(:session :id))
                        :busy (and (fboundp 'shell-maker-busy) (shell-maker-busy))))))
            (buffer-list))))

(defun weft-session-send (buffer-name prompt)
  "Send PROMPT to an existing ACP session, preserving pending user input."
  (let ((buffer (get-buffer buffer-name)))
    (unless (and buffer (stringp prompt) (not (string-empty-p prompt)))
      (user-error "Expected a live session buffer and nonempty prompt"))
    (with-current-buffer buffer
      (unless (and (derived-mode-p 'agent-shell-mode)
                   (map-nested-elt agent-shell--state '(:session :id)))
        (user-error "Buffer has no connected ACP session"))
      (when (agent-shell--input) (user-error "Session has unsent user input"))
      (if (shell-maker-busy)
          (agent-shell-queue-request prompt)
        (agent-shell--insert-to-shell-buffer :shell-buffer buffer :text prompt :submit t :no-focus t)))
    (list :queued t :buffer buffer-name)))

(defun weft-show-sessions ()
  "Show the interactive sessions available to session-send effects."
  (interactive)
  (with-help-window "*Weft sessions*"
    (princ "Existing ACP sessions\n\n")
    (dolist (session (weft-session-list)) (princ (format "%S\n\n" session)))
    (princ "Native Codex tasks (use codex:ID as the session target)\n\n")
    (condition-case err
        (let ((reply (json-parse-string (weft--call "codex-list") :object-type 'alist :array-type 'list)))
          (dolist (thread (alist-get 'data reply))
            (princ (format "codex:%s  %s\n" (alist-get 'id thread)
                           (or (alist-get 'name thread) (alist-get 'cwd thread))))))
      (error (princ (error-message-string err))))))

(defvar weft-console-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'weft-refresh)
    (define-key map (kbd "e") #'weft-evaluate)
    (define-key map (kbd "m") #'weft-zone-first)
    (define-key map (kbd "s") #'weft-show-sessions)
    map))

(define-derived-mode weft-console-mode special-mode "Weft"
  "Inspect typed zones and decide exact-content effect requests.")

;;;###autoload
(defun weft-console ()
  "Open the native Weft owner console."
  (interactive)
  (pop-to-buffer (get-buffer-create "*Weft*"))
  (weft-console-mode)
  (weft-refresh))

(provide 'weft)
