;; #1539 prerequisite ABI-availability probe for `wasi:cli/stdin`.
;;
;; This deliberately contains only the import shape. It must not be mistaken
;; for a lifecycle implementation: normal EOF, early readable-end drop, and
;; the completion future's error result remain unmeasured until a host links
;; the ratified `wasi:cli/stdin@0.3.0` interface below.
;;
;; The WIT source signature is:
;;
;;   read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>
;;
;; wasm-tools 1.245 rejects an imported instance when `error-code` is encoded
;; as a nominal enum in this hand-authored component type. The probe therefore
;; uses a one-byte error-payload stand-in solely to make the
;; interface-name/version availability check validate. It does NOT establish
;; compatibility of the full nominal result type; that too stays blocked.
(component
  (type $stream (stream u8))
  (type $completion-result (result (error u8)))
  (type $completion (future $completion-result))
  (type $read-result (tuple $stream $completion))
  (type $stdin
    (instance
      (export "read-via-stream" (func (result $read-result)))
    )
  )

  (import "wasi:cli/stdin@0.3.0" (instance $stdin-import (type $stdin)))
  (alias export $stdin-import "read-via-stream" (func $read-via-stream))
)
