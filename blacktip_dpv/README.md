# Improved version of the Dive Xtras Scooter software for VESC controller

![Blacktip DPV Logo.](https://raw.githubusercontent.com/mikeller/vesc_pkg/main/blacktip_dpv/shark_with_laser.png)

## About

This software is an improved version of the Dive Xtras scooter software for VESC controllers. It includes all the original features plus many new ones. It is designed to be used with the VESC ecosystem, including the VESC Tool (PC) and the VESC mobile app.

## What's New

- **New features** — Jump speed, reverse gears, smart cruise, battery thirds, and more
- **Bug fixes** — Resolved multiple issues from the original firmware
- **EEPROM protection** — Settings changes no longer wear out the EEPROM
- **Latest compatibility** — Always works with the latest VESC firmware

## Features

### Bluetooth App

Designed primarily to be used with new scooters (Cuda-X & Blacktip) which now have Bluetooth, allowing all features to be accessed via the VESC mobile app on your phone.

### Latest VESC Firmware

Always stays compatible with latest VESC firmware, ensuring your scooter runs as smoothly and quietly as possible.

### Triple Click "Jump Speed"

A triple click jumps the scooter to a preset speed. By default, it jumps you to speed 6, straight to overdrive. The jump speed can be set via the app to whatever speed you want.

### Quadruple Click Reverse Gears

A quadruple click gets you into reverse. There are two reverse speeds: "Untangle" (slow, useful for untangling line) and "Reverse" (faster, for backing out). Reverse can be enabled or disabled in the app. Access it via a quadruple click, then normal shifting switches between the two speeds. Release to stop, then restart with a double click to resume forward speeds.

### Quintuple "5" Click Smart Cruise

Smart Cruise can be activated with a quintuple click. Optionally, Smart Cruise can be set to auto-engage after the scooter has been running at the same speed for some time. It will auto-disengage after a user-configurable timeout, or on trigger input.

### Slow Speed Restart

If you stop the scooter in any speed less than the start speed, when you restart it will do so in the speed you stopped at. This prevents the scooter from unexpectedly jumping to a higher speed when you restart in a sensitive environment. Shifting speeds to above the start speed clears this setting.

### Thirds Battery Display

Hold the trigger for 10 seconds to activate thirds mode (confirmed by audible warble). Your battery display will show three bars, each one being a third of capacity at the time you activated it. When you have used a third of your battery, you get an audible warning telling you it's time to turn around. Great for dive planning! Can be reactivated at any time and at any battery level.

### Battery Capacity Beeps

Struggle to see your screen underwater? Set your scooter to beep its capacity so you can just listen for how much battery you have remaining.

### Trigger Click Beeps

For new scooter divers and training, enable this option to have each different click make a unique beep tone, making it easier to learn the click patterns.

### Speed Ramp Rate

Adjust the acceleration of the scooter via the app. Videographers may want a slow ramp for smooth transitions, while tech divers may want the scooter to kick up to full speed as fast as possible. Smaller numbers accelerate slower, larger numbers faster.

### Safe Start

As the scooter starts, it only accelerates to full speed and torque if nothing is blocking the prop. Designed to make the scooter safer in situations where curious people or children may turn it on without fully understanding that there is a big spinning propeller. Can be enabled/disabled in the app. The updated version adds zero time to normal startup. If something blocks the prop, the scooter stops with a beep, making it very clear when it is triggered.

## Installation

1. Download the latest `blacktip_dpv.vescpkg` file
2. Open VESC Tool (PC) or VESC app (mobile)
3. Connect to your scooter
4. Install the package through the VESC Tool interface

## Configuration

All settings can be adjusted through the VESC mobile app or VESC Tool:
- Speed settings and jump speed
- Reverse enable/disable
- Smart Cruise behavior
- Battery display and beep options
- Safe start enable/disable
- Speed ramp rate
- And more...

## Support

For issues, questions, or contributions, visit the project repository:
https://github.com/mikeller/vesc_pkg

## Developer Information

For developers interested in contributing or building from source, see `DEVELOPMENT.md` in the repository.
