;;; smoke-load.el --- Batch smoke test for native modules -*- lexical-binding: t; -*-

(setq command-line-args-left (cdr command-line-args-left))

(unless (= (length command-line-args-left) 2)
  (error "usage: emacs --batch -Q -l test/smoke-load.el -- MODULE-PATH FEATURE"))

(let* ((module-path (nth 0 command-line-args-left))
       (feature-name (nth 1 command-line-args-left))
       (feature (intern feature-name)))
  (unless (file-exists-p module-path)
    (error "module file does not exist: %s" module-path))
  (unless (module-load module-path)
    (error "module-load returned nil for %s" module-path))
  (unless (featurep feature)
    (error "feature not provided: %S" feature))
  (princ (format "smoke-load ok: %s (%s)\n" module-path feature-name)))
