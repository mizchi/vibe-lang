; Celsius to Fahrenheit conversion test
(let celsiusToFahrenheit (fn (c: Float) (+. (*. c 1.8) 32.0)))

; Test cases
(print "Testing celsius to fahrenheit conversion:")
(print (concat "0°C = " (toString (celsiusToFahrenheit 0.0))))
(print (concat "100°C = " (toString (celsiusToFahrenheit 100.0))))
(print (concat "37°C = " (toString (celsiusToFahrenheit 37.0))))

; Return the last calculation
(celsiusToFahrenheit 37.0)