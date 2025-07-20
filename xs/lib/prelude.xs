;; XS Standard Library - Prelude
;; すべての標準ライブラリをインポートする

(import (Core compose id const flip fst snd Maybe Just Nothing maybe Either Left Right either not and or inc dec double square abs min max apply pipe))
(import (List singleton pair null length append reverse map filter fold-left fold-right find elem take drop zip range replicate all any))
(import (Math neg reciprocal pow factorial gcd lcm even odd positive negative zero fib fib-tail sum product average clamp sign))
(import (String empty-string str-append join repeat-string str-eq str-neq))