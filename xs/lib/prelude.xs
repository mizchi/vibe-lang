;; XS Standard Library - Prelude
;; すべての標準ライブラリをインポートする

(import (Core compose id const flip fst snd Maybe Just Nothing maybe Either Left Right either not and or inc dec double square abs min max apply pipe))
(import (List singleton pair null length append reverse map filter foldLeft foldRight find elem take drop zip range replicate all any))
(import (Math neg reciprocal pow factorial gcd lcm even odd positive negative zero fib fibTail sum product average clamp sign))
(import (String emptyString strAppend join repeatString strEq strNeq))