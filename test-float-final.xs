; Celsius to Fahrenheit conversion function
(let celsiusToFahrenheit (fn (c) (+ (* c 1.8) 32.0)))

; Test: 0°C to Fahrenheit (should be 32.0)
(celsiusToFahrenheit 0.0)