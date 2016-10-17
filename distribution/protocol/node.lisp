;;;; Erlangen node protocol implementation. The node protocol defines a
;;;; scheme to issue SPAWN, SEND, LINK and UNLINK remotely. Any node can
;;;; act as a client connecting to another node on its listening port. At
;;;; the same time every node must listen for incoming requests on its
;;;; listening port. The listening port of a node is retrieved from a
;;;; port mapper instance.
;;;;
;;;; In the context of this protocol, “local” and “remote” describe the
;;;; client and server nodes respectively, but do not imply that these
;;;; must necessarily be on different hosts.

(in-package :erlangen.distribution.protocol.node)

;; SPAWN-REQUEST is sent by a node to issue a SPAWN. It contains a CALL
;; (see ERLANGEN.DISTRIBUTION.CALL), the parent agent identifier, the
;; attach mode (:LINK, :ATTACH or NIL) and the mailbox capacity of the
;; agent to create. The remote node must either spawn the agent
;; accordingly and acknowlege the request by sending a SPAWN-REPLY or
;; indicate failure to do so by sending an ERROR-REPLY.
;;
;; SPAWN-REPLY is sent by nodes to acknowledge a SPAWN-REQUEST. It
;; contains the agent identifier of the spawned agent.
(define-message #x30 spawn-request
  (call value) (parent string) (attach value) (mailbox-size integer))
(define-message #x31 spawn-reply (agent string))

;; SEND-REQUEST is sent by a node to issue a SEND. It contains the
;; message to be delivered and the target agent. The remote node must
;; either acknowledge the delivery of the message by sending an ACK-REPLY
;; or indicate failure to do so by sending an ERROR-REPLY.
(define-message #x32 send-request (message value) (agent string))

;; LINK-REQUEST is sent by a node to issue a LINK. It contains a remote
;; agent identifier and a local agent identifier as well as the desired
;; link mode (:LINK or :ATTACH). The remote node must either link the
;; specified agents accordingly and acknowlege the request by sending an
;; ACK-REPLY or indicate failure to do so by sending an ERROR-REPLY.
;;
;; UNLINK-REQUEST is sent by a node to issue an UNLINK. It contains a
;; remote agent identifier and a local agent identifier. The remote node
;; must either unlink the specified agents accordingly and acknowlege the
;; request by sending an ACK-REPLY or indicate failure to do so by
;; sending an ERROR-REPLY.
(define-message #x34 link-request
  (remote-agent string) (local-agent string) (mode value))
(define-message #x36 unlink-request
  (remote-agent string) (local-agent string))

;; EXIT-REQUEST is sent by a node to issue an EXIT. It contains the exit
;; reason and the target agent. The remote node must kill the target
;; agent—given it exists and has not exited already—and acknowledge the
;; request by sending an ACK-REPLY.
(define-message #x38 exit-request (reason value) (agent string))

;; NOTIFY-REQUEST is sent by a node to issue an exit notification. It
;; contains the remote agent, its exit reason, and and the target agent.
;; The remote node must notify the target agent accordingly—given it
;; exists and has not exited—and acknowledge the request by sending an
;; ACK-REPLY.
(define-message #x40 notify-request
  (remote-agent string) (reason value) (local-agent string))

(defun handle-spawn-request (connection request)
  "Handles REQUEST of type SPAWN-REQUEST on CONNECTION."
  (multiple-value-bind (call parent attach mailbox-size)
      (read-spawn-request request)
    (handler-case (spawn (make-function call)
                         :attach attach
                         :to parent
                         :mailbox-size mailbox-size)
      (type-error (error)
        (declare (ignore error))
        (write-error-reply "Invalid request." connection))
      (error (error)
        (declare (ignore error))
        (write-error-reply "Unable to spawn agent." connection))
      (:no-error (agent)
        (write-spawn-reply (agent-id agent) connection)))))

(defun handle-send-request (connection request)
  "Handles REQUEST of type SEND-REQUEST on CONNECTION."
  (multiple-value-bind (message agent-id) (read-send-request request)
    (let ((agent (find-agent agent-id)))
      (if agent
          (handler-case (send message agent)
            (error (error)
              (declare (ignore error))
              (write-error-reply
               "Unable to deliver message." connection))
            (:no-error () (write-ack-reply connection)))
          (write-error-reply "No such agent." connection)))))

(defun handle-link-request (connection request)
  "Handles REQUEST of type LINK-REQUEST on CONNECTION."
  (multiple-value-bind (local-agent remote-agent mode)
      (read-link-request request)
    (let ((agent (find-agent local-agent)))
      (if agent
          (progn (add-link agent mode remote-agent)
                 (write-ack-reply connection))
          (write-error-reply "No such agent." connection)))))

(defun handle-unlink-request (connection request)
  "Handles REQUEST of type UNLINK-REQUEST on CONNECTION."
  (multiple-value-bind (local-agent remote-agent)
      (read-unlink-request request)
    (let ((agent (find-agent local-agent)))
      (when agent
        (remove-link agent remote-agent))))
  (write-ack-reply connection))

(defun handle-exit-request (connection request)
  "Handles REQUEST of type EXIT-REQUEST on CONNECTION."
  (multiple-value-bind (reason agent-id) (read-exit-request request)
    (let ((agent (find-agent agent-id)))
      (when agent
        (exit reason agent))))
  (write-ack-reply connection))

(defun handle-notify-request (connection request)
  "Handles REQUEST of type NOTIFY-REQUEST on CONNECTION."
  (multiple-value-bind (remote-agent reason local-agent)
      (read-notify-request request)
    (let ((agent (find-agent local-agent)))
      (when agent
        (notify remote-agent reason agent))
      (write-ack-reply connection))))

(defun serve-requests (connection)
  "Serves requests on CONNECTION."
  (send-hello connection)
  (force-output connection)
  (loop do (select ((listen connection) (ready-p)
                    (multiple-value-bind (type request)
                        (read-message connection)
                      (funcall (ecase type
                                 (#x30 'handle-spawn-request)
                                 (#x32 'handle-send-request)
                                 (#x34 'handle-link-request)
                                 (#x36 'handle-unlink-request)
                                 (#x38 'handle-exit-request)
                                 (#x40 'handle-notify-request))
                                 connection request)
                      (force-output connection))))))

(defun make-request-handler (connection)
  "Returns a handler for node protocol CONNECTION."
  (lambda ()
    (unwind-protect (serve-requests connection)
      (close connection))))

(defun make-node-server (&key (host "localhost"))
  "Returns listener for node protocol on HOST and the listening port."
  (let ((socket (make-socket* :connect :passive
                              :local-host host
                              :keepalive t)))
    (values (lambda ()
              (with-socket (socket socket)
                (loop do
                     (select
                      ((accept-connection socket :wait nil) (connection)
                       (spawn (make-request-handler connection)
                              :attach :monitor))))))
            (local-port socket))))

;; The local node opens and reuses one `connection' per remote node.
(defvar *remote-connections*/lock (make-lock))
(defvar *remote-connections* (make-hash-table :test 'equal)
  "Holds established connections to remote nodes.")

(defstruct connection
  "A `connection' contains a SOCKET and a LOCK, as well as a list of DEFERRED
requests."
  socket
  (deferred nil :type list)
  (deferred-tail nil :type (or cons null))
  (lock (make-lock) :type lock))

(defun get-connection (host node &aux (nid (cons host node)))
  "Returns the connection object for NODE on HOST."
  (with-lock-grabbed (*remote-connections*/lock)
    (or #1=(gethash nid *remote-connections*)
        (setf #1# (make-connection)))))

(defun defer-request (request connection)
  "Defer REQUEST for CONNECTION."
  (with-slots (deferred deferred-tail) connection
    (setf deferred-tail
          (if (null deferred-tail)
              (setf deferred #1=(list request))
              (setf (cdr deferred-tail) #1#)))))

(defun replay-deferred (connection)
  "Replay DEFERRED requests onto CONNECTION, and remove successful requests
  from DEFERRED."
  (with-slots (socket deferred deferred-tail) connection
    (loop while deferred do
         (funcall (first deferred) socket)
         (pop deferred))
    (setf deferred-tail nil)))

(defun establish-connection (connection host node)
  "Establishes CONNECTION to remote NODE on HOST."
  (setf (connection-socket connection)
        (make-socket* :remote-host host
                      :remote-port (query-node-port host node)
                      :keepalive t))
  (assert-protocol-version (connection-socket connection))
  (replay-deferred connection))

(defun close-connection (connection)
  "Closes CONNECTION."
  (when #1=(connection-socket connection)
    (close #1# :abort t)
    (setf #1# nil)))

(defun clear-connections ()
  "Closes all remote connections."
  (with-lock-grabbed (*remote-connections*/lock)
    (maphash (lambda (nid connection)
               (with-lock-grabbed ((connection-lock connection))
                 (close-connection connection)
                 (remhash nid *remote-connections*)))
             *remote-connections*)))

(defmacro with-connection ((var host node &key persist-p) &body request
                           &aux (host-sym (gensym "host"))
                                (node-sym (gensym "node"))
                                (connection-sym (gensym "connection"))
                                (error-sym (gensym "error")))
  "Evaluate REQUEST with VAR bound to a socket of an established `connection'
to NODE of HOST. If PERSIST-P is non-nil REQUEST will be persistent."
  `(let* ((,host-sym ,host)
          (,node-sym ,node)
          (,connection-sym (get-connection ,host-sym ,node-sym)))
     (or (with-lock-grabbed ((connection-lock ,connection-sym))
           (handler-case (with-slots ((,var socket)) ,connection-sym
                           (when (null ,var)
                             (establish-connection
                              ,connection-sym ,host-sym ,node-sym))
                           ,@request)
             (error (,error-sym)
               (declare (ignorable ,error-sym))
               ,(when persist-p
                  `(defer-request (lambda (,var) ,@request) ,connection-sym))
               (close-connection ,connection-sym)
               ,(unless persist-p
                  `(error ,error-sym)))))
         (values))))

(defun remote-spawn (host node call parent attach mailbox-size)
  "Spawns agent on remote NODE of HOST using CALL, PARENT, ATTACH mode
and MAILBOX-SIZE."
  (check-type call list)
  (check-type attach (member :link :monitor nil))
  (check-type mailbox-size (integer 1))
  (with-connection (socket host node)
    (do-request (socket)
      (write-spawn-request call parent attach mailbox-size)
      (#x31 read-spawn-reply))))

(defun remote-send (message id)
  "Sends MESSAGE to remote agent by ID."
  (let ((error (multiple-value-bind (host node) (decode-id id)
                 (with-connection (socket host node)
                   (handler-case (do-request (socket)
                                   (write-send-request message id))
                     (protocol-error (error) error))))))
    (when error
      (error error))))

(defun remote-link (remote-id local-id mode)
  "Links remote agent by REMOTE-ID to agent by LOCAL-ID using MODE."
  (check-type mode (member :link :monitor))
  (multiple-value-bind (host node) (decode-id remote-id)
    (with-connection (socket host node :persist-p t)
      (handler-case (do-request (socket)
                      (write-link-request remote-id local-id mode))
        (protocol-error (error)
          (let ((agent (find-agent local-id)))
            (when agent
              (case mode
                (:link (exit `(,remote-id . ,error) agent))
                (:monitor (notify remote-id error agent))))))))))

(defun remote-unlink (remote-id local-id)
  "Unlinks remote agent by REMOTE-ID from agent by LOCAL-ID."
  (multiple-value-bind (host node) (decode-id remote-id)
    (with-connection (socket host node :persist-p t)
      (do-request (socket)
        (write-unlink-request remote-id local-id)))))

(defun remote-exit (reason id)
  "Kill remote agent by ID with REASON as the exit reason of agent."
  (multiple-value-bind (host node) (decode-id id)
    (with-connection (socket host node :persist-p t)
      (do-request (socket)
        (write-exit-request reason id)))))

(defun remote-notify (local-id reason id)
  (multiple-value-bind (host node) (decode-id id)
    (with-connection (socket host node :persist-p t)
      (do-request (socket)
        (write-notify-request local-id reason id)))))
