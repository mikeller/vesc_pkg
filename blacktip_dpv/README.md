# Improved version of the Dive Xtras Scooter software for VESC controller

![Blacktip DPV Logo.](https://raw.githubusercontent.com/mikeller/vesc_pkg/main/blacktip_dpv/shark_with_laser.png)

## Features
This software is an improved version of the Dive Xtras scooter software for VESC controllers. It includes all the original features plus many new ones. It is designed to be used with the VESC ecosystem, including the VESC Tool (PC) and the VESC.

## Improvements over the original Dive Xtras Scooter Software

- added new features (see below)
- fixed a bunch of minor bugs
- don't wear out the EEPROM by writing to it for every settings change

## Features

### Bluetooth App.
Designed primarily to be used with new scooters (Cuda-X & Blacktip) which now have Bluetooth allowing all features to be accessed via an app on your phone (VESC phone app).

### Latest Vesc Firmware
Always stays compatable with latest Vesc firmware ensuring your always upto date and your scooter the smoothest and quietest posible.

### Triple Click "Jump Speed"
A triple click jumps the scooter to a preset speed. By default, it jumps you to speed 6, straight to overdrive. The jump speed can be set via the app to whatever speed you want.

### Quadruple Click Reverse Gears
A quadruple click gets you into reverse. There are two reverse speeds "Untangle" and "Reverse". Untangle is slow and useful for untangling line, whilst Reverse is a bit faster for backing out of that wreck corridor. Reverse can be enabled or disabled in the app. It is accessible via a quadruple click and then normal shifting switches between the two speeds. Release to stop and then restart with a double click to resume forward speeds as normal.

### Quintuple "5" Click
The software is set up for Smart Cruise on a quintuple click.
Optionally Smart Cruise can be set to auto-engage after the scooter has been running at the same speed for some time.
It will auto-disengage after a user-configurable time out, or on trigger input.

### Slow Speed Restart
Have you ever been cruising around in speeds 1 or 2, maybe in a sensitive enviroment, stoped and then restarted only to find your in speed 3 again and going too fast? Now if you stop the scooter in any speed less than the start speed, when you restart it will do so in the speed you stopped at. Shifting speeds to above the start speed clears this setting and you will restart in the normal start speed.

### Thirds Battery Display
Hold the trigger for 10 seconds and you will activate thirds mode (confirmed by audible warble). From now on your battery display will show three bars, each one being a third of capacity at the time you activated it. When you have used a third of your battery you will get an audible warning telling you its time to turn around. Great for backup for divers who want to use thirds for dive planning. Can be reactivated at any time, and at any battery level, so wherever you are in your dive, you can calculate thirds from that point.

### Battery Capacity Beeps
Do you struggle to see your screen? You can now set your scooter to beep its capacity underwater so you can just listen for how much battery you have remaining.

### Trigger Click Beeps
For new scooter divers and training, enable this option to have each different click make a unique beep tone.

### Speed Ramp Rate
Can be adjusted in the app to vary the acceleration of the scooter. Videographers may want a slow ramp for smooth transitions, Tec divers may want the scooter to kick up to full speed as fast as possible. Smaller numbers accelerate slower, larger faster.

### Safe Start
**New and Updated:** As the scooter starts it only accelerates to full speed and torque if nothing is blocking the prop. Designed to make the scooter safer in situations where curious people or children may turn it on without fully understanding that there is a big spinning propellor. Can be enabled/disabled in the app. New version adds zero time to normal startup. If something blocks the prop, scooter stops with a beep making it very clear when it is triggered.

### VESC Package Support
The VESC team have created a fantastic ecosystem where we can now load our scooter software onto the scooter as a package. A package is a small code file thats easy to create and share. It includes the scooter code and a user interface that is accessable on the VESC app (phone) or The VESC Tool (PC). The graphical user interface and app makes it much easier for you to change settings. As the package is independant of updates of the VESC ecosystem, it can always take advantage of the latest version giving you the best posible motor control of your scooter.
