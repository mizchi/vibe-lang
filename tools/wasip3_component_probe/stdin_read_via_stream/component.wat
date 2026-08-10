;; #1539 ABI-availability probe for `wasi:cli/stdin@0.3.0`.
;;
;; The imported `error-code` is the nominal type exported by
;; `wasi:cli/types@0.3.0`, not a representation-compatible stand-in. Keeping
;; that alias in the `stdin` instance makes this component an exact declaration
;; of the WIT result type.
(component
  (type $types
    (instance
      (type $error-code (enum "io" "illegal-byte-sequence" "pipe"))
      (export "error-code" (type (eq $error-code)))
    )
  )
  (import "wasi:cli/types@0.3.0" (instance $types-import (type $types)))
  (alias export $types-import "error-code" (type $error-code))

  (type $stdin
    (instance
      (alias outer 1 $error-code (type $stdin-error-code))
      (type $stream (stream u8))
      (type $completion-result (result (error $stdin-error-code)))
      (type $completion (future $completion-result))
      (type $read-result (tuple $stream $completion))
      (export "read-via-stream" (func (result $read-result)))
    )
  )
  (import "wasi:cli/stdin@0.3.0" (instance $stdin-import (type $stdin)))
  (alias export $stdin-import "read-via-stream" (func $read-via-stream))
)
