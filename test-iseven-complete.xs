; Test isEven function
(let isEven (fn (n) (= (% n 2) 0)))

; Test individual cases and return result
(if (isEven 4)
    (if (not (isEven 7))
        (if (isEven 0)
            (if (isEven -2)
                "All tests passed!"
                "Test failed: isEven(-2) should be true")
            "Test failed: isEven(0) should be true")
        "Test failed: isEven(7) should be false")
    "Test failed: isEven(4) should be true")