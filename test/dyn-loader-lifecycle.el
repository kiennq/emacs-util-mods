;;; dyn-loader-lifecycle.el --- Batch lifecycle test for dyn-loader -*- lexical-binding: t; -*-

(setq command-line-args-left (cdr command-line-args-left))

(unless (= (length command-line-args-left) 5)
  (error "usage: emacs --batch -Q -l test/dyn-loader-lifecycle.el -- MODULE-PATH MANIFEST-PATH LIVE-PATH V2-PATH V3-PATH"))

(let* ((module-path (nth 0 command-line-args-left))
       (manifest-path (nth 1 command-line-args-left))
       (live-path (nth 2 command-line-args-left))
       (v2-path (nth 3 command-line-args-left))
       (v3-path (nth 4 command-line-args-left))
       (module-id nil)
       (old-fn nil))
  (dolist (path (list module-path manifest-path live-path v2-path v3-path))
    (unless (file-exists-p path)
      (error "test input does not exist: %s" path)))

  (unless (module-load module-path)
    (error "module-load returned nil for %s" module-path))
  (unless (featurep 'dyn-loader-module)
    (error "feature not provided: dyn-loader-module"))

  (setq module-id (dyn-loader-load-manifest manifest-path))
  (unless (equal module-id "dyn-loader-test")
    (error "unexpected module id: %S" module-id))
  (unless (member module-id dyn-loader-loaded-modules)
    (error "module id missing from dyn-loader-loaded-modules after load: %S" dyn-loader-loaded-modules))

  (setq old-fn (symbol-function 'dyn-loader-test-call))
  (unless (= (funcall old-fn) 1)
    (error "expected initial function result 1"))
  (unless (= dyn-loader-test-value 10)
    (error "expected initial variable value 10"))

  (dyn-loader-unload module-id)
  (dyn-loader-unload module-id)
  (when (member module-id dyn-loader-loaded-modules)
    (error "module id still present after unload: %S" dyn-loader-loaded-modules))
  (unless (= dyn-loader-test-value 10)
    (error "expected variable snapshot value 10 after unload"))
  (condition-case err
      (progn
        (funcall old-fn)
        (error "expected unload to invalidate stale function"))
    (error
     (unless (string-match-p
              (regexp-quote "dyn-loader: module 'dyn-loader-test' is unloaded")
              (error-message-string err))
       (signal (car err) (cdr err)))))

  (copy-file v2-path live-path t)
  (dyn-loader-reload module-id)
  (unless (member module-id dyn-loader-loaded-modules)
    (error "module id missing from dyn-loader-loaded-modules after reload: %S" dyn-loader-loaded-modules))
  (unless (= (funcall old-fn) 2)
    (error "expected compatible reload to retarget stale function"))
  (unless (= dyn-loader-test-value 20)
    (error "expected reloaded variable value 20"))

  (copy-file v3-path live-path t)
  (dyn-loader-reload module-id)
  (unless (= dyn-loader-test-value 30)
    (error "expected variable value 30 after incompatible reload"))
  (condition-case err
      (progn
        (funcall old-fn)
        (error "expected incompatible reload to reject stale function"))
    (error
     (unless (string-match-p
              (regexp-quote "dyn-loader: export 'dyn-loader-test-call' changed signature")
              (error-message-string err))
       (signal (car err) (cdr err)))))

  (princ (format "dyn-loader lifecycle ok: %s\n" module-id)))
