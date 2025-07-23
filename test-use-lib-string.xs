; Test use lib/String functionality

; Import specific functions from String module
(use lib/String (concat, length))

; Now we can use concat and length without String. prefix
(length (concat "Hello" " World"))