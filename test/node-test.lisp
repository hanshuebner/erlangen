;;;; Basic test for node protocol.

(defpackage erlangen.distribution.protocol.node-test
  (:use :cl
        :erlangen
        :erlangen.distribution.protocol.node
        :erlangen.distribution.protocol.port-mapper
        :erlangen.distribution.id)
  (:export :run-tests))

(in-package :erlangen.distribution.protocol.node-test)

(let (messages)
  (defun test-agent ()
    (setf messages nil)
    (loop do (push (receive) messages)))
  (defun test-messages ()
    messages))

(defun run-tests ()
  (let (port-mapper node-server-agent register-agent id)
    (unwind-protect
         (progn
           (setq port-mapper (spawn `(port-mapper)))
           (sleep 1)
           (multiple-value-bind (node-server port)
               (make-node-server)
             (setq node-server-agent (spawn node-server))
             (setq register-agent
                   (spawn `(register-node ,(node-name) ,port))))
           (sleep 1)

           ;; Test REMOTE-SPAWN
           (setq id (remote-spawn (host-name) (node-name) '(test-agent)
                                  "bar" :link 1))
           (assert (find-agent id) ()
                   "REMOTE-SPAWN failed.")
           (handler-case (remote-spawn
                          (host-name) (node-name) '(test-agent)
                          "nil" :invalid 1)
             (error (error)
               (declare (ignore error)))
             (:no-error ()
               (error "REMOTE-SPAWN succeeded with invalid mode.")))
           (handler-case (remote-spawn
                          (host-name) (node-name) '(invalid)
                          "nil" nil 1)
             (error (error)
               (declare (ignore error)))
             (:no-error ()
               (error "REMOTE-SPAWN succeeded with invalid call.")))

           ;; Test REMOTE-SEND
           (remote-send "hello" id)
           (assert (equal '("hello") (test-messages)) ()
                   "REMOTE-SEND failed.")
           (handler-case
               (let ((id (remote-spawn (host-name) (node-name) '(sleep 2)
                                       "nil" nil 1)))
                 (remote-send "hello" id)
                 (remote-send "hello2" id))
             (error (error)
               (declare (ignore error)))
             (:no-error ()
               (error "REMOTE-SEND succeeded even though message was not delivered.")))
           (handler-case (remote-send "hello" (agent-id :invalid))
             (error (error)
               (declare (ignore error)))
             (:no-error ()
               (error "REMOTE-SEND succeeded with invalid id.")))

           ;; Test REMOTE-LINK
           (remote-link id "foo" :link)
           (assert (equal (erlangen.agent::agent-links
                           (find-agent id))
                          '("foo" "bar")))
           (remote-link id "foo" :monitor)
           (assert (equal (erlangen.agent::agent-monitors
                           (find-agent id))
                          '("foo")))
           (handler-case (remote-link id "foo" :invalid)
             (error (error)
               (declare (ignore error)))
             (:no-error ()
               (error "REMOTE-LINK succeeded with invalid mode.")))
           (remote-link (agent-id :invalid) "foo" :link)

           ;; Test REMOTE-UNLINK
           (remote-unlink id "foo")
           (assert (equal (erlangen.agent::agent-links
                           (find-agent id))
                          '("bar")))
           (assert (equal (erlangen.agent::agent-monitors
                           (find-agent id))
                          '()))
           (remote-unlink (agent-id :invalid) "foo")

           ;; Test REMOTE-EXIT
           (let* (kill-message
                  (agent (find-agent id))
                  (monitor (spawn (lambda ()
                                    (link agent :monitor)
                                    (setf kill-message (receive))))))
             (unwind-protect
                  (progn
                    (remote-exit :foo id)
                    (sleep 1)
                    (destructuring-bind (killed-agent status . reason)
                        kill-message
                      (assert (eq agent killed-agent))
                      (assert (eq status :exit))
                      (assert (eq reason :foo))))
               (exit :kill monitor))))

      (exit :kill (find-agent id))
      (exit :kill register-agent)
      (exit :kill node-server-agent)
      (exit :kill port-mapper)
      (clear-connections))))
