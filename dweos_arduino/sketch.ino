#include <PWM.h>

// Pin configuration
int led = 9;            // LED pin
int brightness = 127;   // Initial brightness value for the PWM duty cycle
float frequency = 60.3; // Initial frequency in Hz

void setup()
{
    Serial.begin(9600);

    // Initialize all timers except for timer0 to save timekeeping tasks
    InitTimersSafe();

    // Set the initial PWM frequency and duty cycle
    if (SetPinFrequencySafe(led, frequency))
    {
        pwmWrite(led, brightness);
        Serial.println("PWM frequency and initial duty cycle set.");
    }
    else
    {
        Serial.println("Failed to set frequency.");
    }
}

void loop()
{
    if (Serial.available())
    {
        // Read frequency and duty cycle values over Serial
        String inputString = Serial.readStringUntil('\n'); // Read string input until newline
        inputString.trim();                                // Remove any extraneous spaces or newlines
        int freqDutySplitIndex = inputString.indexOf(',');

        if (freqDutySplitIndex != -1)
        {
            String freqStr = inputString.substring(0, freqDutySplitIndex);  // Extract frequency string
            String dutyStr = inputString.substring(freqDutySplitIndex + 1); // Extract duty cycle string

            // Parse floats
            float newFrequency = freqStr.toFloat();
            int newDutyCycle = dutyStr.toInt();

            // Validate frequency range
            if (newFrequency >= 1 && newFrequency <= 2000000)
            {
                // Set the PWM frequency and apply duty cycle
                if (SetPinFrequencySafe(led, newFrequency))
                {
                    brightness = map(constrain(newDutyCycle, 0, 100), 0, 100, 0, 255);
                    pwmWrite(led, brightness);
                    Serial.print("Set frequency to: ");
                    Serial.print(newFrequency);
                    Serial.print(" Hz, duty cycle to: ");
                    Serial.print(newDutyCycle);
                    Serial.println("%");
                }
                else
                {
                    Serial.println("Failed to set new frequency.");
                }
            }
            else
            {
                Serial.println("Invalid frequency value.");
            }
        }
        else
        {
            Serial.println("Invalid input format. Use frequency,dutycycle (e.g., 60,50).");
        }
    }
}
