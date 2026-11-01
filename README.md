# Pixel Kid

A DIY baby monitor for Apple devices. The current app is a low-light test bench for the sender iPhone (iPhone XS, iOS 18).

## Low-light test app

- **Live view** from the back or front camera, with auto or manual exposure (ISO and shutter), digital gain, live frame averaging and noise reduction.
- **Stats overlay**: ISO, shutter, frame rate, frame brightness, and a *light index* (brightness ÷ ISO × shutter) for comparing how much light a setup provides, independent of camera settings.
- **Screen light**: turns the screen into a dim colored light (red, amber, warm, white) with adjustable screen brightness, color level and fade time. With the back camera facing the crib, the screen faces the wall and the light bounces into the room.
- **Peek**: after a countdown, fades the screen light in, averages every frame for a few seconds into one still image, fades the light out, and shows the result. Results can be saved to Photos for comparison.

## Running it

Open `PixelKid.xcodeproj` in Xcode, select the iPhone as the run destination and press Run. Signing uses automatic signing with team `YBXD458GD5`; change the bundle identifier (`com.retronator.pixelkid`) in the target settings if needed.
